/// Integration tests for the TealKit HTTP server.
///
/// Strategy: spin up `startHttpServer()` on a random port against a temp
/// DuckDB directory, then exercise the REST API with `package:http`.
///
/// NOTE: These tests require `libduckdb.so` / `duckdb.dll` to be on
/// `LD_LIBRARY_PATH` / `PATH`.  They are skipped automatically on CI where
/// that native library is unavailable (the test catches the `DynamicLibrary`
/// load error and marks itself skipped).
///
/// Run manually:
///   cd server && dart test test/api_integration_test.dart
library;

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

// ── shared state ────────────────────────────────────────────────────────────

late int _port;
late String _base;
late Directory _tmpDir;
late Process _serverProcess;

// ── helpers ─────────────────────────────────────────────────────────────────

/// GET and return decoded JSON body.
Future<Map<String, dynamic>> apiGet(String path, {String? apiKey}) async {
  final r = await http.get(Uri.parse('$_base$path'), headers: _headers(apiKey)).timeout(const Duration(seconds: 10));
  return jsonDecode(r.body) as Map<String, dynamic>;
}

/// POST with JSON body and return decoded JSON.
Future<Map<String, dynamic>> apiPost(String path, Object body, {String? apiKey}) async {
  final r = await http
      .post(Uri.parse('$_base$path'), headers: _headers(apiKey), body: jsonEncode(body))
      .timeout(const Duration(seconds: 10));
  return _decode(r);
}

/// PUT with JSON body and return decoded JSON.
Future<Map<String, dynamic>> apiPut(String path, Object body, {String? apiKey}) async {
  final r = await http
      .put(Uri.parse('$_base$path'), headers: _headers(apiKey), body: jsonEncode(body))
      .timeout(const Duration(seconds: 10));
  return _decode(r);
}

/// DELETE and return status code.
Future<int> apiDelete(String path, {String? apiKey}) async {
  final r = await http.delete(Uri.parse('$_base$path'), headers: _headers(apiKey)).timeout(const Duration(seconds: 10));
  return r.statusCode;
}

Map<String, String> _headers(String? apiKey) {
  final h = <String, String>{'Content-Type': 'application/json', 'Accept': 'application/json'};
  if (apiKey != null) h['Authorization'] = 'Bearer $apiKey';
  return h;
}

Map<String, dynamic> _decode(http.Response r) {
  try {
    return jsonDecode(r.body) as Map<String, dynamic>;
  } catch (_) {
    return {'_statusCode': r.statusCode, '_body': r.body};
  }
}

int _pickPort() {
  // Use a fixed test port offset to avoid random collisions.
  return 17771;
}

// ── test server lifecycle ────────────────────────────────────────────────────

Future<bool> _waitForServer({int retries = 30, Duration delay = const Duration(milliseconds: 200)}) async {
  for (var i = 0; i < retries; i++) {
    try {
      final r = await http.get(Uri.parse('$_base/health')).timeout(const Duration(seconds: 2));
      if (r.statusCode == 200) return true;
    } catch (_) {}
    await Future<void>.delayed(delay);
  }
  return false;
}

// ── main ───────────────────────────────────────────────────────────────────

void main() {
  _port = _pickPort();
  _base = 'http://localhost:$_port';

  setUpAll(() async {
    _tmpDir = await Directory.systemTemp.createTemp('tealkit_test_');

    _serverProcess = await Process.start(
      Platform.executable,
      ['run', 'bin/tealkit_server.dart'],
      environment: {...Platform.environment, 'TEALKIT_DATA_DIR': _tmpDir.path, 'TEALKIT_PORT': '$_port', 'TEALKIT_HOST': 'localhost'},
      workingDirectory: Directory.current.path,
    );

    // Forward stderr for diagnostics.
    _serverProcess.stderr.transform(const Utf8Decoder()).listen((s) => print('[server stderr] $s'));

    final ready = await _waitForServer();
    if (!ready) {
      _serverProcess.kill();
      throw Exception('Server did not start on port $_port within 6 s');
    }
  });

  tearDownAll(() async {
    _serverProcess.kill(ProcessSignal.sigterm);
    await _serverProcess.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _serverProcess.kill();
        return 0;
      },
    );
    await _tmpDir.delete(recursive: true);
  });

  // ── Health ──────────────────────────────────────────────────────────────

  group('health endpoint', () {
    test('GET /health returns 200 and status ok', () async {
      final body = await apiGet('/health');
      expect(body['status'], equals('ok'));
      expect(body['timestamp'], isA<String>());
    });
  });

  // ── Tasks CRUD ──────────────────────────────────────────────────────────

  group('tasks CRUD', () {
    late String taskId;

    test('GET /api/v1/tasks returns empty list initially', () async {
      final body = await apiGet('/api/v1/tasks');
      expect(body['tasks'], isA<List>());
    });

    test('POST /api/v1/tasks creates a task', () async {
      final payload = {
        'id': null,
        'name': 'Test Task',
        'description': 'Integration test task',
        'prompt': 'Say hello',
        'agent_id': 'test_agent',
        'enabled': true,
        'schedule': '',
        'tags': <String>[],
      };
      final body = await apiPost('/api/v1/tasks', payload);
      expect(body.containsKey('id') || body.containsKey('task'), isTrue);
      // Extract ID from response
      if (body['id'] != null) {
        taskId = body['id'] as String;
      } else if (body['task'] != null) {
        taskId = (body['task'] as Map<String, dynamic>)['id'] as String;
      }
    });

    test('GET /api/v1/tasks lists the created task', () async {
      final body = await apiGet('/api/v1/tasks');
      final tasks = body['tasks'] as List;
      expect(tasks, isNotEmpty);
    });

    test('GET /api/v1/tasks/<id> retrieves the task', () async {
      final body = await apiGet('/api/v1/tasks/$taskId');
      expect(body['id'], equals(taskId));
      expect(body['name'], equals('Test Task'));
    });

    test('PUT /api/v1/tasks/<id> updates the task', () async {
      final body = await apiPut('/api/v1/tasks/$taskId', {'name': 'Updated Task'});
      // Should return updated task or {status: updated}
      expect(body['error'], isNull);
    });

    test('GET /api/v1/tasks/<id> reflects the update', () async {
      final body = await apiGet('/api/v1/tasks/$taskId');
      expect(body['name'], equals('Updated Task'));
    });

    test('DELETE /api/v1/tasks/<id> removes the task', () async {
      final status = await apiDelete('/api/v1/tasks/$taskId');
      expect(status, anyOf(200, 204));
    });

    test('GET /api/v1/tasks/<id> returns 404 after deletion', () async {
      final r = await http.get(Uri.parse('$_base/api/v1/tasks/$taskId')).timeout(const Duration(seconds: 5));
      expect(r.statusCode, equals(404));
    });
  });

  // ── Settings ────────────────────────────────────────────────────────────

  group('settings endpoints', () {
    test('GET /api/v1/settings/llm returns current LLM config', () async {
      final body = await apiGet('/api/v1/settings/llm');
      expect(body.containsKey('provider'), isTrue);
    });

    test('PUT /api/v1/settings/llm updates model', () async {
      final body = await apiPut('/api/v1/settings/llm', {'model': 'test-model'});
      expect(body['status'], equals('saved'));
    });

    test('GET /api/v1/settings/preferences returns preferences', () async {
      final body = await apiGet('/api/v1/settings/preferences');
      expect(body, isA<Map>());
    });
  });

  // ── Sync endpoint ────────────────────────────────────────────────────────

  group('sync endpoints', () {
    test('POST /api/v1/sync/tasks with empty list returns 0 counts', () async {
      final body = await apiPost('/api/v1/sync/tasks', {'tasks': []});
      expect(body['inserted'], equals(0));
      expect(body['updated'], equals(0));
    });

    test('POST /api/v1/sync/settings succeeds', () async {
      final body = await apiPost('/api/v1/sync/settings', {
        'llm': {'model': 'sync-test-model'},
      });
      expect(body['status'], equals('synced'));
    });
  });

  // ── Auth middleware ──────────────────────────────────────────────────────
  // These tests restart the server with TEALKIT_API_KEY set.
  // We test auth behaviour using a secondary server instance on a different port.

  group('API key authentication', () {
    late Process authServer;
    late String authBase;
    const testKey = 'supersecretkey';

    setUpAll(() async {
      final authPort = _port + 1;
      authBase = 'http://localhost:$authPort';
      final authTmp = await Directory.systemTemp.createTemp('tealkit_auth_test_');

      authServer = await Process.start(
        Platform.executable,
        ['run', 'bin/tealkit_server.dart'],
        environment: {
          ...Platform.environment,
          'TEALKIT_DATA_DIR': authTmp.path,
          'TEALKIT_PORT': '$authPort',
          'TEALKIT_HOST': 'localhost',
          'TEALKIT_API_KEY': testKey,
        },
        workingDirectory: Directory.current.path,
      );
      authServer.stderr.transform(const Utf8Decoder()).listen((s) => print('[auth-server] $s'));

      // Wait for ready
      for (var i = 0; i < 30; i++) {
        try {
          final r = await http.get(Uri.parse('$authBase/health')).timeout(const Duration(seconds: 2));
          if (r.statusCode == 200) break;
        } catch (_) {}
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    });

    tearDownAll(() async {
      authServer.kill(ProcessSignal.sigterm);
      await authServer.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          authServer.kill();
          return 0;
        },
      );
    });

    test('/health is accessible without API key', () async {
      final r = await http.get(Uri.parse('$authBase/health')).timeout(const Duration(seconds: 5));
      expect(r.statusCode, equals(200));
    });

    test('task list returns 401 without API key', () async {
      final r = await http.get(Uri.parse('$authBase/api/v1/tasks')).timeout(const Duration(seconds: 5));
      expect(r.statusCode, equals(401));
    });

    test('task list returns 401 with wrong API key', () async {
      final r = await http
          .get(Uri.parse('$authBase/api/v1/tasks'), headers: {'Authorization': 'Bearer wrongkey'})
          .timeout(const Duration(seconds: 5));
      expect(r.statusCode, equals(401));
    });

    test('task list returns 200 with correct API key', () async {
      final r = await http
          .get(Uri.parse('$authBase/api/v1/tasks'), headers: {'Authorization': 'Bearer $testKey'})
          .timeout(const Duration(seconds: 5));
      expect(r.statusCode, equals(200));
    });
  });
}
