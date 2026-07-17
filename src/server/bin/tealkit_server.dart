import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import 'package:tealkit_server/config/server_config_service.dart';
import 'package:tealkit_server/database/server_duckdb_service.dart';
import 'package:tealkit_server/version.dart';
import 'package:tealkit_server/models/agentic_task.dart';
import 'package:tealkit_server/runner/server_mcp_client.dart';
import 'package:tealkit_server/runner/server_embedded_llm_adapter.dart';
import 'package:tealkit_server/runner/server_task_runner.dart';
import 'package:tealkit_server/runner/server_internal_mcp.dart';
import 'package:tealkit_server/runner/server_tool_registry.dart';
import 'package:tealkit_server/scheduler/server_scheduler.dart';
import 'package:tealkit_server/services/server_data_sources_service.dart';
import 'package:tealkit_server/services/server_external_tools_service.dart';
import 'package:tealkit_server/services/server_indexing_service.dart';
import 'package:tealkit_server/services/server_llm_settings_service.dart';
import 'package:tealkit_server/services/server_model_download_service.dart';
import 'package:tealkit_server/services/server_preferences_service.dart';
import 'package:tealkit_server/utils/server_credential_cipher.dart';
import 'package:tealkit_server/utils/server_logger.dart';
import 'package:tealkit_server/utils/server_paths.dart';
import 'package:tealkit_server/services/server_skill_service.dart';
import 'package:tealkit_server/utils/server_live_log.dart';

final _uuid = const Uuid();

/// Active in-progress run tokens keyed by task ID.
final Map<String, CancellationToken> _activeRuns = {};

/// Persistent MCP server connections for proxy routes (keyed by server ID /
/// serverUrl).  Independent of per-task [ServerToolRegistry] instances.
final Map<String, ServerMcpClient> _mcpProxyClients = {};
final Map<String, StdioMcpProcess> _mcpProxyProcesses = {};
final Map<String, Process> _mcpProxyLocalHttpProcesses = {};
final Map<String, StreamSubscription<String>> _mcpProxyLocalHttpStdoutSubs = {};
final Map<String, StreamSubscription<String>> _mcpProxyLocalHttpStderrSubs = {};
final Map<String, Timer> _mcpProxyLocalHttpIdleTimers = {};
final Map<String, List<MCPTool>> _mcpProxyTools = {};

/// Cached in-process ServerInternalMcp instances for virtual MCP proxy IDs
/// (e.g. 'py_bridge').
final Map<String, ServerInternalMcp> _mcpProxyInternals = {};

const String _npmGlobalPrefix = '/data/.npm-global';

Map<String, String> _serverRuntimeEnv([Map<String, String>? overrides]) {
  final env = <String, String>{...Platform.environment};
  final pathSep = Platform.isWindows ? ';' : ':';
  final currentPath = env['PATH'] ?? '';
  env['NPM_CONFIG_PREFIX'] = _npmGlobalPrefix;
  env['NPM_CONFIG_CACHE'] = env['NPM_CONFIG_CACHE'] ?? '/data/.cache/npm';
  env['PATH'] = currentPath.isEmpty
      ? '$_npmGlobalPrefix/bin'
      : '$_npmGlobalPrefix/bin$pathSep$currentPath';
  if (overrides != null) env.addAll(overrides);
  return env;
}

bool _envBool(String name, {required bool defaultValue}) {
  final raw = Platform.environment[name]?.trim().toLowerCase();
  if (raw == null || raw.isEmpty) return defaultValue;
  return raw == '1' || raw == 'true' || raw == 'yes' || raw == 'on';
}

Duration _localHttpMcpIdleTimeout() {
  final raw = Platform.environment['TEALKIT_LOCAL_HTTP_MCP_IDLE_MINUTES']
      ?.trim();
  final minutes = int.tryParse(raw ?? '');
  if (minutes != null && minutes > 0) {
    return Duration(minutes: minutes);
  }
  return const Duration(minutes: 10);
}

void _cancelLocalHttpIdleShutdown(String serverId) {
  _mcpProxyLocalHttpIdleTimers.remove(serverId)?.cancel();
}

void _armLocalHttpIdleShutdown(String serverId) {
  if (!_mcpProxyLocalHttpProcesses.containsKey(serverId)) return;
  _cancelLocalHttpIdleShutdown(serverId);
  final timeout = _localHttpMcpIdleTimeout();
  _mcpProxyLocalHttpIdleTimers[serverId] = Timer(timeout, () async {
    log.info(
      '[API] Stopping idle local HTTP MCP proxy $serverId after ${timeout.inMinutes} minute(s) of inactivity',
    );
    await _stopMcpProxyServer(serverId, disposeClient: true);
  });
}

Future<void> _stopMcpProxyServer(
  String serverId, {
  bool disposeClient = true,
}) async {
  _cancelLocalHttpIdleShutdown(serverId);

  final internalImpl = _mcpProxyInternals.remove(serverId);
  if (internalImpl != null) {
    await internalImpl.dispose();
  }

  final client = _mcpProxyClients.remove(serverId);
  if (client != null && disposeClient) {
    client.dispose();
  }

  final proc = _mcpProxyProcesses.remove(serverId);
  if (proc != null) {
    proc.dispose();
  }

  final localHttp = _mcpProxyLocalHttpProcesses.remove(serverId);
  if (localHttp != null) {
    localHttp.kill();
  }

  await _mcpProxyLocalHttpStdoutSubs.remove(serverId)?.cancel();
  await _mcpProxyLocalHttpStderrSubs.remove(serverId)?.cancel();
  _mcpProxyTools.remove(serverId);
}

Future<Map<String, dynamic>?> _loadBundledMcpManifest() async {
  final explicit = Platform.environment['TEALKIT_BUNDLED_MCP_MANIFEST']?.trim();
  final candidates = <String>[
    if (explicit != null && explicit.isNotEmpty) explicit,
    p.join(Directory.current.path, 'config', 'bundled_mcp_servers.json'),
    p.join(
      Directory.current.path,
      'server',
      'config',
      'bundled_mcp_servers.json',
    ),
    '/app/config/bundled_mcp_servers.json',
  ];

  for (final path in candidates) {
    final file = File(path);
    if (!await file.exists()) continue;
    try {
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        log.info('[Bootstrap] Loaded bundled MCP manifest: $path');
        return decoded;
      }
    } catch (e) {
      log.warning('[Bootstrap] Failed to parse bundled MCP manifest $path: $e');
    }
  }

  log.info('[Bootstrap] No bundled MCP manifest found');
  return null;
}

Future<void> _copyDirectoryRecursive(
  Directory source,
  Directory target, {
  required bool overwrite,
}) async {
  if (!await target.exists()) {
    await target.create(recursive: true);
  }

  await for (final entity in source.list(
    recursive: false,
    followLinks: false,
  )) {
    final name = p.basename(entity.path);
    final outPath = p.join(target.path, name);
    if (entity is Directory) {
      await _copyDirectoryRecursive(
        entity,
        Directory(outPath),
        overwrite: overwrite,
      );
      continue;
    }
    if (entity is File) {
      final outFile = File(outPath);
      if (!overwrite && await outFile.exists()) {
        continue;
      }
      if (!await outFile.parent.exists()) {
        await outFile.parent.create(recursive: true);
      }
      await entity.copy(outPath);
    }
  }
}

List<Map<String, dynamic>> _manifestServers(Map<String, dynamic> manifest) {
  final raw = manifest['servers'];
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList(growable: false);
}

Future<void> _seedBundledMcpSources(Map<String, dynamic> manifest) async {
  final sourceRoot =
      Platform.environment['TEALKIT_BUNDLED_MCP_SOURCE_DIR']
              ?.trim()
              .isNotEmpty ==
          true
      ? Platform.environment['TEALKIT_BUNDLED_MCP_SOURCE_DIR']!.trim()
      : '/app/bundled_mcp';
  final overwrite = _envBool(
    'TEALKIT_BUNDLED_MCP_OVERWRITE',
    defaultValue: false,
  );
  final targetRoot = resolveServerMcpServersDir();
  final selectedIds = (Platform.environment['TEALKIT_BUNDLED_MCP_IDS'] ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet();

  for (final server in _manifestServers(manifest)) {
    final id = (server['id'] as String? ?? '').trim();
    if (id.isEmpty) continue;
    if (selectedIds.isNotEmpty && !selectedIds.contains(id)) continue;

    final bundle = server['bundle'];
    if (bundle is! Map) continue;
    final bundleMap = Map<String, dynamic>.from(bundle);
    final sourceSubdir = (bundleMap['sourceSubdir'] as String? ?? '').trim();
    final targetSubdir = (bundleMap['targetSubdir'] as String? ?? '').trim();
    if (sourceSubdir.isEmpty || targetSubdir.isEmpty) continue;

    final sourceDir = Directory(p.join(sourceRoot, sourceSubdir));
    if (!await sourceDir.exists()) {
      log.warning(
        '[Bootstrap] Bundled MCP source missing for $id: ${sourceDir.path}',
      );
      continue;
    }

    final targetDir = Directory(p.join(targetRoot, targetSubdir));
    if (await targetDir.exists() && !overwrite) {
      continue;
    }
    if (await targetDir.exists() && overwrite) {
      await targetDir.delete(recursive: true);
    }

    await _copyDirectoryRecursive(sourceDir, targetDir, overwrite: overwrite);
    log.info(
      '[Bootstrap] Seeded bundled MCP source for $id into ${targetDir.path}',
    );
  }
}

List<String> _asStringList(dynamic raw) {
  if (raw is List) {
    return raw.map((e) => e.toString()).toList(growable: false);
  }
  return const [];
}

Map<String, String> _asStringMap(dynamic raw) {
  if (raw is Map) {
    return Map<String, String>.from(
      raw.map((k, v) => MapEntry(k.toString(), v.toString())),
    );
  }
  return const {};
}

Future<void> _registerBundledMcpDefinitions(
  ServerDuckDbService db,
  Map<String, dynamic> manifest,
) async {
  final selectedIds = (Platform.environment['TEALKIT_BUNDLED_MCP_IDS'] ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet();

  final existing = await db.getAllGithubMcpServers();
  final existingById = <String, GithubMcpServerDefinition>{
    for (final s in existing) s.id: s,
  };

  for (final entry in _manifestServers(manifest)) {
    final id = (entry['id'] as String? ?? '').trim();
    if (id.isEmpty) continue;
    if (selectedIds.isNotEmpty && !selectedIds.contains(id)) continue;

    final defaults = _asStringMap(entry['envVars']);
    final old = existingById[id];
    final envVars = {...defaults, ...?old?.envVars};
    final now = DateTime.now();

    final def = GithubMcpServerDefinition(
      id: id,
      name: (entry['name'] as String? ?? id).trim(),
      displayName:
          (entry['displayName'] as String? ?? entry['name'] as String? ?? id)
              .trim(),
      description: (entry['description'] as String? ?? '').trim(),
      githubUrl: (entry['githubUrl'] as String? ?? 'bundled://$id').trim(),
      language: (entry['language'] as String? ?? 'python').trim(),
      installType: (entry['installType'] as String? ?? 'python').trim(),
      packageName: (entry['packageName'] as String? ?? id).trim(),
      entryPoint: (entry['entryPoint'] as String?)?.trim(),
      launchArgs: _asStringList(entry['launchArgs']),
      requiredEnvVars: _asStringList(entry['requiredEnvVars']),
      envVars: envVars,
      category: (entry['category'] as String? ?? 'other').trim(),
      isInstalled: true,
      isActive: old?.isActive ?? true,
      installedAt: old?.installedAt ?? now,
      createdAt: old?.createdAt ?? now,
    );

    await db.saveGithubMcpServer(def);
  }
}

Future<void> _bootstrapBundledMcpServers(ServerDuckDbService db) async {
  if (!_envBool('TEALKIT_BUNDLED_MCP_ENABLED', defaultValue: true)) {
    log.info('[Bootstrap] Bundled MCP bootstrap disabled by env');
    return;
  }

  final manifest = await _loadBundledMcpManifest();
  if (manifest == null) return;

  await _seedBundledMcpSources(manifest);
  await _registerBundledMcpDefinitions(db, manifest);
}

Future<void> main(List<String> args) async {
  log.info('[TealKit Server] Starting up...');

  await serverBootstrap();
  await startHttpServer();
}

/// Initialises all core services in order.
Future<void> serverBootstrap() async {
  final db = ServerDuckDbService();
  final dataDir = db.dataDir;

  log.info('[Bootstrap] Data directory: $dataDir');

  // 1. Encryption key (must be first — config service depends on it)
  await ServerCredentialCipher.instance.init(dataDir);
  InternalMcpEntry.encryptor = ServerCredentialCipher.instance.encryptParams;
  InternalMcpEntry.decryptor = ServerCredentialCipher.instance.decryptParams;

  // 2. Config service
  await ServerConfigService().init(dataDir);

  // 3. DuckDB
  await db.init();

  // 3.1 Seed and register bundled MCP servers (Docker full profile)
  await _bootstrapBundledMcpServers(db);

  // 4. Settings services
  await ServerLlmSettingsService.instance.load();
  await ServerDataSourcesService.instance.load();
  await ServerExternalToolsService.instance.load();
  await ServerPreferencesService.instance.load();
  await ServerModelDownloadService.instance.init();

  // 5. Scheduler
  ServerScheduler.instance.start();

  log.info('[Bootstrap] All services ready');

  // Graceful shutdown
  ProcessSignal.sigint.watch().listen((_) async {
    log.info('[Bootstrap] SIGINT received — shutting down');
    ServerScheduler.instance.stop();
    exit(0);
  });
  if (!Platform.isWindows) {
    try {
      ProcessSignal.sigterm.watch().listen((_) async {
        log.info('[Bootstrap] SIGTERM received — shutting down');
        ServerScheduler.instance.stop();
        exit(0);
      });
    } catch (_) {
      // SIGTERM not available on Windows
    }
  }
}

/// Starts the Shelf HTTP server on the port from the TEALKIT_PORT env var
/// (default: 7771).
Future<void> startHttpServer() async {
  final port = int.tryParse(Platform.environment['TEALKIT_PORT'] ?? '') ?? 7771;
  final host = Platform.environment['TEALKIT_HOST'] ?? 'localhost';

  final router = Router();

  // ── Health / status ─────────────────────────────
  router.get('/health', _handleHealth);
  router.get('/status', _handleStatus);

  // ── Tasks ────────────────────────────────────────
  router.get('/api/v1/tasks', _handleListTasks);
  router.get('/api/v1/tasks/<id>', _handleGetTask);
  router.post('/api/v1/tasks', _handleCreateTask);
  router.put('/api/v1/tasks/<id>', _handleUpdateTask);
  router.delete('/api/v1/tasks/<id>', _handleDeleteTask);
  router.post('/api/v1/tasks/<id>/run', _handleRunTask);
  router.get('/api/v1/tasks/<id>/run-status', _handleGetTaskRunStatus);
  router.post('/api/v1/tasks/<id>/cancel', _handleCancelTask);
  router.get('/api/v1/tasks/<id>/output', _handleGetTaskOutput);
  router.get('/api/v1/tasks/<id>/execution-logs', _handleGetTaskExecutionLogs);
  router.get('/api/v1/tasks/<id>/output-files', _handleGetTaskOutputFiles);
  router.get(
    '/api/v1/tasks/<id>/output/<runId>/<fileName>',
    _handleDownloadTaskOutputFile,
  );

  // ── LLM proxy (OpenAI-compatible pass-through) ───
  router.post('/api/v1/llm/chat/completions', _handleLlmChatCompletions);
  router.post('/api/v1/llm2/chat/completions', _handleLlm2ChatCompletions);

  // ── Embedded model downloads ─────────────────────
  router.post('/api/v1/models/downloads', _handleStartModelDownload);
  router.get('/api/v1/models/downloads/<jobId>', _handleGetModelDownload);
  router.post(
    '/api/v1/models/downloads/<jobId>/cancel',
    _handleCancelModelDownload,
  );
  router.get('/api/v1/models/files', _handleListModelFiles);
  router.delete('/api/v1/models/files/<filename>', _handleDeleteModelFile);
  router.get('/api/v1/models/loaded', _handleGetLoadedModel);
  router.post('/api/v1/models/load', _handleLoadModel);
  router.post('/api/v1/models/unload', _handleUnloadModel);
  router.get('/api/v1/models/custom', _handleGetCustomModels);
  router.post('/api/v1/models/custom', _handleSaveCustomModels);
  router.get('/api/v1/models/gpu', _handleGetGpuCapabilities);

  // ── Settings ─────────────────────────────────────
  router.get('/api/v1/settings/llm', _handleGetLlmSettings);
  router.put('/api/v1/settings/llm', _handlePutLlmSettings);
  router.get('/api/v1/ollama/models', _handleGetOllamaModels);
  router.get('/api/v1/settings/data-sources', _handleGetDataSourcesSettings);
  router.put('/api/v1/settings/data-sources', _handlePutDataSourcesSettings);
  router.get('/api/v1/settings/preferences', _handleGetPreferences);
  router.put('/api/v1/settings/preferences', _handlePutPreferences);
  router.get('/api/v1/settings/external-tools', _handleGetExternalTools);
  router.put('/api/v1/settings/external-tools', _handlePutExternalTools);

  // ── Scheduler log ─────────────────────────────────
  router.get('/api/v1/scheduler/log', _handleGetSchedulerLog);

  // ── Sync ──────────────────────────────────────────
  router.post('/api/v1/sync/tasks', _handleSyncTasks);
  router.post('/api/v1/sync/settings', _handleSyncSettings);
  router.get('/api/v1/sync/ssh_scripts', _handleGetSshScripts);
  router.post('/api/v1/sync/ssh_scripts', _handleSyncSshScripts);
  router.get('/api/v1/sync/py_tools', _handleGetPyTools);
  router.post('/api/v1/sync/py_tools', _handleSyncPyTools);
  router.get('/api/v1/sync/js_tools', _handleGetJsTools);
  router.post('/api/v1/sync/js_tools', _handleSyncJsTools);
  router.post('/api/v1/py_tools/<toolId>/init', _handleInitPyTool);
  router.post('/api/v1/py_tools/<toolId>/run', _handleRunPyTool);

  // ── Indexing ─────────────────────────────────────
  router.post('/api/v1/index/website/start', _handleStartWebsiteIndex);
  router.post('/api/v1/index/website/stop', _handleStopWebsiteIndex);
  router.get('/api/v1/index/website/status', _handleGetWebsiteIndexStatus);
  router.post('/api/v1/index/website/search', _handleSearchWebsiteIndex);
  router.get('/api/v1/index/website/pages', _handleListWebsitePages);
  router.get('/api/v1/index/website/page', _handleGetWebsitePage);
  router.post(
    '/api/v1/index/website/purge-stale',
    _handlePurgeStaleWebsiteIndex,
  );
  router.post('/api/v1/index/document/start', _handleStartDocumentIndex);
  router.post('/api/v1/index/document/stop', _handleStopDocumentIndex);
  router.get('/api/v1/index/document/status', _handleGetDocumentIndexStatus);
  router.post('/api/v1/index/document/search', _handleSearchDocumentIndex);
  router.get('/api/v1/index/document/list', _handleListDocumentIndex);
  router.get('/api/v1/index/document/entry', _handleGetDocumentIndexEntry);
  router.post(
    '/api/v1/index/document/purge-stale',
    _handlePurgeStaleDocumentIndex,
  );

  // ── MCP Proxy ─────────────────────────────────────
  router.get('/api/v1/mcp/servers', _handleListMcpServers);
  router.post('/api/v1/mcp/servers/<serverId|.+>/start', _handleStartMcpServer);
  router.post('/api/v1/mcp/servers/<serverId|.+>/stop', _handleStopMcpServer);
  router.get('/api/v1/mcp/servers/<serverId|.+>/tools', _handleGetMcpServerTools);
  router.post(
    '/api/v1/mcp/servers/<serverId|.+>/tools/<toolName>/call',
    _handleCallMcpTool,
  );
  router.get('/api/v1/mcp/servers/<serverId|.+>/events', _handleMcpServerEvents);

  // ── MCP Registry (install / manage) ───────────────────────────
  router.get('/api/v1/mcp/registry', _handleListRegistry);
  router.post('/api/v1/mcp/registry', _handleInstallRegistry);
  router.put('/api/v1/mcp/registry/<id>', _handleUpdateRegistry);
  router.delete('/api/v1/mcp/registry/<id>', _handleDeleteRegistry);
  router.post('/api/v1/mcp/registry/<id>/test', _handleTestRegistry);

  // ── Skills ────────────────────────────────────────────────────
  router.get('/api/v1/skills', _handleListSkills);
  router.put('/api/v1/skills', _handleSaveSkill);
  router.delete('/api/v1/skills/<id>', _handleDeleteSkill);
  router.delete('/api/v1/skills/tool/<name>', _handleDeleteSkillByToolName);
  router.post('/api/v1/skills/build', _handleBuildSkills);
  router.get('/api/v1/skills/build/status', _handleGetSkillsBuildStatus);

  // ── Playground Sessions ───────────────────────────────────────
  router.get('/api/v1/playground/sessions', _handleListPlaygroundSessions);
  router.post('/api/v1/playground/sessions', _handleSavePlaygroundSession);
  router.delete(
    '/api/v1/playground/sessions/<id>',
    _handleDeletePlaygroundSession,
  );

  final handler = Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_corsMiddleware())
      .addMiddleware(_apiKeyMiddleware())
      .addHandler(router.call);

  final server = await shelf_io.serve(handler, host, port);
  log.info('[HTTP] Listening on http://${server.address.host}:${server.port}');
}

// ── Middleware ───────────────────────────────────────────────

Middleware _corsMiddleware() {
  return (Handler innerHandler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: _corsHeaders());
      }
      final response = await innerHandler(request);
      return response.change(headers: _corsHeaders());
    };
  };
}

/// If the `TEALKIT_API_KEY` environment variable is set, every request must
/// carry a matching `Authorization: Bearer <key>` header.
/// The `/health` and `/status` endpoints are exempt.
Middleware _apiKeyMiddleware() {
  final allowedKeys = _parseApiKeysFromEnv(
    Platform.environment['TEALKIT_API_KEY'] ?? '',
  );
  if (allowedKeys.isEmpty) {
    // Auth disabled — pass everything through.
    return (Handler inner) => inner;
  }
  log.info(
    '[Auth] API key protection enabled (${allowedKeys.length} accepted key${allowedKeys.length == 1 ? '' : 's'})',
  );
  return (Handler innerHandler) {
    return (Request request) async {
      final path = request.url.path;
      // Exempt unauthenticated status probes.
      if (path == 'health' || path == 'status') {
        return innerHandler(request);
      }
      final authHeader =
          request.headers['authorization'] ??
          request.headers['Authorization'] ??
          '';
      final token = authHeader.startsWith('Bearer ')
          ? authHeader.substring(7).trim()
          : '';
      if (!allowedKeys.contains(token)) {
        log.warning(
          '[Auth] Rejected ${request.method} /$path — bad or missing API key',
        );
        return Response(
          401,
          body: jsonEncode({'error': 'Unauthorized'}),
          headers: {'Content-Type': 'application/json'},
        );
      }
      return innerHandler(request);
    };
  };
}

Set<String> _parseApiKeysFromEnv(String rawValue) {
  var raw = rawValue.trim();
  if (raw.isEmpty) return const <String>{};
  final stripQuotes = RegExp(r'''^['"]|['"]$''');

  // Strip leading/trailing single/double quotes around the entire value first.
  while ((raw.startsWith("'") && raw.endsWith("'")) ||
      (raw.startsWith('"') && raw.endsWith('"'))) {
    if (raw.length < 2) break;
    raw = raw.substring(1, raw.length - 1).trim();
  }

  // Backward-compatible default: a single key string.
  final single = raw.replaceAll(stripQuotes, '').trim();

  // Support JSON-style array values:
  //   TEALKIT_API_KEY=["k1","k2"]
  // and lenient bare-token arrays:
  //   TEALKIT_API_KEY=[k1,k2]
  if (raw.startsWith('[') && raw.endsWith(']')) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final keys = decoded
            .map((e) => e.toString().trim().replaceAll(stripQuotes, ''))
            .where((e) => e.isNotEmpty)
            .toSet();
        if (keys.isNotEmpty) return keys;
      }
    } catch (_) {
      final inner = raw.substring(1, raw.length - 1);
      final keys = inner
          .split(',')
          .map((e) => e.trim().replaceAll(stripQuotes, ''))
          .where((e) => e.isNotEmpty)
          .toSet();
      if (keys.isNotEmpty) return keys;
    }
  }

  // Support comma-separated list values:
  //   TEALKIT_API_KEY=k1,k2,k3
  if (raw.contains(',')) {
    final keys = raw
        .split(',')
        .map((e) => e.trim().replaceAll(stripQuotes, ''))
        .where((e) => e.isNotEmpty)
        .toSet();
    if (keys.isNotEmpty) return keys;
  }

  return single.isNotEmpty ? <String>{single} : const <String>{};
}

Map<String, String> _corsHeaders() => const {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
};

// ── Helpers ──────────────────────────────────────────────────

Response _json(Object body, {int status = 200}) => Response(
  status,
  body: jsonEncode(body),
  headers: {'Content-Type': 'application/json'},
);

Response _jsonError(String message, {int status = 400}) =>
    _json({'error': message}, status: status);

Future<Map<String, dynamic>?> _parseJsonBody(Request request) async {
  try {
    final body = await request.readAsString();
    if (body.isEmpty) return null;
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    return null;
  } catch (_) {
    return null;
  }
}

// ── Health / Status ──────────────────────────────────────────

Future<Response> _handleHealth(Request request) async {
  return _json({'status': 'ok', 'timestamp': DateTime.now().toIso8601String()});
}

Future<Response> _handleStatus(Request request) async {
  final llm = ServerLlmSettingsService.instance;
  return _json({
    'status': 'ok',
    'version': kServerVersion,
    'timestamp': DateTime.now().toIso8601String(),
    'llm': {
      'configured': llm.isConfigured,
      'provider': llm.provider.configKey,
      'model': llm.model,
    },
    'scheduler': {
      'running': ServerScheduler.instance.isRunning,
      'active_runs': _activeRuns.length,
    },
    'paths': {
      'data_dir': resolveServerDataDir(),
      'files_dir': resolveServerFilesDir(),
      'mcp_servers_dir': resolveServerMcpServersDir(),
    },
  });
}

// ── Tasks ────────────────────────────────────────────────────

Future<Response> _handleListTasks(Request request) async {
  try {
    final tasks = await ServerDuckDbService().getAllTasks();
    return _json({'tasks': tasks.map(_taskTransportJson).toList()});
  } catch (e) {
    log.error('[API] GET /tasks failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleGetTask(Request request, String id) async {
  try {
    final task = await ServerDuckDbService().getTask(id);
    if (task == null) return _jsonError('Not found', status: 404);
    return _json(_taskTransportJson(task));
  } catch (e) {
    log.error('[API] GET /tasks/$id failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleCreateTask(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  final title = body['title'] as String? ?? body['name'] as String?;
  final cronExpression =
      body['cron_expression'] as String? ??
      (body['execution_plan'] as Map?)?['cron_expression'] as String?;
  final llmPrompt = body['llm_prompt'] as String? ?? body['prompt'] as String?;

  if (title == null || title.trim().isEmpty) {
    return _jsonError('Missing required field: title');
  }
  if (llmPrompt == null || llmPrompt.trim().isEmpty) {
    return _jsonError('Missing required field: llm_prompt');
  }

  try {
    final now = DateTime.now();
    final taskId = _uuid.v4();

    // Build a minimal task from the body, using AgenticTask.fromJson if a
    // full payload is supplied, otherwise construct with required defaults.
    AgenticTask task;
    if (body.containsKey('id') || body.containsKey('execution_plan')) {
      // Full task payload — honour all supplied fields, overwrite id.
      final merged = Map<String, dynamic>.from(body);
      merged['id'] = taskId;
      merged['created_at'] = now.toIso8601String();
      merged['updated_at'] = now.toIso8601String();
      task = AgenticTask.fromJson(merged);
    } else {
      task = AgenticTask(
        id: taskId,
        name: title.trim(),
        prompt: llmPrompt.trim(),
        enabled: body['enabled'] as bool? ?? true,
        executionPlan: ExecutionPlan(cronExpression: cronExpression ?? ''),
        mcpTools: const [],
        internalMcps: const [],
        providers: const TaskProviders(),
        execution: TaskExecution(),
        notification: const TaskNotification(),
        tags: [],
        createdAt: now,
        updatedAt: now,
      );
    }

    await ServerDuckDbService().saveTask(task);
    return _json(_taskTransportJson(task), status: 201);
  } catch (e) {
    log.error('[API] POST /tasks failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleUpdateTask(Request request, String id) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  try {
    final db = ServerDuckDbService();
    final existing = await db.getTask(id);
    if (existing == null) return _jsonError('Not found', status: 404);

    // Merge: start from existing JSON, overlay with supplied fields.
    final merged = existing.toJson();
    final serverExecution = merged['execution'];
    _deepMerge(merged, body);
    if (serverExecution != null) {
      merged['execution'] = serverExecution;
    }
    merged['id'] = id; // id is immutable
    merged['updated_at'] = DateTime.now().toIso8601String();

    final updated = AgenticTask.fromJson(merged);
    await db.saveTask(updated);
    return _json(_taskTransportJson(updated));
  } catch (e) {
    log.error('[API] PUT /tasks/$id failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

/// Deep-merge [src] into [dst]. Lists are replaced, not appended.
void _deepMerge(Map<String, dynamic> dst, Map<String, dynamic> src) {
  for (final entry in src.entries) {
    final existing = dst[entry.key];
    if (existing is Map<String, dynamic> &&
        entry.value is Map<String, dynamic>) {
      _deepMerge(existing, entry.value as Map<String, dynamic>);
    } else {
      dst[entry.key] = entry.value;
    }
  }
}

Map<String, dynamic> _taskTransportJson(AgenticTask task) {
  final json = task.toJson();
  final isRunning = ServerScheduler.instance.isTaskRunning(task.id) ||
      _activeRuns.containsKey(task.id);
  if (json['execution'] is Map) {
    final execMap = Map<String, dynamic>.from(json['execution'] as Map);
    execMap['is_running'] = isRunning;
    json['execution'] = execMap;
  } else {
    json['execution'] = {'is_running': isRunning};
  }
  json['internal_mcps'] = task.internalMcps
      .map(_internalMcpTransportJson)
      .toList();
  json['executors'] = task.executors.map((exec) {
    final execJson = exec.toJson();
    execJson['internal_mcps'] = exec.internalMcps
        .map(_internalMcpTransportJson)
        .toList();
    return execJson;
  }).toList();
  return json;
}

Map<String, dynamic> _internalMcpTransportJson(InternalMcpEntry entry) => {
  'id': entry.id,
  'mcp_type': entry.mcpType,
  'label': entry.label,
  'init_params': entry.initParams,
  if (entry.systemPrompt != null) 'system_prompt': entry.systemPrompt,
  'enabled': entry.enabled,
};

Future<Response> _handleDeleteTask(Request request, String id) async {
  try {
    await ServerDuckDbService().deleteTask(id);
    return _json({'deleted': id});
  } catch (e) {
    log.error('[API] DELETE /tasks/$id failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleRunTask(Request request, String id) async {
  try {
    final db = ServerDuckDbService();
    final task = await db.getTask(id);
    if (task == null) return _jsonError('Not found', status: 404);

    if (_activeRuns.containsKey(id) ||
        ServerScheduler.instance.isTaskRunning(id)) {
      return _jsonError('agent is running already', status: 409);
    }

    final runId = _uuid.v4();
    final token = CancellationToken();
    _activeRuns[id] = token;
    ServerScheduler.instance.markTaskRunning(id);

    final runner = ServerTaskRunner(
      db: db,
      llmSettings: ServerLlmSettingsService.instance,
    );
    ServerLiveLog.start(id);

    // Fire-and-forget
    runner
        .runTask(task, cancellationToken: token)
        .then((_) {
          _activeRuns.remove(id);
          ServerScheduler.instance.markTaskFinished(id);
          ServerLiveLog.end(id);
        })
        .catchError((Object e) {
          log.error('[API] Run task $id error: $e');
          _activeRuns.remove(id);
          ServerScheduler.instance.markTaskFinished(id);
          ServerLiveLog.end(id);
        });

    return _json({
      'run_id': runId,
      'task_id': id,
      'status': 'accepted',
    }, status: 202);
  } catch (e) {
    log.error('[API] POST /tasks/$id/run failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleCancelTask(Request request, String id) async {
  final token = _activeRuns[id];
  if (token == null) {
    return _jsonError('No active run for task $id', status: 404);
  }
  token.cancel();
  return _json({'task_id': id, 'status': 'cancellation_requested'});
}

Future<Response> _handleGetTaskRunStatus(Request request, String id) async {
  return _json({'task_id': id, 'running': _activeRuns.containsKey(id)});
}

Future<Response> _handleGetTaskOutput(Request request, String id) async {
  try {
    final db = ServerDuckDbService();
    final dataDir = db.dataDir;
    final outputDir = Directory('$dataDir/output/$id');
    if (!await outputDir.exists()) {
      return _jsonError('No output found for task $id', status: 404);
    }

    final latestRunDir = await _pickLatestRunDirWithFiles(
      outputDir,
      preferOutputLog: true,
    );
    if (latestRunDir == null) {
      return _jsonError('No output files found', status: 404);
    }

    final runId = latestRunDir.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .last;
    final outputFile = File(p.join(latestRunDir.path, 'output.log'));
    if (!await outputFile.exists()) {
      return _jsonError('No output files found', status: 404);
    }
    final text = await outputFile.readAsString();
    final timestamp = runId;

    return _json({
      'run_id': runId,
      'task_id': id,
      'text': text,
      'timestamp': timestamp,
    });
  } catch (e) {
    log.error('[API] GET /tasks/$id/output failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleGetTaskExecutionLogs(Request request, String id) async {
  try {
    final db = ServerDuckDbService();
    final task = await db.getTask(id);
    if (task == null) return _jsonError('Not found', status: 404);

    // Return the execution history from the task model
    final executionHistory = task.execution.history;

    return _json({
      'task_id': id,
      'task_name': task.name,
      'execution_history': executionHistory.map((run) {
        final json = run.toJson();
        json['tool_calls'] = run.toolCallCount;
        return json;
      }).toList(),
      'last_run': task.execution.lastRun?.toIso8601String(),
      'last_result_summary': task.execution.lastResult,
      'last_error': task.execution.lastError,
      'live_logs': ServerLiveLog.get(id),
    });
  } catch (e) {
    log.error('[API] GET /tasks/$id/execution-logs failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleGetTaskOutputFiles(Request request, String id) async {
  try {
    final db = ServerDuckDbService();
    final dataDir = db.dataDir;
    final outputDir = Directory('$dataDir/output/$id');

    if (!await outputDir.exists()) {
      return _json({'task_id': id, 'files': []});
    }

    final runDirs = await outputDir
        .list()
        .where((e) => e is Directory)
        .cast<Directory>()
        .toList();
    if (runDirs.isEmpty) {
      return _json({'task_id': id, 'files': []});
    }

    // Prefer the newest run that actually has files to avoid transient
    // empty responses while a run directory is still being populated.
    final latestRunDir = await _pickLatestRunDirWithFiles(outputDir);
    if (latestRunDir == null) {
      return _json({'task_id': id, 'files': [], 'total_runs': runDirs.length});
    }

    final runId = latestRunDir.uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .last;
    final files = await latestRunDir
        .list()
        .where((e) => e is File)
        .cast<File>()
        .toList();

    final fileList = <Map<String, dynamic>>[];
    for (final file in files) {
      final fileName = file.uri.pathSegments.last;
      final stat = await file.stat();
      fileList.add({
        'filename': '$runId/$fileName',
        'name': fileName,
        'timestamp': runId,
        'size': stat.size,
      });
    }

    fileList.sort((a, b) {
      final aName = (a['name'] as String).toLowerCase();
      final bName = (b['name'] as String).toLowerCase();
      final aScore = _getFileSortScore(aName);
      final bScore = _getFileSortScore(bName);
      if (aScore != bScore) return aScore.compareTo(bScore);
      return aName.compareTo(bName);
    });

    return _json({
      'task_id': id,
      'run_id': runId,
      'files': fileList,
      'total_runs': runDirs.length,
    });
  } catch (e) {
    log.error('[API] GET /tasks/$id/output-files failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleDownloadTaskOutputFile(
  Request request,
  String id,
  String runId,
  String fileName,
) async {
  try {
    final db = ServerDuckDbService();
    final dataDir = db.dataDir;
    final decodedRunId = Uri.decodeComponent(runId).trim();
    final decodedFileName = Uri.decodeComponent(fileName).trim();

    // Security: deny traversal attempts in both segments.
    if (decodedRunId.isEmpty ||
        decodedRunId.contains('/') ||
        decodedRunId.contains('\\') ||
        decodedRunId.contains('..')) {
      return _jsonError('Invalid run id', status: 400);
    }
    if (decodedFileName.isEmpty ||
        decodedFileName.contains('/') ||
        decodedFileName.contains('\\') ||
        decodedFileName.contains('..')) {
      return _jsonError('Invalid filename', status: 400);
    }

    final filePath = p.join(
      dataDir,
      'output',
      id,
      decodedRunId,
      decodedFileName,
    );
    final file = File(filePath);
    if (!await file.exists()) {
      return _jsonError('File not found', status: 404);
    }

    final bytes = await file.readAsBytes();
    final ext = p.extension(decodedFileName).toLowerCase();
    return Response.ok(
      bytes,
      headers: {
        'content-type': _getMimeType(ext),
        'content-length': bytes.length.toString(),
        'content-disposition': 'attachment; filename="$decodedFileName"',
      },
    );
  } catch (e) {
    log.error('[API] GET /tasks/$id/output/$runId/$fileName failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Directory?> _pickLatestRunDirWithFiles(
  Directory outputDir, {
  bool preferOutputLog = false,
}) async {
  final runDirs = await outputDir
      .list()
      .where((e) => e is Directory)
      .cast<Directory>()
      .toList();
  if (runDirs.isEmpty) return null;

  runDirs.sort((a, b) => b.path.compareTo(a.path));
  for (final dir in runDirs) {
    if (preferOutputLog) {
      final outputLog = File(p.join(dir.path, 'output.log'));
      if (await outputLog.exists()) return dir;
    }

    final hasAnyFile = await dir.list().any((e) => e is File);
    if (hasAnyFile) return dir;
  }

  return null;
}

int _getFileSortScore(String fileName) {
  if (fileName == 'execution.log') return 0;
  if (fileName == 'output.html') return 1;
  if (fileName == 'output.log') return 2;
  if (fileName.endsWith('.json')) return 3;
  if (fileName.endsWith('.csv')) return 4;
  return 5;
}

String _getMimeType(String extension) {
  switch (extension) {
    case '.json':
      return 'application/json';
    case '.csv':
      return 'text/csv; charset=utf-8';
    case '.xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    case '.xls':
      return 'application/vnd.ms-excel';
    case '.pdf':
      return 'application/pdf';
    case '.html':
      return 'text/html; charset=utf-8';
    case '.txt':
    case '.log':
    case '.md':
      return 'text/plain; charset=utf-8';
    case '.xml':
      return 'application/xml';
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.gif':
      return 'image/gif';
    case '.svg':
      return 'image/svg+xml';
    default:
      return 'application/octet-stream';
  }
}

// ── Embedded models ─────────────────────────────────

Future<Response> _handleStartModelDownload(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  final url = body['url'] as String?;
  final filename = body['filename'] as String?;
  if (url == null || url.trim().isEmpty) {
    return _jsonError('Missing required field: url');
  }
  if (filename == null || filename.trim().isEmpty) {
    return _jsonError('Missing required field: filename');
  }

  try {
    final job = await ServerModelDownloadService.instance.startDownload(
      url: url.trim(),
      filename: filename.trim(),
      displayName: body['display_name'] as String?,
      requestedSizeBytes: (body['size_bytes'] as num?)?.toInt(),
    );
    return _json(job.toJson(), status: 202);
  } on ArgumentError catch (e) {
    return _jsonError(e.message.toString(), status: 400);
  } catch (e, st) {
    log.error('[API] POST /models/downloads failed: $e', e, st);
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleGetModelDownload(Request request, String jobId) async {
  try {
    final job = ServerModelDownloadService.instance.getJob(jobId);
    if (job == null) return _jsonError('Not found', status: 404);
    return _json(job.toJson());
  } catch (e, st) {
    log.error('[API] GET /models/downloads/$jobId failed: $e', e, st);
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleCancelModelDownload(
  Request request,
  String jobId,
) async {
  try {
    final ok = await ServerModelDownloadService.instance.cancelDownload(jobId);
    if (!ok) return _jsonError('Not found', status: 404);
    final job = ServerModelDownloadService.instance.getJob(jobId);
    return _json({'job_id': jobId, 'status': job?.status.name ?? 'cancelled'});
  } catch (e, st) {
    log.error('[API] POST /models/downloads/$jobId/cancel failed: $e', e, st);
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleListModelFiles(Request request) async {
  try {
    final files = await ServerModelDownloadService.instance.listFiles();
    return _json({'files': files.map((f) => f.toJson()).toList()});
  } catch (e, st) {
    log.error('[API] GET /models/files failed: $e', e, st);
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleDeleteModelFile(
  Request request,
  String filename,
) async {
  try {
    final decoded = Uri.decodeComponent(filename);
    final deleted = await ServerModelDownloadService.instance.deleteFile(
      decoded,
    );
    if (!deleted) return _jsonError('Not found', status: 404);
    return _json({'deleted': decoded});
  } on ArgumentError catch (e) {
    return _jsonError(e.message.toString(), status: 400);
  } catch (e, st) {
    log.error('[API] DELETE /models/files/$filename failed: $e', e, st);
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleGetLoadedModel(Request request) async {
  try {
    final adapter = ServerEmbeddedLlmAdapter.instance;
    final isLoaded = adapter.isLoaded;
    final path = adapter.loadedModelPath;
    return _json({
      'loaded': isLoaded,
      'filename': path != null ? p.basename(path) : null,
    });
  } catch (e, st) {
    log.error('[API] GET /models/loaded failed: $e', e, st);
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleLoadModel(Request request) async {
  try {
    final body = await _parseJsonBody(request);
    if (body == null || !body.containsKey('filename')) {
      return _jsonError('Missing filename in request body', status: 400);
    }
    final filename = body['filename'] as String;
    final modelPath = p.join(resolveServerModelsDir(), filename);
    if (!await File(modelPath).exists()) {
      return _jsonError('Model file not found on server', status: 404);
    }

    final gpuLayers = (body['gpuLayers'] as num?)?.toInt();

    final adapter = ServerEmbeddedLlmAdapter.instance;
    await adapter
        .initialize(modelPath, gpuLayers: gpuLayers)
        .timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw TimeoutException(
            'Timed out while loading embedded model "$filename".',
          ),
        );
    return _json({'status': 'loaded', 'filename': filename});
  } catch (e, st) {
    log.error('[API] POST /models/load failed: $e', e, st);
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleUnloadModel(Request request) async {
  try {
    await ServerEmbeddedLlmAdapter.instance.dispose();
    return _json({'status': 'unloaded'});
  } catch (e, st) {
    log.error('[API] POST /models/unload failed: $e', e, st);
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleGetGpuCapabilities(Request request) async {
  try {
    final adapter = ServerEmbeddedLlmAdapter.instance;
    final supported = await adapter.isGpuSupported();
    final vram = await adapter.getVramInfo();
    return _json({
      'supported': supported,
      'vram_total': vram.total,
      'vram_free': vram.free,
    });
  } catch (e, st) {
    log.error('[API] GET /models/gpu failed: $e', e, st);
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleGetCustomModels(Request request) async {
  try {
    final cfg = ServerConfigService();
    final raw = cfg.getString('embedded_llm_custom_models');
    if (raw == null || raw.isEmpty) {
      return _json({'models': []});
    }
    final decoded = jsonDecode(raw) as List<dynamic>;
    return _json({'models': decoded});
  } catch (e, st) {
    log.error('[API] GET /models/custom failed: $e', e, st);
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleSaveCustomModels(Request request) async {
  try {
    final body = await _parseJsonBody(request);
    if (body == null || !body.containsKey('models')) {
      return _jsonError('Missing models list in request body', status: 400);
    }
    final models = body['models'] as List<dynamic>;
    final cfg = ServerConfigService();
    await cfg.setString('embedded_llm_custom_models', jsonEncode(models));
    return _json({'status': 'saved'});
  } catch (e, st) {
    log.error('[API] POST /models/custom failed: $e', e, st);
    return _jsonError(e.toString(), status: 500);
  }
}

// ── LLM proxy ─────────────────────────────────────────────────

String _contentToText(dynamic content) {
  if (content == null) return '';
  if (content is String) return content;
  if (content is List) {
    final parts = <String>[];
    for (final item in content) {
      if (item is String && item.trim().isNotEmpty) {
        parts.add(item.trim());
      } else if (item is Map) {
        final text = (item['text'] ?? item['content'] ?? '').toString().trim();
        if (text.isNotEmpty) parts.add(text);
      }
    }
    return parts.join('\n');
  }
  return content.toString();
}

Map<String, dynamic> _openAiToolCallFromEmbedded(ServerEmbeddedToolCall tc) {
  return {
    'id': (tc.id ?? 'tool_${DateTime.now().microsecondsSinceEpoch}'),
    'type': 'function',
    'function': {'name': tc.name, 'arguments': jsonEncode(tc.arguments)},
  };
}

List<MCPTool> _parseOpenAiTools(dynamic rawTools) {
  if (rawTools is! List) return const <MCPTool>[];
  final out = <MCPTool>[];
  for (final item in rawTools) {
    if (item is! Map) continue;
    final function = item['function'];
    if (function is! Map) continue;
    final name = (function['name'] ?? '').toString().trim();
    if (name.isEmpty) continue;
    final description = (function['description'] ?? '').toString();
    final parameters = function['parameters'];
    out.add(
      MCPTool(
        name: name,
        description: description.isEmpty ? null : description,
        inputSchema: parameters is Map
            ? Map<String, dynamic>.from(parameters)
            : const <String, dynamic>{'type': 'object'},
      ),
    );
  }
  return out;
}

String _normalizeModelName(String value) {
  return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

Future<List<String>> _listEmbeddedModelFilenames() async {
  final dir = Directory(resolveServerModelsDir());
  if (!await dir.exists()) return const <String>[];

  final names = <String>[];
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    if (name.startsWith('.')) continue;
    if (name.endsWith('.part')) continue;
    names.add(name);
  }
  return names;
}

Future<String?> _resolveEmbeddedModelFilename(String rawModel) async {
  final requested = rawModel.trim();
  if (requested.isEmpty) return null;

  final modelPath = p.join(resolveServerModelsDir(), requested);
  if (await File(modelPath).exists()) return requested;

  final available = await _listEmbeddedModelFilenames();
  if (available.isEmpty) return null;

  for (final name in available) {
    if (name.toLowerCase() == requested.toLowerCase()) {
      return name;
    }
  }

  final requestedNormalized = _normalizeModelName(requested);
  if (requestedNormalized.isEmpty) return null;

  for (final name in available) {
    if (_normalizeModelName(name) == requestedNormalized) {
      return name;
    }
  }

  for (final name in available) {
    final normalized = _normalizeModelName(name);
    if (normalized.contains(requestedNormalized) ||
        requestedNormalized.contains(normalized)) {
      return name;
    }
  }

  return null;
}

Future<Response> _handleEmbeddedChatCompletions(
  Map<String, dynamic> reqBody,
  ServerLlmSettingsService llm,
) async {
  final stream = reqBody['stream'] as bool? ?? false;
  if (stream) {
    return _jsonError(
      'Embedded provider does not support streaming on this endpoint yet. Use non-stream requests.',
      status: 400,
    );
  }

  final rawSelectedModel = ((reqBody['model'] ?? llm.model) as String? ?? '')
      .trim();
  if (rawSelectedModel.isEmpty) {
    return _jsonError('Embedded model is not configured', status: 400);
  }

  final selectedModel = await _resolveEmbeddedModelFilename(rawSelectedModel);
  if (selectedModel == null) {
    final modelPath = p.join(resolveServerModelsDir(), rawSelectedModel);
    return _jsonError(
      'Embedded model file not found on server: $rawSelectedModel (expected at $modelPath)',
      status: 404,
    );
  }

  if (selectedModel != rawSelectedModel) {
    log.info(
      '[LlmProxy:embedded] Resolved model "$rawSelectedModel" -> "$selectedModel"',
    );
  }

  final modelPath = p.join(resolveServerModelsDir(), selectedModel);

  final rawMessages = reqBody['messages'];
  if (rawMessages is! List || rawMessages.isEmpty) {
    return _jsonError('Invalid request: messages[] is required', status: 400);
  }

  final toolNameById = <String, String>{};
  final messages = <ServerEmbeddedChatMessage>[];
  for (final raw in rawMessages) {
    if (raw is! Map) continue;
    final msg = Map<String, dynamic>.from(raw);
    final role = (msg['role'] ?? '').toString().trim();
    final content = _contentToText(msg['content']);

    switch (role) {
      case 'system':
        messages.add(ServerEmbeddedChatMessage.system(content));
        break;
      case 'user':
        messages.add(ServerEmbeddedChatMessage.human(content));
        break;
      case 'assistant':
        final calls = <ServerEmbeddedToolCall>[];
        final toolCalls = msg['tool_calls'];
        if (toolCalls is List) {
          for (final tcRaw in toolCalls) {
            if (tcRaw is! Map) continue;
            final tc = Map<String, dynamic>.from(tcRaw);
            final id = (tc['id'] ?? '').toString().trim();
            final function = tc['function'];
            if (function is! Map) continue;
            final fn = Map<String, dynamic>.from(function);
            final name = (fn['name'] ?? '').toString().trim();
            if (name.isEmpty) continue;

            Map<String, dynamic> arguments = <String, dynamic>{};
            final argsRaw = fn['arguments'];
            if (argsRaw is String && argsRaw.trim().isNotEmpty) {
              try {
                final parsed = jsonDecode(argsRaw);
                if (parsed is Map) {
                  arguments = Map<String, dynamic>.from(parsed);
                }
              } catch (_) {}
            } else if (argsRaw is Map) {
              arguments = Map<String, dynamic>.from(argsRaw);
            }

            if (id.isNotEmpty) {
              toolNameById[id] = name;
            }
            calls.add(
              ServerEmbeddedToolCall(
                id: id.isEmpty ? null : id,
                name: name,
                arguments: arguments,
              ),
            );
          }
        }
        messages.add(ServerEmbeddedChatMessage.ai(content, toolCalls: calls));
        break;
      case 'tool':
        final toolCallId = (msg['tool_call_id'] ?? '').toString().trim();
        final toolName = toolCallId.isNotEmpty
            ? (toolNameById[toolCallId] ?? 'tool')
            : 'tool';
        messages.add(
          ServerEmbeddedChatMessage.toolResult(
            toolCallId: toolCallId.isEmpty
                ? 'tool_${DateTime.now().microsecondsSinceEpoch}'
                : toolCallId,
            toolName: toolName,
            content: content,
          ),
        );
        break;
      default:
        // Ignore unknown roles to stay permissive with clients.
        break;
    }
  }

  if (messages
      .where(
        (m) =>
            m.role == ServerEmbeddedChatRole.human ||
            m.role == ServerEmbeddedChatRole.tool,
      )
      .isEmpty) {
    return _jsonError(
      'Invalid request: no user/tool conversation content found',
      status: 400,
    );
  }

  final tools = _parseOpenAiTools(reqBody['tools']);
  final temp = (reqBody['temperature'] as num?)?.toDouble() ?? llm.temperature;
  final maxTokens = (reqBody['max_tokens'] as num?)?.toInt() ?? llm.maxTokens;

  final adapter = ServerEmbeddedLlmAdapter.instance;
  try {
    final result = await adapter.runExclusive(() async {
      await adapter
          .initialize(modelPath)
          .timeout(
            const Duration(minutes: 2),
            onTimeout: () => throw TimeoutException(
              'Timed out while loading embedded model "$selectedModel".',
            ),
          );

      return await adapter
          .generateResponse(
            messages: messages,
            availableTools: tools,
            temperature: temp,
            maxTokens: maxTokens > 0 ? maxTokens : 1024,
          )
          .timeout(
            const Duration(minutes: 5),
            onTimeout: () => throw TimeoutException(
              'Timed out waiting for embedded model response.',
            ),
          );
    }, waitTimeout: const Duration(minutes: 3));

    final message = <String, dynamic>{
      'role': 'assistant',
      'content': result.content,
    };
    if (result.toolCalls.isNotEmpty) {
      message['tool_calls'] = result.toolCalls
          .map(_openAiToolCallFromEmbedded)
          .toList();
    }

    final response = {
      'id': 'chatcmpl_${DateTime.now().microsecondsSinceEpoch}',
      'object': 'chat.completion',
      'created': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'model': selectedModel,
      'choices': [
        {
          'index': 0,
          'message': message,
          'finish_reason': result.toolCalls.isNotEmpty ? 'tool_calls' : 'stop',
        },
      ],
      'usage': {'prompt_tokens': 0, 'completion_tokens': 0, 'total_tokens': 0},
    };

    return _json(response, status: 200);
  } catch (e) {
    log.error('[LlmProxy:embedded] Error: $e');
    return _jsonError('Embedded LLM error: $e', status: 502);
  }
}

/// Converts an OpenAI-format chat/completions request to a form that Ollama's
/// `/v1/chat/completions` endpoint accepts.
///
/// Uses a whitelist of known-supported fields so that any future OpenAI-specific
/// extension is automatically excluded rather than causing HTTP 400 errors.
String _sanitizeBodyForOllama(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return body;

    // Whitelist: only pass fields that Ollama's OpenAI-compat endpoint supports.
    const allowedTopLevel = {
      'model', 'messages', 'stream',
      'temperature', 'top_p', 'seed',
      'max_tokens', // Ollama uses max_tokens, NOT max_completion_tokens
      'stop',
      'presence_penalty', 'frequency_penalty',
      'tools', 'tool_choice',
      'n',
    };

    final sanitized = <String, dynamic>{};
    for (final key in allowedTopLevel) {
      if (decoded.containsKey(key)) sanitized[key] = decoded[key];
    }

    // Remove `strict` from tool function schemas — not supported by Ollama.
    final tools = sanitized['tools'];
    if (tools is List) {
      for (final tool in tools) {
        if (tool is! Map<String, dynamic>) continue;
        final fn = tool['function'];
        if (fn is Map<String, dynamic>) fn.remove('strict');
      }
    }

    return jsonEncode(sanitized);
  } catch (_) {
    return body;
  }
}

/// Streaming OpenAI-compatible proxy that forwards `/api/v1/llm/chat/completions`
/// to the server's configured LLM provider, substituting the server's API key.
/// Supported providers: openai, openai_compatible, mistral, gemini, ollama.
Future<Response> _handleLlmChatCompletions(Request request) async {
  final llm = ServerLlmSettingsService.instance;
  if (!llm.isConfigured) {
    return _jsonError('LLM not configured on server', status: 503);
  }

  final body = await request.readAsString();
  Map<String, dynamic>? reqBody;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      reqBody = decoded;
    }
  } catch (_) {}

  final requestedModel = ((reqBody?['model']) as String? ?? '').trim();
  final resolvedEmbeddedModel = await _resolveEmbeddedModelFilename(
    requestedModel,
  );
  final requestedModelLooksEmbedded = resolvedEmbeddedModel != null;

  if (llm.provider == LlmProvider.embedded || requestedModelLooksEmbedded) {
    if (requestedModelLooksEmbedded &&
        reqBody != null &&
        resolvedEmbeddedModel != requestedModel) {
      reqBody['model'] = resolvedEmbeddedModel;
      log.info(
        '[LlmProxy] Normalized embedded model "$requestedModel" -> "$resolvedEmbeddedModel"',
      );
    }
    if (requestedModelLooksEmbedded && llm.provider != LlmProvider.embedded) {
      log.info(
        '[LlmProxy] Auto-routing chat/completions to embedded model "$resolvedEmbeddedModel" (global provider is ${llm.provider.configKey})',
      );
    }
    return _handleEmbeddedChatCompletions(
      reqBody ?? const <String, dynamic>{},
      llm,
    );
  }

  // Determine upstream URL + auth based on provider (checking headers and auto-detecting from model name)
  LlmProvider resolvedProvider = llm.provider;
  final headerProvider = request.headers['x-llm-provider'] ?? request.headers['X-Llm-Provider'];
  if (headerProvider != null && headerProvider.isNotEmpty) {
    resolvedProvider = LlmProvider.fromConfigKey(headerProvider);
  } else if (requestedModel.isNotEmpty) {
    final modelLower = requestedModel.toLowerCase();
    if (modelLower.contains('gemini')) {
      resolvedProvider = LlmProvider.gemini;
    } else if (modelLower.startsWith('gpt-') || modelLower.startsWith('o1-') || modelLower.startsWith('o3-')) {
      resolvedProvider = LlmProvider.openai;
    } else if (modelLower.contains('mistral') || modelLower.startsWith('pixtral') || modelLower.startsWith('open-mixtral')) {
      resolvedProvider = LlmProvider.mistral;
    }
  }

  String upstreamBase;
  String? upstreamAuth;
  
  final headerBaseUrl = request.headers['x-llm-base-url'] ?? request.headers['X-Llm-Base-Url'];
  final headerApiKey = request.headers['x-llm-api-key'] ?? request.headers['X-Llm-Api-Key'];

  switch (resolvedProvider) {
    case LlmProvider.openai:
      upstreamBase = 'https://api.openai.com/v1';
      upstreamAuth = headerApiKey ?? llm.getApiKeyForProvider(LlmProvider.openai);
    case LlmProvider.mistral:
      upstreamBase = 'https://api.mistral.ai/v1';
      upstreamAuth = headerApiKey ?? llm.getApiKeyForProvider(LlmProvider.mistral);
    case LlmProvider.gemini:
      // Google exposes an OpenAI-compatible endpoint under this path
      upstreamBase = 'https://generativelanguage.googleapis.com/v1beta/openai';
      upstreamAuth = headerApiKey ?? llm.getApiKeyForProvider(LlmProvider.gemini);
    case LlmProvider.ollama:
      final base = (headerBaseUrl ?? llm.getBaseUrlForProvider(LlmProvider.ollama));
      final cleanBase = (base.isNotEmpty ? base : 'http://localhost:11434')
          .trimRight()
          .replaceAll(RegExp(r'/+$'), '');
      upstreamBase = '$cleanBase/v1';
      upstreamAuth = headerApiKey ?? (llm.getApiKeyForProvider(LlmProvider.ollama).isNotEmpty ? llm.getApiKeyForProvider(LlmProvider.ollama) : null);
    case LlmProvider.openaiCompatible:
      final base = (headerBaseUrl ?? llm.getBaseUrlForProvider(LlmProvider.openaiCompatible));
      upstreamBase = base.trimRight().replaceAll(RegExp(r'/+$'), '');
      upstreamAuth = headerApiKey ?? (llm.getApiKeyForProvider(LlmProvider.openaiCompatible).isNotEmpty ? llm.getApiKeyForProvider(LlmProvider.openaiCompatible) : null);
    default:
      return _jsonError(
        'Provider "${resolvedProvider.label}" is not supported by LLM proxy',
        status: 400,
      );
  }

  final upstreamUrl = '$upstreamBase/chat/completions';
  final isOllama1 = resolvedProvider == LlmProvider.ollama;

  try {
    final effectiveBody = isOllama1 ? _sanitizeBodyForOllama(body) : body;
    if (isOllama1) {
      log.debug(
        '[LlmProxy] Sanitized Ollama request body: ${effectiveBody.length > 500 ? "${effectiveBody.substring(0, 500)}…" : effectiveBody}',
      );
    }
    final bodyBytes = utf8.encode(effectiveBody);
    final client = HttpClient();
    final httpRequest = await client.postUrl(Uri.parse(upstreamUrl));
    httpRequest.contentLength =
        bodyBytes.length; // avoid chunked encoding through tunnels
    httpRequest.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/json; charset=utf-8',
    );
    if (upstreamAuth != null && upstreamAuth.isNotEmpty) {
      httpRequest.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $upstreamAuth',
      );
    }
    // Forward Accept so streaming SSE requests are handled correctly upstream
    final acceptHeader = request.headers['accept'] ?? request.headers['Accept'];
    if (acceptHeader != null) {
      httpRequest.headers.set(HttpHeaders.acceptHeader, acceptHeader);
    }
    httpRequest.add(bodyBytes);

    final httpResponse = await httpRequest.close();
    log.info(
      '[LlmProxy] ${resolvedProvider.configKey} → $upstreamUrl — HTTP ${httpResponse.statusCode}',
    );

    final contentType =
        httpResponse.headers.contentType?.toString() ?? 'application/json';

    if (httpResponse.statusCode >= 400) {
      final errorBody = await utf8.decodeStream(httpResponse);
      log.error('[LlmProxy] Upstream error body: $errorBody');
      return Response(
        httpResponse.statusCode,
        body: errorBody,
        headers: {
          'Content-Type': contentType,
          'X-Proxy-Provider': resolvedProvider.configKey,
        },
      );
    }

    return Response(
      httpResponse.statusCode,
      body: httpResponse.cast<List<int>>(),
      headers: {
        'Content-Type': contentType,
        'X-Proxy-Provider': resolvedProvider.configKey,
      },
    );
  } catch (e) {
    log.error('[LlmProxy] Error proxying to $upstreamUrl: $e');
    return _jsonError('LLM proxy error: $e', status: 502);
  }
}

/// Streaming OpenAI-compatible proxy for LLM 2 — forwards `/api/v1/llm2/chat/completions`
/// to the server's configured LLM 2 provider, substituting the server's LLM 2 API key.
Future<Response> _handleLlm2ChatCompletions(Request request) async {
  final llm = ServerLlmSettingsService.instance;
  if (!llm.isConfigured2) {
    return _jsonError('LLM 2 not configured on server', status: 503);
  }

  final body = await request.readAsString();
  Map<String, dynamic>? reqBody;
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      reqBody = decoded;
    }
  } catch (_) {}

  final requestedModel = ((reqBody?['model']) as String? ?? '').trim();

  // Determine upstream URL + auth based on provider2 (checking headers and auto-detecting from model name)
  LlmProvider resolvedProvider = llm.provider2;
  final headerProvider = request.headers['x-llm-provider'] ?? request.headers['X-Llm-Provider'];
  if (headerProvider != null && headerProvider.isNotEmpty) {
    resolvedProvider = LlmProvider.fromConfigKey(headerProvider);
  } else if (requestedModel.isNotEmpty) {
    final modelLower = requestedModel.toLowerCase();
    if (modelLower.contains('gemini')) {
      resolvedProvider = LlmProvider.gemini;
    } else if (modelLower.startsWith('gpt-') || modelLower.startsWith('o1-') || modelLower.startsWith('o3-')) {
      resolvedProvider = LlmProvider.openai;
    } else if (modelLower.contains('mistral') || modelLower.startsWith('pixtral') || modelLower.startsWith('open-mixtral')) {
      resolvedProvider = LlmProvider.mistral;
    }
  }

  String upstreamBase;
  String? upstreamAuth;
  
  final headerBaseUrl = request.headers['x-llm-base-url'] ?? request.headers['X-Llm-Base-Url'];
  final headerApiKey = request.headers['x-llm-api-key'] ?? request.headers['X-Llm-Api-Key'];

  switch (resolvedProvider) {
    case LlmProvider.openai:
      upstreamBase = 'https://api.openai.com/v1';
      upstreamAuth = headerApiKey ?? llm.apiKey2;
    case LlmProvider.mistral:
      upstreamBase = 'https://api.mistral.ai/v1';
      upstreamAuth = headerApiKey ?? llm.apiKey2;
    case LlmProvider.gemini:
      upstreamBase = 'https://generativelanguage.googleapis.com/v1beta/openai';
      upstreamAuth = headerApiKey ?? llm.apiKey2;
    case LlmProvider.ollama:
      final base = (headerBaseUrl ?? (llm.baseUrl2.isNotEmpty ? llm.baseUrl2 : 'http://localhost:11434'))
          .trimRight()
          .replaceAll(RegExp(r'/+$'), '');
      final cleanBase = base.endsWith('/api') ? base.substring(0, base.length - 4) : base;
      upstreamBase = '$cleanBase/v1';
      upstreamAuth = headerApiKey ?? (llm.apiKey2.isNotEmpty ? llm.apiKey2 : null);
    case LlmProvider.openaiCompatible:
      final base = (headerBaseUrl ?? llm.baseUrl2).trimRight().replaceAll(RegExp(r'/+$'), '');
      upstreamBase = base;
      upstreamAuth = headerApiKey ?? (llm.apiKey2.isNotEmpty ? llm.apiKey2 : null);
    default:
      return _jsonError(
        'LLM 2 provider "${resolvedProvider.label}" is not supported by LLM proxy',
        status: 400,
      );
  }

  final upstreamUrl = '$upstreamBase/chat/completions';
  final isOllama2 = resolvedProvider == LlmProvider.ollama;

  try {
    final effectiveBody = isOllama2 ? _sanitizeBodyForOllama(body) : body;
    if (isOllama2) {
      log.debug(
        '[LlmProxy2] Sanitized Ollama request body: ${effectiveBody.length > 500 ? "${effectiveBody.substring(0, 500)}…" : effectiveBody}',
      );
    }
    final bodyBytes = utf8.encode(effectiveBody);
    final client = HttpClient();
    final httpRequest = await client.postUrl(Uri.parse(upstreamUrl));
    httpRequest.contentLength =
        bodyBytes.length; // avoid chunked encoding through tunnels
    httpRequest.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/json; charset=utf-8',
    );
    if (upstreamAuth != null && upstreamAuth.isNotEmpty) {
      httpRequest.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $upstreamAuth',
      );
    }
    final acceptHeader = request.headers['accept'] ?? request.headers['Accept'];
    if (acceptHeader != null) {
      httpRequest.headers.set(HttpHeaders.acceptHeader, acceptHeader);
    }
    httpRequest.add(bodyBytes);

    final httpResponse = await httpRequest.close();
    log.info(
      '[LlmProxy2] ${resolvedProvider.configKey} → $upstreamUrl — HTTP ${httpResponse.statusCode}',
    );

    final contentType =
        httpResponse.headers.contentType?.toString() ?? 'application/json';

    // On error, read and log the full response body to help diagnose the problem.
    if (httpResponse.statusCode >= 400) {
      final errorBody = await utf8.decodeStream(httpResponse);
      log.error('[LlmProxy2] Upstream error body: $errorBody');
      return Response(
        httpResponse.statusCode,
        body: errorBody,
        headers: {
          'Content-Type': contentType,
          'X-Proxy-Provider': resolvedProvider.configKey,
        },
      );
    }

    return Response(
      httpResponse.statusCode,
      body: httpResponse.cast<List<int>>(),
      headers: {
        'Content-Type': contentType,
        'X-Proxy-Provider': resolvedProvider.configKey,
      },
    );
  } catch (e) {
    log.error('[LlmProxy2] Error proxying to $upstreamUrl: $e');
    return _jsonError('LLM 2 proxy error: $e', status: 502);
  }
}

// ── Settings ─────────────────────────────────────────────────

Future<Response> _handleGetLlmSettings(Request request) async {
  final llm = ServerLlmSettingsService.instance;
  return _json({
    'provider': llm.provider.configKey,
    'model': llm.model,
    'api_key': llm.apiKey,
    'base_url': llm.baseUrl,
    'configured': llm.isConfigured,
    'temperature': llm.temperature,
    'max_tokens': llm.maxTokens,
    'is_slm': llm.isSlm,
    'thinking': llm.thinking,
    'use_native_tool_call': llm.useNativeToolCall,
    'use_safe_tool_call': llm.useSafeToolCall,
    'enable_tool_parameter_auto_recovery': llm.enableToolParameterAutoRecovery,
    'top_k': llm.topK,
    'top_p': llm.topP,
    'repeat_penalty': llm.repeatPenalty,
    'seed': llm.seed,
    'max_tool_output_size': llm.maxToolOutputSize,
    'token_warning_threshold': llm.tokenWarningThreshold,
    'is_multi_modal': llm.isMultiModal,
    'provider2': llm.provider2.configKey,
    'model2': llm.model2,
    'api_key2': llm.apiKey2,
    'base_url2': llm.baseUrl2,
    'configured2': llm.isConfigured2,
    'temperature2': llm.temperature2,
    'max_tokens2': llm.maxTokens2,
    'is_slm2': llm.isSlm2,
    'thinking2': llm.thinking2,
    'use_native_tool_call2': llm.useNativeToolCall2,
    'use_safe_tool_call2': llm.useSafeToolCall2,
    'top_k2': llm.topK2,
    'top_p2': llm.topP2,
    'repeat_penalty2': llm.repeatPenalty2,
    'seed2': llm.seed2,
    'max_tool_output_size2': llm.maxToolOutputSize2,
    'token_warning_threshold2': llm.tokenWarningThreshold2,
    'is_multi_modal2': llm.isMultiModal2,
  });
}

Future<Response> _handlePutLlmSettings(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  final provider = body.containsKey('provider')
      ? LlmProvider.fromConfigKey(body['provider'] as String?)
      : null;
  final provider2 = body.containsKey('provider2')
      ? LlmProvider.fromConfigKey(body['provider2'] as String?)
      : null;

  try {
    final llm = ServerLlmSettingsService.instance;
    if (body.containsKey('provider')) {
      await llm.setProvider(provider!);
    }
    if (body.containsKey('model')) await llm.setModel(body['model'] as String);
    if (body.containsKey('api_key')) {
      await llm.setApiKey(body['api_key'] as String);
    }
    if (body.containsKey('base_url')) {
      await llm.setBaseUrl(body['base_url'] as String);
    }
    if (body.containsKey('temperature')) {
      await llm.setTemperature((body['temperature'] as num).toDouble());
    }
    if (body.containsKey('max_tokens')) {
      await llm.setMaxTokens(body['max_tokens'] as int);
    }
    if (body.containsKey('max_tool_output_size')) {
      await llm.setMaxToolOutputSize(body['max_tool_output_size'] as int);
    }
    if (body.containsKey('token_warning_threshold')) {
      await llm.setTokenWarningThreshold(
        body['token_warning_threshold'] as int,
      );
    }
    if (body.containsKey('is_slm')) {
      await llm.setIsSlm(body['is_slm'] as bool);
    }
    if (body.containsKey('is_multi_modal')) {
      await llm.setIsMultiModal(body['is_multi_modal'] as bool);
    }
    if (body.containsKey('top_k')) {
      await llm.setTopK(body['top_k'] as int?);
    }
    if (body.containsKey('top_p')) {
      await llm.setTopP((body['top_p'] as num?)?.toDouble());
    }
    if (body.containsKey('repeat_penalty')) {
      await llm.setRepeatPenalty((body['repeat_penalty'] as num?)?.toDouble());
    }
    if (body.containsKey('seed')) {
      await llm.setSeed(body['seed'] as int?);
    }
    if (body.containsKey('provider2')) {
      await llm.setProvider2(provider2!);
    }
    if (body.containsKey('model2')) {
      await llm.setModel2(body['model2'] as String);
    }
    if (body.containsKey('api_key2')) {
      await llm.setApiKey2(body['api_key2'] as String);
    }
    if (body.containsKey('base_url2')) {
      await llm.setBaseUrl2(body['base_url2'] as String);
    }
    if (body.containsKey('temperature2')) {
      await llm.setTemperature2((body['temperature2'] as num).toDouble());
    }
    if (body.containsKey('max_tokens2')) {
      await llm.setMaxTokens2(body['max_tokens2'] as int);
    }
    if (body.containsKey('max_tool_output_size2')) {
      await llm.setMaxToolOutputSize2(body['max_tool_output_size2'] as int);
    }
    if (body.containsKey('token_warning_threshold2')) {
      await llm.setTokenWarningThreshold2(
        body['token_warning_threshold2'] as int,
      );
    }
    if (body.containsKey('is_slm2')) {
      await llm.setIsSlm2(body['is_slm2'] as bool);
    }
    if (body.containsKey('is_multi_modal2')) {
      await llm.setIsMultiModal2(body['is_multi_modal2'] as bool);
    }
    if (body.containsKey('top_k2')) {
      await llm.setTopK2(body['top_k2'] as int?);
    }
    if (body.containsKey('top_p2')) {
      await llm.setTopP2((body['top_p2'] as num?)?.toDouble());
    }
    if (body.containsKey('repeat_penalty2')) {
      await llm.setRepeatPenalty2(
        (body['repeat_penalty2'] as num?)?.toDouble(),
      );
    }
    if (body.containsKey('seed2')) {
      await llm.setSeed2(body['seed2'] as int?);
    }
    if (body.containsKey('thinking')) {
      await llm.setThinking(body['thinking'] as bool);
    }
    if (body.containsKey('thinking2')) {
      await llm.setThinking2(body['thinking2'] as bool);
    }
    if (body.containsKey('use_native_tool_call')) {
      await llm.setUseNativeToolCall(body['use_native_tool_call'] as bool);
    }
    if (body.containsKey('use_safe_tool_call')) {
      await llm.setUseSafeToolCall(body['use_safe_tool_call'] as bool);
    }
    if (body.containsKey('enable_tool_parameter_auto_recovery')) {
      await llm.setEnableToolParameterAutoRecovery(
        body['enable_tool_parameter_auto_recovery'] as bool,
      );
    }
    if (body.containsKey('use_native_tool_call2')) {
      await llm.setUseNativeToolCall2(body['use_native_tool_call2'] as bool);
    }
    if (body.containsKey('use_safe_tool_call2')) {
      await llm.setUseSafeToolCall2(body['use_safe_tool_call2'] as bool);
    }
    return _json({'status': 'saved'});
  } catch (e) {
    log.error('[API] PUT /settings/llm failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

/// Proxies an Ollama `/api/tags` request from the server side so that mobile
/// clients in server mode can fetch the Ollama model list without needing
/// direct network access to the Ollama host.
///
/// Query params:
///   base_url – Ollama base URL (default: http://localhost:11434)
///   api_key  – Optional Bearer token
Future<Response> _handleGetOllamaModels(Request request) async {
  final params = request.url.queryParameters;
  final baseUrl = (params['base_url'] ?? '').trim();
  final apiKey = (params['api_key'] ?? '').trim();
  final base = (baseUrl.isEmpty ? 'http://localhost:11434' : baseUrl)
      .replaceAll(RegExp(r'/+$'), '');
  final tagsBase = base.endsWith('/api') ? base : '$base/api';
  final url = Uri.parse('$tagsBase/tags');
  final headers = <String, String>{};
  if (apiKey.isNotEmpty) headers['Authorization'] = 'Bearer $apiKey';
  try {
    final resp = await http
        .get(url, headers: headers)
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (data['models'] as List<dynamic>? ?? [])
          .map((m) => (m as Map<String, dynamic>)['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .toList();
      return _json({'models': list});
    } else {
      return _jsonError(
        'Could not fetch Ollama models: HTTP ${resp.statusCode}',
        status: resp.statusCode,
      );
    }
  } catch (e) {
    return _jsonError('Could not reach Ollama at $base: $e', status: 502);
  }
}

Future<Response> _handleGetDataSourcesSettings(Request request) async {
  final ds = ServerDataSourcesService.instance;
  return _json({
    'email': {
      'provider': ds.emailProvider.configKey,
      'enabled': ds.emailEnabled,
      'imap_host': ds.imapHost,
      'imap_port': ds.imapPort,
      'imap_username': ds.imapUsername,
      'imap_password': ds.imapPassword,
      'imap_use_ssl': ds.imapUseSsl,
      'smtp_host': ds.smtpHost,
      'smtp_port': ds.smtpPort,
      'smtp_sender': ds.smtpSender,
      'notification_email_enabled': ds.notificationEmailEnabled,
      'gmail_account_email': ds.gmailAccountEmail,
      'has_gmail_tokens': ds.hasGmailOAuthTokens,
    },
    'web_search': {
      'provider': ds.webSearchProvider.configKey,
      'enabled': ds.webSearchEnabled,
      'api_key': ds.webSearchApiKey,
      'engine_id': ds.webSearchEngineId,
      'max_results': ds.webSearchMaxResults,
      'custom_provider_name': ds.webSearchCustomProviderName,
      'custom_endpoint': ds.webSearchCustomEndpoint,
      'duckdb_index_size_limit_gb': ds.duckDbIndexSizeLimitGb,
      'output_retention_days': ds.outputRetentionDays,
    },
    'website_index': {
      'urls': ds.websiteIndexUrls,
      'max_pages': ds.websiteIndexMaxPages,
      'cron': ds.websiteIndexCron,
      'last_indexed_at': ds.websiteIndexLastIndexedAt?.toIso8601String(),
    },
    'document_index': {
      'root_paths': ds.documentRootPaths,
      'file_types': ds.documentFileTypes,
      'cron': ds.documentIndexCron,
      'last_indexed_at': ds.documentIndexLastIndexedAt?.toIso8601String(),
    },
    'cloud_storage': {
      'google_drive_enabled': ds.googleDriveEnabled,
      'one_drive_enabled': ds.oneDriveEnabled,
      'one_drive_client_id': ds.oneDriveClientId,
      'one_drive_tenant_id': ds.oneDriveTenantId,
    },
    'location': {'lat': ds.locationLatitude, 'lng': ds.locationLongitude},
    'ssh': {
      'host': ds.sshHost,
      'port': ds.sshPort,
      'username': ds.sshUsername,
      'password': ds.sshPassword,
      'private_key': ds.sshPrivateKey,
    },
    'slack': {
      'enabled': ds.slackEnabled,
      'webhook_url': ds.slackWebhookUrl,
      'bot_token': ds.slackBotToken,
      'default_channel': ds.slackDefaultChannel,
    },
    'home_assistant': {'base_url': ds.haBaseUrl, 'token': ds.haToken},
    'whatsapp': {
      'enabled': ds.whatsAppEnabled,
      'mode': ds.whatsAppMode,
      'phone_number_id': ds.whatsAppPhoneNumberId,
      'access_token': ds.whatsAppAccessToken,
      'default_recipient': ds.whatsAppDefaultRecipient,
      'callmebot_api_key': ds.whatsAppCallMeBotApiKey,
    },
  });
}

Future<Response> _handlePutDataSourcesSettings(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  try {
    final ds = ServerDataSourcesService.instance;

    if (body.containsKey('email')) {
      final e = body['email'] as Map<String, dynamic>;
      await ds.saveEmail(
        provider: EmailProvider.fromConfigKey(e['provider'] as String? ?? ''),
        enabled: e['enabled'] as bool? ?? false,
        imapHost: e['imap_host'] as String? ?? '',
        imapPort: e['imap_port'] as int? ?? 993,
        imapUsername: e['imap_username'] as String? ?? '',
        imapPassword: e['imap_password'] as String? ?? '',
        imapUseSsl: e['imap_use_ssl'] as bool? ?? true,
        smtpHost: e['smtp_host'] as String? ?? '',
        smtpPort: e['smtp_port'] as int? ?? 587,
        smtpSender: e['smtp_sender'] as String? ?? '',
        notificationEmailEnabled:
            e['notification_email_enabled'] as bool? ?? false,
      );
    }
    if (body.containsKey('web_search')) {
      final ws = body['web_search'] as Map<String, dynamic>;
      await ds.saveWebSearch(
        provider: WebSearchProvider.fromConfigKey(
          ws['provider'] as String? ?? '',
        ),
        enabled: ws['enabled'] as bool? ?? false,
        apiKey: ws['api_key'] as String? ?? '',
        engineId: ws['engine_id'] as String? ?? '',
        maxResults: ws['max_results'] as int? ?? 5,
        customProviderName: ws['custom_provider_name'] as String? ?? '',
        customEndpoint: ws['custom_endpoint'] as String? ?? '',
        duckDbIndexSizeLimitGb:
            (ws['duckdb_index_size_limit_gb'] as num?)?.toDouble() ?? 1.0,
        outputRetentionDays: ws['output_retention_days'] as int? ?? 2,
      );
    }
    if (body.containsKey('website_index')) {
      final wi = body['website_index'] as Map<String, dynamic>;
      final lastRaw = wi['last_indexed_at'] as String?;
      await ds.saveWebsiteIndex(
        urls: wi['urls'] as String? ?? '',
        maxPages: wi['max_pages'] as int? ?? 100,
        cron: wi['cron'] as String? ?? '',
        lastIndexedAt: lastRaw != null ? DateTime.tryParse(lastRaw) : null,
      );
    }
    if (body.containsKey('document_index')) {
      final di = body['document_index'] as Map<String, dynamic>;
      final lastRaw = di['last_indexed_at'] as String?;
      await ds.saveDocumentIndex(
        rootPaths: di['root_paths'] as String? ?? '',
        fileTypes: di['file_types'] as String? ?? 'pdf,md,docx',
        cron: di['cron'] as String? ?? '',
        lastIndexedAt: lastRaw != null ? DateTime.tryParse(lastRaw) : null,
      );
    }
    if (body.containsKey('cloud_storage')) {
      final cs = body['cloud_storage'] as Map<String, dynamic>;
      await ds.saveCloudStorage(
        googleDriveEnabled: cs['google_drive_enabled'] as bool? ?? false,
        oneDriveEnabled: cs['one_drive_enabled'] as bool? ?? false,
        oneDriveClientId: cs['one_drive_client_id'] as String? ?? '',
        oneDriveTenantId: cs['one_drive_tenant_id'] as String? ?? '',
      );
    }
    if (body.containsKey('location')) {
      final loc = body['location'] as Map<String, dynamic>;
      final lat = (loc['lat'] as num?)?.toDouble();
      final lng = (loc['lng'] as num?)?.toDouble();
      await ds.saveLocation(lat, lng);
    }
    if (body.containsKey('ssh')) {
      final ssh = body['ssh'] as Map<String, dynamic>;
      await ds.setSshCredentials(
        host: ssh['host'] as String? ?? '',
        port: ssh['port'] as int? ?? 22,
        username: ssh['username'] as String? ?? '',
        password: ssh['password'] as String? ?? '',
        privateKey: ssh['private_key'] as String? ?? '',
      );
    }
    if (body.containsKey('slack')) {
      final s = body['slack'] as Map<String, dynamic>;
      await ds.setSlack(
        enabled: s['enabled'] as bool? ?? false,
        webhookUrl: s['webhook_url'] as String? ?? '',
        botToken: s['bot_token'] as String? ?? '',
        defaultChannel: s['default_channel'] as String? ?? '',
      );
    }
    if (body.containsKey('home_assistant')) {
      final ha = body['home_assistant'] as Map<String, dynamic>;
      await ds.setHomeAssistant(
        baseUrl: ha['base_url'] as String? ?? '',
        token: ha['token'] as String? ?? '',
      );
    }
    if (body.containsKey('whatsapp')) {
      final wa = body['whatsapp'] as Map<String, dynamic>;
      await ds.saveWhatsApp(
        enabled: wa['enabled'] as bool? ?? false,
        mode: wa['mode'] as String? ?? 'meta',
        phoneNumberId: wa['phone_number_id'] as String? ?? '',
        accessToken: wa['access_token'] as String? ?? '',
        defaultRecipient: wa['default_recipient'] as String? ?? '',
        callMeBotApiKey: wa['callmebot_api_key'] as String? ?? '',
      );
    }
    // Legacy flat keys (backward compat with syncSettings)
    if (body.containsKey('web_search_api_key')) {
      await ds.setWebSearchApiKey(body['web_search_api_key'] as String);
    }

    return _json({'status': 'saved'});
  } catch (e) {
    log.error('[API] PUT /settings/data-sources failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleGetPreferences(Request request) async {
  final p = ServerPreferencesService.instance;
  return _json({
    'default_output_path': p.defaultOutputPath,
    'output_retention_days': p.outputRetentionDays,
    'background_check_interval_minutes': p.backgroundCheckIntervalMinutes,
    'locale': p.locale,
  });
}

Future<Response> _handlePutPreferences(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  try {
    final p = ServerPreferencesService.instance;
    if (body.containsKey('default_output_path')) {
      await p.setDefaultOutputPath(body['default_output_path'] as String);
    }
    if (body.containsKey('output_retention_days')) {
      await p.setOutputRetentionDays(body['output_retention_days'] as int);
    }
    if (body.containsKey('background_check_interval_minutes')) {
      await p.setBackgroundCheckIntervalMinutes(
        body['background_check_interval_minutes'] as int,
      );
    }
    if (body.containsKey('locale')) {
      await p.setLocale(body['locale'] as String);
    }
    return _json({'status': 'saved'});
  } catch (e) {
    log.error('[API] PUT /settings/preferences failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleGetExternalTools(Request request) async {
  final et = ServerExternalToolsService.instance;
  return _json({
    'catalog_base_url': et.catalogBaseUrl,
    'catalog_source': et.catalogSource,
    'smithery_api_key_set': et.smitheryApiKey.isNotEmpty,
    'selected_count': et.selectedCount,
    'selected_servers': et.selectedServers.map((s) => s.toJson()).toList(),
  });
}

Future<Response> _handlePutExternalTools(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  try {
    final et = ServerExternalToolsService.instance;
    if (body.containsKey('catalog_base_url')) {
      await et.saveCatalogBaseUrl(body['catalog_base_url'] as String);
    }
    if (body.containsKey('catalog_source')) {
      await et.saveCatalogSource(body['catalog_source'] as String);
    }
    if (body.containsKey('smithery_api_key')) {
      await et.saveSmitheryApiKey(body['smithery_api_key'] as String);
    }
    if (body.containsKey('selected_servers')) {
      final raw = body['selected_servers'] as List<dynamic>;
      final servers = raw
          .whereType<Map<String, dynamic>>()
          .map(McpToolConfig.fromJson)
          .toList();
      await et.saveSelectedServers(servers);
    }
    return _json({'status': 'saved'});
  } catch (e) {
    log.error('[API] PUT /settings/external-tools failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

// ── Scheduler log ─────────────────────────────────────────────

Future<Response> _handleGetSchedulerLog(Request request) async {
  try {
    final limitStr = request.url.queryParameters['limit'];
    final offsetStr = request.url.queryParameters['offset'];
    final limit = int.tryParse(limitStr ?? '') ?? 50;
    final offset = int.tryParse(offsetStr ?? '') ?? 0;

    final rows = await ServerDuckDbService().query(
      'SELECT id, task_id, task_name, started_at, ended_at, success, message '
      'FROM scheduler_log '
      'ORDER BY started_at DESC '
      'LIMIT $limit OFFSET $offset',
    );

    final entries = rows
        .map(
          (row) => {
            'id': row[0],
            'task_id': row[1],
            'task_name': row[2],
            'started_at': row[3]?.toString(),
            'ended_at': row[4]?.toString(),
            'success': row[5],
            'message': row[6],
          },
        )
        .toList();

    return _json({'entries': entries, 'limit': limit, 'offset': offset});
  } catch (e) {
    log.error('[API] GET /scheduler/log failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

// ── Indexing ──────────────────────────────────────────────────

Future<Response> _handleStartWebsiteIndex(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');
  final urls = (body['urls'] as String? ?? '').trim();
  if (urls.isEmpty) return _jsonError('Missing required field: urls');
  final maxPages =
      (body['max_pages'] as int?) ?? (body['maxPages'] as int?) ?? 100;
  final result = ServerIndexingService.instance.startWebsiteIndex(
    urls: urls,
    maxPages: maxPages,
  );
  if (result.containsKey('error')) return _jsonError(result['error'] as String);
  return _json(result, status: 202);
}

Future<Response> _handleStopWebsiteIndex(Request request) async {
  return _json(ServerIndexingService.instance.stopWebsiteIndex());
}

Future<Response> _handleGetWebsiteIndexStatus(Request request) async {
  return _json(ServerIndexingService.instance.getWebsiteIndexStatus());
}

Future<Response> _handleSearchWebsiteIndex(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');
  final query = (body['query'] as String? ?? '').trim();
  if (query.isEmpty) return _jsonError('Missing required field: query');
  final domain = (body['domain'] as String?)?.trim();
  final limit = (body['limit'] as int?) ?? 20;
  final searchMode =
      (body['search_mode'] as String? ??
              body['searchMode'] as String? ??
              'hybrid')
          .trim();
  final result = await ServerIndexingService.instance.searchWebsiteIndex(
    query: query,
    domain: domain?.isEmpty == true ? null : domain,
    limit: limit.clamp(1, 200),
    searchMode: searchMode,
  );
  return _json(result);
}

Future<Response> _handleListWebsitePages(Request request) async {
  final params = request.url.queryParameters;
  final domain = (params['domain'] ?? '').trim();
  final limit = int.tryParse(params['limit'] ?? '') ?? 50;
  final result = await ServerIndexingService.instance.listWebsitePages(
    domain: domain.isEmpty ? null : domain,
    limit: limit.clamp(1, 500),
  );
  return _json(result);
}

Future<Response> _handleGetWebsitePage(Request request) async {
  final url = (request.url.queryParameters['url'] ?? '').trim();
  if (url.isEmpty) return _jsonError('Missing required query parameter: url');
  final result = await ServerIndexingService.instance.getWebsitePage(url);
  if (result.containsKey('error')) {
    return _jsonError(result['error'] as String, status: 404);
  }
  return _json(result);
}

Future<Response> _handlePurgeStaleWebsiteIndex(Request request) async {
  final result = await ServerIndexingService.instance.purgeStaleWebsiteIndex();
  return _json(result);
}

Future<Response> _handleStartDocumentIndex(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');
  final rootPaths =
      (body['root_paths'] as String? ?? body['rootPaths'] as String? ?? '')
          .trim();
  if (rootPaths.isEmpty) {
    return _jsonError('Missing required field: root_paths');
  }
  final fileTypes =
      (body['file_types'] as String? ??
              body['fileTypes'] as String? ??
              'pdf,md,docx')
          .trim();
  final result = ServerIndexingService.instance.startDocumentIndex(
    rootPaths: rootPaths,
    fileTypes: fileTypes,
  );
  if (result.containsKey('error')) return _jsonError(result['error'] as String);
  return _json(result, status: 202);
}

Future<Response> _handleStopDocumentIndex(Request request) async {
  return _json(ServerIndexingService.instance.stopDocumentIndex());
}

Future<Response> _handleGetDocumentIndexStatus(Request request) async {
  return _json(ServerIndexingService.instance.getDocumentIndexStatus());
}

Future<Response> _handleSearchDocumentIndex(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');
  final query = (body['query'] as String? ?? '').trim();
  if (query.isEmpty) return _jsonError('Missing required field: query');
  final fileType = (body['file_type'] as String? ?? body['fileType'] as String?)
      ?.trim();
  final limit = (body['limit'] as int?) ?? 20;
  final searchMode =
      (body['search_mode'] as String? ??
              body['searchMode'] as String? ??
              'hybrid')
          .trim();
  final result = await ServerIndexingService.instance.searchDocumentIndex(
    query: query,
    fileType: fileType?.isEmpty == true ? null : fileType,
    limit: limit.clamp(1, 200),
    searchMode: searchMode,
  );
  return _json(result);
}

Future<Response> _handleListDocumentIndex(Request request) async {
  final params = request.url.queryParameters;
  final fileType = (params['file_type'] ?? params['fileType'] ?? '').trim();
  final limit = int.tryParse(params['limit'] ?? '') ?? 100;
  final result = await ServerIndexingService.instance.listDocumentIndex(
    fileType: fileType.isEmpty ? null : fileType,
    limit: limit.clamp(1, 1000),
  );
  return _json(result);
}

Future<Response> _handleGetDocumentIndexEntry(Request request) async {
  final filePath =
      (request.url.queryParameters['file_path'] ??
              request.url.queryParameters['filePath'] ??
              '')
          .trim();
  if (filePath.isEmpty) {
    return _jsonError('Missing required query parameter: file_path');
  }
  final result = await ServerIndexingService.instance.getDocumentIndexEntry(
    filePath,
  );
  if (result.containsKey('error')) {
    return _jsonError(result['error'] as String, status: 404);
  }
  return _json(result);
}

Future<Response> _handlePurgeStaleDocumentIndex(Request request) async {
  final result = await ServerIndexingService.instance.purgeStaleDocumentIndex();
  return _json(result);
}

// ── Sync ─────────────────────────────────────────────────────

Future<Response> _handleSyncTasks(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  final rawTasks = body['tasks'];
  if (rawTasks is! List) return _jsonError('Expected {"tasks": [...]}');

  final db = ServerDuckDbService();
  int inserted = 0;
  int updated = 0;
  final errors = <String>[];

  for (final rawTask in rawTasks) {
    if (rawTask is! Map<String, dynamic>) continue;
    try {
      final task = AgenticTask.fromJson(rawTask);
      final existing = await db.getTask(task.id);
      await db.saveTask(task);
      if (existing == null) {
        inserted++;
      } else {
        updated++;
      }
    } catch (e) {
      errors.add('${rawTask['id'] ?? '?'}: $e');
    }
  }

  return _json({'inserted': inserted, 'updated': updated, 'errors': errors});
}

Future<Response> _handleSyncSettings(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  try {
    // Delegate to individual PUT handlers using synthetic requests
    if (body.containsKey('llm')) {
      await _handlePutLlmSettings(
        Request(
          'PUT',
          Uri.parse('http://localhost/'),
          body: jsonEncode(body['llm']),
        ),
      );
    }
    if (body.containsKey('data_sources')) {
      await _handlePutDataSourcesSettings(
        Request(
          'PUT',
          Uri.parse('http://localhost/'),
          body: jsonEncode(body['data_sources']),
        ),
      );
    }
    if (body.containsKey('preferences')) {
      await _handlePutPreferences(
        Request(
          'PUT',
          Uri.parse('http://localhost/'),
          body: jsonEncode(body['preferences']),
        ),
      );
    }
    if (body.containsKey('external_tools')) {
      await _handlePutExternalTools(
        Request(
          'PUT',
          Uri.parse('http://localhost/'),
          body: jsonEncode(body['external_tools']),
        ),
      );
    }
    return _json({'status': 'synced'});
  } catch (e) {
    log.error('[API] POST /sync/settings failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleGetPyTools(Request request) async {
  try {
    final db = ServerDuckDbService();
    final list = await db.getAllPyTools();
    final normalized = list
        .map(
          (item) => {
            'id': item['id'],
            'name': item['name'],
            'description': item['description'],
            'inputSchema': item['input_schema'],
            'code': item['code'],
            'requirements': item['requirements'],
            'venvReady': item['venv_ready'],
            'isActive': item['is_active'],
            'generationPrompt': item['generation_prompt'],
          },
        )
        .toList();
    return _json({'tools': normalized});
  } catch (e) {
    log.error('[API] GET /sync/py_tools failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleGetJsTools(Request request) async {
  try {
    final db = ServerDuckDbService();
    final list = await db.getAllJsTools(activeOnly: false);
    final normalized = list
        .map(
          (item) => {
            'id': item['id'],
            'name': item['name'],
            'description': item['description'],
            'inputSchema': item['input_schema'],
            'jsCode': item['js_code'],
            'isActive': item['is_active'],
          },
        )
        .toList();
    return _json({'tools': normalized});
  } catch (e) {
    log.error('[API] GET /sync/js_tools failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleSyncPyTools(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  final rawTools = body['tools'];
  if (rawTools is! List) return _jsonError('Expected {"tools": [...]}');

  final db = ServerDuckDbService();
  int inserted = 0;
  int updated = 0;
  final errors = <String>[];

  for (final raw in rawTools) {
    if (raw is! Map<String, dynamic>) continue;
    final id = (raw['id'] as String?)?.trim();
    if (id == null || id.isEmpty) continue;
    try {
      final existing = (await db.getAllPyTools())
          .where((t) => t['id']?.toString() == id)
          .firstOrNull;
      final hasVenvReady =
          raw.containsKey('venvReady') || raw.containsKey('venv_ready');
      final existingVenvReady = existing?['venv_ready'] as bool? ?? false;
      await db.savePyTool(<String, dynamic>{
        'id': id,
        'name': raw['name'] as String? ?? 'unnamed_tool',
        'description': raw['description'] as String? ?? '',
        'input_schema':
            raw['inputSchema'] ??
            raw['input_schema'] ??
            const <String, dynamic>{
              'type': 'object',
              'properties': <String, dynamic>{},
            },
        'code': raw['code'] as String? ?? '',
        'requirements': raw['requirements'] as String? ?? '',
        'venv_ready': hasVenvReady
            ? (raw['venvReady'] as bool? ??
                  raw['venv_ready'] as bool? ??
                  existingVenvReady)
            : existingVenvReady,
        'is_active':
            raw['isActive'] as bool? ?? raw['is_active'] as bool? ?? true,
        'generation_prompt':
            raw['generationPrompt'] as String? ??
            raw['generation_prompt'] as String? ??
            '',
      });
      if (existing == null) {
        inserted++;
      } else {
        updated++;
      }
    } catch (e) {
      errors.add('$id: $e');
    }
  }

  // 1. Gather all synced tool IDs
  final syncedIds = <String>[];
  for (final raw in rawTools) {
    if (raw is! Map<String, dynamic>) continue;
    final id = (raw['id'] as String?)?.trim();
    if (id != null && id.isNotEmpty) {
      syncedIds.add(id);
    }
  }

  // 2. Delete tools on the server that are not in the synced list
  try {
    if (syncedIds.isEmpty) {
      final conn = await db.connection;
      await conn.execute('DELETE FROM py_tools');
    } else {
      final conn = await db.connection;
      final escapedIds = syncedIds.map((id) => "'${ServerDuckDbService.esc(id)}'").join(', ');
      await conn.execute('DELETE FROM py_tools WHERE id NOT IN ($escapedIds)');
    }
  } catch (e) {
    errors.add('delete_stale: $e');
  }

  return _json({'inserted': inserted, 'updated': updated, 'errors': errors});
}

Future<Response> _handleGetSshScripts(Request request) async {
  try {
    final db = ServerDuckDbService();
    final dataDir = db.dataDir;
    final file = File('$dataDir/scripts.json');
    if (!await file.exists()) {
      return _json({'scripts': <Map<String, dynamic>>[]});
    }
    final raw = await file.readAsString();
    final list = jsonDecode(raw) as List<dynamic>;
    return _json({'scripts': list});
  } catch (e) {
    log.error('[API] GET /sync/ssh_scripts failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleSyncSshScripts(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  final rawScripts = body['scripts'];
  if (rawScripts is! List) return _jsonError('Expected {"scripts": [...]}');

  final db = ServerDuckDbService();
  final dataDir = db.dataDir;
  final file = File('$dataDir/scripts.json');
  await file.parent.create(recursive: true);

  List<Map<String, dynamic>> existing = const <Map<String, dynamic>>[];
  if (await file.exists()) {
    try {
      existing = (jsonDecode(await file.readAsString()) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .toList();
    } catch (_) {
      existing = const <Map<String, dynamic>>[];
    }
  }

  int inserted = 0;
  int updated = 0;
  final errors = <String>[];
  final normalizedScripts = <Map<String, dynamic>>[];
  final existingIds = existing
      .map((script) => (script['id'] as String?)?.trim())
      .whereType<String>()
      .where((id) => id.isNotEmpty)
      .toSet();

  for (final raw in rawScripts) {
    if (raw is! Map<String, dynamic>) continue;
    final id = (raw['id'] as String?)?.trim();
    if (id == null || id.isEmpty) continue;
    try {
      final normalized = Map<String, dynamic>.from(raw);
      if (existingIds.contains(id)) {
        updated++;
      } else {
        inserted++;
      }
      normalizedScripts.add(normalized);
    } catch (e) {
      errors.add('$id: $e');
    }
  }

  normalizedScripts.sort(
    (a, b) => (a['name'] as String? ?? '').toLowerCase().compareTo(
      (b['name'] as String? ?? '').toLowerCase(),
    ),
  );
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(normalizedScripts),
  );
  ServerSshMcp.clearScriptCache();

  return _json({'inserted': inserted, 'updated': updated, 'errors': errors});
}

Future<Response> _handleInitPyTool(Request request, String toolId) async {
  toolId = toolId.trim();
  if (toolId.isEmpty) return _jsonError('toolId is required');
  final db = ServerDuckDbService();
  final rows = await db.getAllPyTools();
  final tool = rows.where((t) => t['id']?.toString() == toolId).firstOrNull;
  if (tool == null) {
    return _jsonError('Python tool not found: $toolId', status: 404);
  }

  final pyMcp = ServerPyBridgeMcp();
  await pyMcp.initialize(const {
    'allowInactive': true,
    'initTimeoutSeconds': 300,
  });
  final result = await pyMcp.callTool('init_py_tool', {'toolId': toolId});
  if (result['success'] == true) {
    return _json(result);
  }
  return _json(result, status: 500);
}

Future<Response> _handleRunPyTool(Request request, String toolId) async {
  toolId = toolId.trim();
  if (toolId.isEmpty) return _jsonError('toolId is required');

  final body = await _parseJsonBody(request);
  final argsRaw = body?['args'];
  if (argsRaw != null && argsRaw is! Map<String, dynamic>) {
    return _jsonError('args must be a JSON object');
  }
  final timeoutSeconds = body?['timeoutSeconds'] as int?;

  final pyMcp = ServerPyBridgeMcp();
  await pyMcp.initialize(const {
    'allowInactive': true,
    'defaultTimeoutSeconds': 60,
  });
  final result = await pyMcp.callTool('run_py_tool', {
    'toolId': toolId,
    'args': argsRaw ?? <String, dynamic>{},
    'timeoutSeconds': timeoutSeconds,
  });

  if (result['success'] == true) {
    return _json(result);
  }

  final err = (result['error']?.toString() ?? '').toLowerCase();
  if (err.contains('tool not found')) {
    return _json(result, status: 404);
  }
  return _json(result, status: 500);
}

Future<Response> _handleSyncJsTools(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  final rawTools = body['tools'];
  if (rawTools is! List) return _jsonError('Expected {"tools": [...]}');

  final db = ServerDuckDbService();
  int inserted = 0;
  int updated = 0;
  final errors = <String>[];

  for (final raw in rawTools) {
    if (raw is! Map<String, dynamic>) continue;
    final id = (raw['id'] as String?)?.trim();
    if (id == null || id.isEmpty) continue;
    try {
      final existing = (await db.getAllJsTools())
          .where((t) => t['id']?.toString() == id)
          .firstOrNull;
      await db.saveJsTool(<String, dynamic>{
        'id': id,
        'name': raw['name'] as String? ?? 'unnamed_tool',
        'description': raw['description'] as String? ?? '',
        'input_schema':
            raw['inputSchema'] ??
            raw['input_schema'] ??
            const <String, dynamic>{
              'type': 'object',
              'properties': <String, dynamic>{},
            },
        'js_code': raw['jsCode'] as String? ?? raw['js_code'] as String? ?? '',
        'is_active':
            raw['isActive'] as bool? ?? raw['is_active'] as bool? ?? true,
      });
      if (existing == null) {
        inserted++;
      } else {
        updated++;
      }
    } catch (e) {
      errors.add('$id: $e');
    }
  }

  // 1. Gather all synced tool IDs
  final syncedIds = <String>[];
  for (final raw in rawTools) {
    if (raw is! Map<String, dynamic>) continue;
    final id = (raw['id'] as String?)?.trim();
    if (id != null && id.isNotEmpty) {
      syncedIds.add(id);
    }
  }

  // 2. Delete tools on the server that are not in the synced list
  try {
    if (syncedIds.isEmpty) {
      final conn = await db.connection;
      await conn.execute('DELETE FROM js_tools');
    } else {
      final conn = await db.connection;
      final escapedIds = syncedIds.map((id) => "'${ServerDuckDbService.esc(id)}'").join(', ');
      await conn.execute('DELETE FROM js_tools WHERE id NOT IN ($escapedIds)');
    }
  } catch (e) {
    errors.add('delete_stale: $e');
  }

  return _json({'inserted': inserted, 'updated': updated, 'errors': errors});
}

// ── MCP Proxy ─────────────────────────────────────────────────

Future<Response> _handleListMcpServers(Request request) async {
  try {
    final db = ServerDuckDbService();
    final githubServers = await db.getAllGithubMcpServers();
    final externalServers = ServerExternalToolsService.instance.selectedServers;

    final servers = <Map<String, dynamic>>[];

    for (final s in githubServers) {
      final isRunning =
          _mcpProxyClients.containsKey(s.id) ||
          _mcpProxyProcesses.containsKey(s.id);
      final tools =
          _mcpProxyTools[s.id] ??
          (_mcpProxyClients[s.id]?.availableTools ?? []);
      final httpUrl =
          s.envVars['MCP_HTTP_URL'] ??
          s.envVars['SERVER_URL'] ??
          s.envVars['ENDPOINT_URL'];
      servers.add({
        'id': s.id,
        'name': s.name,
        'display_name': s.displayName,
        'type': 'github',
        'transport': httpUrl != null && httpUrl.isNotEmpty ? 'http' : 'stdio',
        'status': isRunning ? 'running' : 'stopped',
        'is_active': s.isActive,
        'tool_count': tools.length,
      });
    }

    for (final cfg in externalServers) {
      final id = cfg.serverUrl;
      final isRunning = _mcpProxyClients.containsKey(id);
      final tools = _mcpProxyClients[id]?.availableTools ?? [];
      servers.add({
        'id': id,
        'name': cfg.name ?? cfg.serverUrl,
        'display_name': cfg.name ?? cfg.serverUrl,
        'type': 'external',
        'transport': 'http',
        'status': isRunning ? 'running' : 'stopped',
        'tool_count': tools.length,
      });
    }

    return _json({'servers': servers});
  } catch (e) {
    log.error('[API] GET /mcp/servers failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleStartMcpServer(Request request, String serverId) async {
  final normServerId = _normalizeServerId(serverId);
  if (_mcpProxyClients.containsKey(normServerId) ||
      _mcpProxyProcesses.containsKey(normServerId) ||
      _mcpProxyInternals.containsKey(normServerId)) {
    return _jsonError('Server already running', status: 409);
  }

  final body = await _parseJsonBody(request);
  final initParams =
      (body?['initParams'] as Map<String, dynamic>?) ??
      const <String, dynamic>{};

  // Virtual internal MCP servers are handled in-process.
  const internalTypes = <String>{
    'ssh',
    'weather',
    'document',
    'pdf',
    'py_bridge',
    'toolbox',
  };
  if (internalTypes.contains(normServerId)) {
    try {
      final effectiveInitParams = <String, dynamic>{...initParams};
      if (normServerId == 'py_bridge') {
        effectiveInitParams.putIfAbsent('allowInactive', () => true);
      }
      final impl = await createServerInternalMcp(normServerId, effectiveInitParams);
      if (impl == null) {
        return _jsonError('$normServerId MCP not available', status: 500);
      }
      _mcpProxyInternals[normServerId] = impl;
      return _json({
        'server_id': normServerId,
        'status': 'running',
        'transport': 'internal',
        'tool_count': impl.tools.length,
      });
    } catch (e) {
      return _jsonError('Failed to start $normServerId: $e', status: 500);
    }
  }

  final db = ServerDuckDbService();

  GithubMcpServerDefinition? githubServer;
  try {
    final all = await db.getAllGithubMcpServers();
    githubServer = all.where((s) => s.id == normServerId).firstOrNull;
  } catch (e) {
    log.warning('[API] Could not load GitHub MCP servers: $e');
  }

  if (githubServer != null) {
    return _startGithubMcpServer(githubServer);
  }

  final externalCfg = ServerExternalToolsService.instance.selectedServers
      .where((s) => s.serverUrl == normServerId)
      .firstOrNull;

  if (externalCfg != null) {
    return _startExternalMcpServer(externalCfg);
  }

  return _jsonError('Server not found: $normServerId', status: 404);
}

Future<Response> _startGithubMcpServer(GithubMcpServerDefinition server) async {
  final httpUrl =
      server.envVars['MCP_HTTP_URL'] ??
      server.envVars['SERVER_URL'] ??
      server.envVars['ENDPOINT_URL'];

  if (httpUrl != null && httpUrl.isNotEmpty) {
    final launchError = await _ensureLocalHttpProxyProcess(server, httpUrl);
    if (launchError is String && launchError.isNotEmpty) {
      return _jsonError(launchError, status: 502);
    }
    final client = ServerMcpClient(httpUrl);
    try {
      await client.connect();
      _mcpProxyClients[server.id] = client;
      if (_mcpProxyLocalHttpProcesses.containsKey(server.id)) {
        _armLocalHttpIdleShutdown(server.id);
      }
      return _json({
        'server_id': server.id,
        'status': 'running',
        'transport': 'http',
        'tool_count': client.availableTools.length,
      });
    } catch (e) {
      client.dispose();
      return _jsonError('Failed to connect to ${server.name}: $e', status: 502);
    }
  }

  // Stdio-based
  final (executable, args) = ServerToolRegistry.resolveStdioCommand(
    server,
    dataDir: ServerDuckDbService().dataDir,
  );
  if (executable.isEmpty) {
    return _jsonError(
      'Cannot resolve startup command for ${server.name}',
      status: 422,
    );
  }

  final proc = StdioMcpProcess(server.id);
  try {
    await proc.start(executable, args, env: _serverRuntimeEnv(server.envVars));
    _mcpProxyProcesses[server.id] = proc;
    final tools = await _stdioProxyInit(proc, server.name);
    _mcpProxyTools[server.id] = tools;
    return _json({
      'server_id': server.id,
      'status': 'running',
      'transport': 'stdio',
      'tool_count': tools.length,
    });
  } catch (e) {
    proc.dispose();
    _mcpProxyProcesses.remove(server.id);
    _mcpProxyTools.remove(server.id);
    return _jsonError('Failed to start ${server.name}: $e', status: 502);
  }
}

Future<Response> _startExternalMcpServer(McpToolConfig cfg) async {
  final baseUrl = cfg.serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
  var endpoint = (cfg.mcpEndpoint ?? '/mcp').trim();
  if (endpoint.isEmpty) endpoint = '/mcp';
  if (!endpoint.startsWith('/')) endpoint = '/$endpoint';

  final apiKey = ServerExternalToolsService.instance.resolveApiKey(baseUrl, cfg.apiKey);
  final resolvedTuple = await ServerExternalToolsService.instance
      .resolveSmitheryEndpoint(baseUrl, apiKey);
  final resolvedBase = resolvedTuple.$1;
  final resolvedKey = resolvedTuple.$2;

  final parsedResolved = Uri.parse(resolvedBase);
  final resolvedUrl = parsedResolved.path.toLowerCase().endsWith('/mcp')
      ? resolvedBase
      : parsedResolved
            .replace(path: parsedResolved.path + endpoint)
            .toString();

  final client = ServerMcpClient(resolvedUrl, bearerToken: resolvedKey);
  try {
    await client.connect();
    _mcpProxyClients[cfg.serverUrl] = client;
    return _json({
      'server_id': cfg.serverUrl,
      'status': 'running',
      'transport': 'http',
      'tool_count': client.availableTools.length,
    });
  } catch (e) {
    client.dispose();
    return _jsonError('Failed to connect to ${cfg.serverUrl}: $e', status: 502);
  }
}

// ── MCP Registry (install / manage) ────────────────────────────────────────

/// GET /api/v1/mcp/registry — list all github MCP servers stored in the DB.
Future<Response> _handleListRegistry(Request request) async {
  try {
    final db = ServerDuckDbService();
    final servers = await db.getAllGithubMcpServers();
    return _json({'servers': servers.map((s) => s.toJson()).toList()});
  } catch (e) {
    log.error('[API] GET /mcp/registry failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

/// POST /api/v1/mcp/registry — save definition to DB and run the package
/// installer (uvx / npm / pip) on the server.
String _normalizeGithubBlobToRaw(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null) return value.trim();
  if ((uri.host == 'github.com' || uri.host == 'www.github.com') &&
      uri.pathSegments.length >= 5) {
    final s = uri.pathSegments;
    if (s[2] == 'blob') {
      final owner = s[0];
      final repo = s[1];
      final ref = s[3];
      final rest = s.sublist(4).join('/');
      final rawPath = '/$owner/$repo/$ref/$rest';
      return Uri(
        scheme: 'https',
        host: 'raw.githubusercontent.com',
        path: rawPath,
      ).toString();
    }
  }
  return value.trim();
}

bool _looksLikeRequirementsSpec(String value) {
  final v = value.trim().toLowerCase();
  if (v.isEmpty) return false;
  return v.endsWith('requirements.txt') ||
      v.endsWith('.txt') ||
      v.contains('/requirements');
}

Future<Response> _handleInstallRegistry(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  GithubMcpServerDefinition incoming;
  try {
    incoming = GithubMcpServerDefinition.fromJson(body);
  } catch (e) {
    return _jsonError('Invalid server definition: $e');
  }

  final db = ServerDuckDbService();

  // Keep one stable DB record per package. If already present, reuse its id.
  final existing = (await db.getAllGithubMcpServers())
      .where((s) => s.packageName == incoming.packageName)
      .firstOrNull;
  final def = existing == null
      ? incoming
      : GithubMcpServerDefinition(
          id: existing.id,
          name: incoming.name,
          displayName: incoming.displayName,
          description: incoming.description,
          githubUrl: incoming.githubUrl,
          language: incoming.language,
          installType: incoming.installType,
          packageName: incoming.packageName,
          entryPoint: incoming.entryPoint,
          launchArgs: incoming.launchArgs,
          requiredEnvVars: incoming.requiredEnvVars,
          envVars: incoming.envVars,
          category: incoming.category,
          isInstalled: incoming.isInstalled,
          isActive: incoming.isActive,
          isManual: incoming.isManual,
          installedAt: incoming.installedAt,
          createdAt: existing.createdAt,
        );

  // Persist first so we have a record even if install fails.
  await db.saveGithubMcpServer(def);

  final logs = <String>[];
  String? installError;

  try {
    final installType = def.installType.toLowerCase();
    ProcessResult result;

    if (installType == 'uvx') {
      logs.add('Running: uv tool install ${def.packageName}');
      result = await Process.run(
        'uv',
        ['tool', 'install', def.packageName],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        runInShell: false,
      ).timeout(const Duration(minutes: 5));
    } else if (installType == 'pip') {
      final normalizedSpec = _normalizeGithubBlobToRaw(def.packageName);
      if (_looksLikeRequirementsSpec(normalizedSpec)) {
        logs.add('Running: uv pip install -r $normalizedSpec');
        result = await Process.run(
          'uv',
          ['pip', 'install', '--system', '-r', normalizedSpec],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
          runInShell: false,
        ).timeout(const Duration(minutes: 5));
      } else {
        logs.add('Running: uv pip install $normalizedSpec');
        result = await Process.run(
          'uv',
          ['pip', 'install', '--system', normalizedSpec],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
          runInShell: false,
        ).timeout(const Duration(minutes: 5));
      }
    } else if (installType == 'npm' || installType == 'npx') {
      logs.add(
        'Running: npm install -g --prefix $_npmGlobalPrefix ${def.packageName}',
      );
      result = await Process.run(
        'npm',
        ['install', '-g', '--prefix', _npmGlobalPrefix, def.packageName],
        environment: _serverRuntimeEnv(),
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        runInShell: false,
      ).timeout(const Duration(minutes: 5));
    } else {
      // Unknown type — treat as already installed (e.g. bespoke binary).
      logs.add(
        'Install type "${def.installType}" — skipping package install step.',
      );
      result = ProcessResult(0, 0, '', '');
    }

    final stdout = (result.stdout as String).trim();
    final stderr = (result.stderr as String).trim();
    if (stdout.isNotEmpty) logs.add(stdout);
    if (stderr.isNotEmpty) logs.add(stderr);

    if (result.exitCode != 0) {
      installError =
          'Install failed (exit ${result.exitCode}):\n${stderr.isNotEmpty ? stderr : stdout}';
    }
  } on TimeoutException {
    installError = 'Install timed out after 5 minutes.';
  } catch (e) {
    installError = 'Install threw: $e';
  }

  if (installError != null) {
    // Remove the record so the app does not show a broken entry.
    await db.deleteGithubMcpServer(def.id);
    log.error(
      '[API] POST /mcp/registry install failed for ${def.packageName}: $installError',
    );
    return _json({
      'success': false,
      'error': installError,
      'logs': logs,
    }, status: 500);
  }

  // Mark as installed + active.
  final installed = def.copyWith(
    isInstalled: true,
    isActive: true,
    installedAt: DateTime.now(),
  );
  await db.saveGithubMcpServer(installed);
  log.info('[API] POST /mcp/registry installed: ${def.packageName}');
  return _json({
    'success': true,
    'logs': logs,
    'server': installed.toJson(),
  }, status: 201);
}

/// PUT /api/v1/mcp/registry/:id — update env vars and/or active state.
Future<Response> _handleUpdateRegistry(Request request, String id) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  try {
    final db = ServerDuckDbService();
    final all = await db.getAllGithubMcpServers();
    final existing = all.where((s) => s.id == id).firstOrNull;
    if (existing == null) return _jsonError('Not found', status: 404);

    final envRaw = body['env_vars'];
    final envVars = envRaw is Map
        ? Map<String, String>.from(
            envRaw.map((k, v) => MapEntry(k.toString(), v.toString())),
          )
        : existing.envVars;
    final isActive = body['is_active'] as bool? ?? existing.isActive;

    final updated = existing.copyWith(envVars: envVars, isActive: isActive);
    await db.saveGithubMcpServer(updated);
    return _json({'server': updated.toJson()});
  } catch (e) {
    log.error('[API] PUT /mcp/registry/$id failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

/// DELETE /api/v1/mcp/registry/:id — uninstall package and remove from DB.
Future<Response> _handleDeleteRegistry(Request request, String id) async {
  try {
    final db = ServerDuckDbService();
    final all = await db.getAllGithubMcpServers();
    final existing = all.where((s) => s.id == id).firstOrNull;

    // Stop any running proxy connections/processes.
    _mcpProxyClients.remove(id)?.dispose();
    final proc = _mcpProxyProcesses.remove(id);
    final localHttp = _mcpProxyLocalHttpProcesses.remove(id);
    _mcpProxyLocalHttpStdoutSubs.remove(id)?.cancel();
    _mcpProxyLocalHttpStderrSubs.remove(id)?.cancel();
    _mcpProxyTools.remove(id);
    proc?.dispose();
    localHttp?.kill();

    if (existing != null) {
      final installType = existing.installType.toLowerCase();
      try {
        if (installType == 'uvx') {
          await Process.run('uv', [
            'tool',
            'uninstall',
            existing.packageName,
          ], runInShell: false).timeout(const Duration(minutes: 2));
        } else if (installType == 'npm' || installType == 'npx') {
          await Process.run(
            'npm',
            [
              'uninstall',
              '-g',
              '--prefix',
              _npmGlobalPrefix,
              existing.packageName,
            ],
            environment: _serverRuntimeEnv(),
            runInShell: false,
          ).timeout(const Duration(minutes: 2));
        }
        // pip: system pip removal is risky; skip uninstall, just remove DB record.
      } catch (e) {
        log.warning('[API] DELETE /mcp/registry/$id uninstall warning: $e');
      }
      await db.deleteGithubMcpServer(id);
    }

    return _json({'success': true, 'id': id});
  } catch (e) {
    log.error('[API] DELETE /mcp/registry/$id failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

/// POST /api/v1/mcp/registry/:id/test — launch the server, run MCP handshake,
/// return discovered tools list.
Future<Response> _handleTestRegistry(Request request, String id) async {
  try {
    final db = ServerDuckDbService();
    final all = await db.getAllGithubMcpServers();
    final server = all.where((s) => s.id == id).firstOrNull;
    if (server == null) return _jsonError('Not found', status: 404);

    // HTTP-transport server — connect and list tools.
    final httpUrl =
        server.envVars['MCP_HTTP_URL'] ??
        server.envVars['SERVER_URL'] ??
        server.envVars['ENDPOINT_URL'];
    if (httpUrl != null && httpUrl.isNotEmpty) {
      Process? tempProcess;
      String? tempServerId;
      final launchError = await _ensureLocalHttpProxyProcess(
        server,
        httpUrl,
        persistent: false,
      );
      if (launchError is String) {
        return _json({'success': false, 'error': launchError, 'tools': []});
      }
      if (launchError is Map<String, dynamic>) {
        tempProcess = launchError['process'] as Process?;
        tempServerId = launchError['tempServerId'] as String?;
      }
      final client = ServerMcpClient(httpUrl);
      try {
        await client.connect();
        final tools = client.availableTools.map((t) => t.toJson()).toList();
        client.dispose();
        return _json({'success': true, 'tools': tools});
      } catch (e) {
        client.dispose();
        return _json({'success': false, 'error': e.toString(), 'tools': []});
      } finally {
        if (tempServerId != null) {
          _mcpProxyLocalHttpStdoutSubs.remove(tempServerId)?.cancel();
          _mcpProxyLocalHttpStderrSubs.remove(tempServerId)?.cancel();
        }
        tempProcess?.kill();
      }
    }

    // Stdio-based — launch, handshake, stop.
    final (executable, args) = ServerToolRegistry.resolveStdioCommand(
      server,
      dataDir: db.dataDir,
    );
    if (executable.isEmpty) {
      return _json({
        'success': false,
        'error': 'Cannot resolve startup command for ${server.name}',
        'tools': [],
      });
    }

    final proc = StdioMcpProcess('test-${server.id}');
    try {
      await proc.start(
        executable,
        args,
        env: _serverRuntimeEnv(server.envVars),
      );
      final tools = await _stdioProxyInit(proc, server.name);
      proc.dispose();
      return _json({
        'success': true,
        'tools': tools.map((t) => t.toJson()).toList(),
      });
    } catch (e) {
      proc.dispose();
      return _json({'success': false, 'error': e.toString(), 'tools': []});
    }
  } catch (e) {
    log.error('[API] POST /mcp/registry/$id/test failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

/// Performs the MCP initialize handshake over a stdio process and returns the
/// tool list.
Future<List<MCPTool>> _stdioProxyInit(
  StdioMcpProcess proc,
  String serverName,
) async {
  const initId = 'proxy-init';
  proc.writeLine(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': initId,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2024-11-05',
        'capabilities': {
          'tools': {'listChanged': true},
        },
        'clientInfo': {'name': 'TealKit Server Proxy', 'version': '1.0.0'},
      },
    }),
  );

  await for (final line in proc.lines.timeout(const Duration(seconds: 30))) {
    if (line.trim().isEmpty) continue;
    try {
      final j = jsonDecode(line) as Map<String, dynamic>;
      if (j['id'] == initId) break;
    } catch (_) {}
  }

  proc.writeLine(
    jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
  );

  const listId = 'proxy-tools';
  proc.writeLine(
    jsonEncode({'jsonrpc': '2.0', 'id': listId, 'method': 'tools/list'}),
  );

  await for (final line in proc.lines.timeout(const Duration(seconds: 15))) {
    if (line.trim().isEmpty) continue;
    try {
      final j = jsonDecode(line) as Map<String, dynamic>;
      if (j['id'] == listId) {
        final raw = j['result']?['tools'] as List? ?? [];
        return raw
            .map((t) => MCPTool.fromJson(t as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {}
  }
  return [];
}

Future<Response> _handleStopMcpServer(Request request, String serverId) async {
  final normServerId = _normalizeServerId(serverId);
  final wasRunning =
      _mcpProxyInternals.containsKey(normServerId) ||
      _mcpProxyClients.containsKey(normServerId) ||
      _mcpProxyProcesses.containsKey(normServerId) ||
      _mcpProxyLocalHttpProcesses.containsKey(normServerId);
  if (wasRunning) {
    await _stopMcpProxyServer(normServerId);
    return _json({'server_id': normServerId, 'status': 'stopped'});
  }

  return _jsonError('Server not running: $normServerId', status: 404);
}

bool _shouldAutoLaunchLocalHttpMcp(
  GithubMcpServerDefinition server,
  Uri endpointUri,
) {
  final explicit = (server.envVars['MCP_LOCAL_LAUNCH'] ?? '')
      .trim()
      .toLowerCase();
  if (explicit == '1' ||
      explicit == 'true' ||
      explicit == 'yes' ||
      explicit == 'auto') {
    return true;
  }

  final isLoopback =
      endpointUri.host == '127.0.0.1' ||
      endpointUri.host == 'localhost' ||
      endpointUri.host == '::1';
  final hasEntryPoint = (server.entryPoint ?? '').trim().isNotEmpty;
  final installType = server.installType.toLowerCase();
  return isLoopback &&
      hasEntryPoint &&
      (installType == 'python' || installType == 'node');
}

List<String> _expandLaunchArgs(List<String> args, Map<String, String> envVars) {
  if (args.isEmpty) return const [];
  final template = RegExp(r'\{\{\s*([a-zA-Z0-9_\-.]+)\s*\}\}');
  final lowerEnv = <String, String>{
    for (final e in envVars.entries) e.key.toLowerCase(): e.value,
  };

  String resolveKey(String key) {
    return envVars[key] ??
        envVars[key.toUpperCase()] ??
        lowerEnv[key.toLowerCase()] ??
        '';
  }

  Iterable<String> splitIfList(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) return const [];
    if (normalized.contains(';')) {
      return normalized
          .split(';')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty);
    }
    if (normalized.contains('\n')) {
      return normalized
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty);
    }
    return [normalized];
  }

  final expanded = <String>[];
  for (final rawArg in args) {
    final matches = template.allMatches(rawArg).toList();
    if (matches.isEmpty) {
      expanded.add(rawArg);
      continue;
    }

    final singleToken =
        matches.length == 1 &&
        matches.first.start == 0 &&
        matches.first.end == rawArg.length;
    if (singleToken) {
      final key = matches.first.group(1)!;
      expanded.addAll(splitIfList(resolveKey(key)));
      continue;
    }

    var replaced = rawArg;
    for (final m in matches) {
      final key = m.group(1)!;
      replaced = replaced.replaceAll(m.group(0)!, resolveKey(key));
    }
    expanded.add(replaced);
  }
  return expanded;
}

String _resolveProxyEntryPoint(GithubMcpServerDefinition server) {
  final installType = server.installType.toLowerCase();
  final defaultEntryPoint = installType == 'node'
      ? 'index.js'
      : server.packageName;
  final rawEntryPoint = (server.entryPoint ?? defaultEntryPoint).trim();
  if (rawEntryPoint.isEmpty) return defaultEntryPoint;
  if (p.isAbsolute(rawEntryPoint)) return rawEntryPoint;

  final type = installType == 'node' ? 'node' : 'python';
  final safeServerName = server.name.trim().replaceAll(
    RegExp(r'[^a-zA-Z0-9._-]+'),
    '_',
  );
  return p.join(
    resolveServerMcpServersDir(),
    type,
    safeServerName,
    rawEntryPoint,
  );
}

String _pythonVenvExecutableForServerDir(String serverDirPath) {
  return Platform.isWindows
      ? p.join(serverDirPath, '.venv', 'Scripts', 'python.exe')
      : p.join(serverDirPath, '.venv', 'bin', 'python');
}

Future<void> _createPythonVenvIfMissing(
  Directory serverDir, {
  required String serverName,
}) async {
  final pythonExe = File(_pythonVenvExecutableForServerDir(serverDir.path));
  if (await pythonExe.exists()) {
    return;
  }

  log.info('[API] Creating Python virtualenv for $serverName');
  final proc = await Process.start(
    'python3',
    <String>['-m', 'venv', p.join(serverDir.path, '.venv')],
    runInShell: false,
    workingDirectory: serverDir.path,
    environment: _serverRuntimeEnv(),
  );

  final stdoutText = await proc.stdout
      .transform(const SystemEncoding().decoder)
      .join();
  final stderrText = await proc.stderr
      .transform(const SystemEncoding().decoder)
      .join();
  final exitCode = await proc.exitCode.timeout(
    const Duration(minutes: 5),
    onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      throw TimeoutException(
        'Timed out creating Python virtualenv for $serverName',
      );
    },
  );

  if (exitCode != 0 || !await pythonExe.exists()) {
    final msg = stderrText.trim().isNotEmpty
        ? stderrText.trim()
        : stdoutText.trim();
    throw Exception(
      'Virtualenv creation failed for $serverName (exit $exitCode): $msg',
    );
  }
}

Future<void> _preparePythonLocalHttpMcpServer(
  GithubMcpServerDefinition server,
  String entryPointPath,
) async {
  final serverDir = Directory(p.dirname(entryPointPath));
  if (!await serverDir.exists()) {
    throw Exception('Python MCP server directory missing: ${serverDir.path}');
  }

  await _createPythonVenvIfMissing(serverDir, serverName: server.name);

  final requirementsFile = File(p.join(serverDir.path, 'requirements.txt'));
  final installedMarker = File(p.join(serverDir.path, '.installed'));
  if (!await requirementsFile.exists() || await installedMarker.exists()) {
    return;
  }

  final pythonExe = _pythonVenvExecutableForServerDir(serverDir.path);
  log.info('[API] Installing Python MCP dependencies for ${server.name}');
  final proc = await Process.start(
    'uv',
    <String>[
      'pip',
      'install',
      '--python',
      pythonExe,
      '-r',
      requirementsFile.path,
    ],
    runInShell: false,
    workingDirectory: serverDir.path,
    environment: _serverRuntimeEnv(),
  );

  final stdoutText = await proc.stdout
      .transform(const SystemEncoding().decoder)
      .join();
  final stderrText = await proc.stderr
      .transform(const SystemEncoding().decoder)
      .join();
  final exitCode = await proc.exitCode.timeout(
    const Duration(minutes: 5),
    onTimeout: () {
      proc.kill(ProcessSignal.sigkill);
      throw TimeoutException(
        'Timed out installing Python dependencies for ${server.name}',
      );
    },
  );

  if (exitCode != 0) {
    final msg = stderrText.trim().isNotEmpty
        ? stderrText.trim()
        : stdoutText.trim();
    throw Exception(
      'Dependency install failed for ${server.name} (exit $exitCode): $msg',
    );
  }

  await installedMarker.writeAsString('1', flush: true);
}

Future<bool> _waitForLocalHttpMcpReady(
  Uri endpointUri, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  final probeUri = endpointUri.path.toLowerCase().endsWith('/mcp')
      ? endpointUri
      : endpointUri.replace(path: '${endpointUri.path}/mcp');
  final client = HttpClient();

  try {
    while (DateTime.now().isBefore(deadline)) {
      try {
        final req = await client.postUrl(probeUri);
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'probe',
            'method': 'initialize',
            'params': {
              'protocolVersion': '2024-11-05',
              'capabilities': {},
              'clientInfo': {
                'name': 'TealKit Server Proxy',
                'version': '1.0.0',
              },
            },
          }),
        );
        final resp = await req.close();
        if (resp.statusCode == 200) {
          return true;
        }
      } catch (_) {
        // Retry until timeout.
      }

      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
  } finally {
    client.close(force: true);
  }

  return false;
}

Future<Object?> _ensureLocalHttpProxyProcess(
  GithubMcpServerDefinition server,
  String httpUrl, {
  bool persistent = true,
}) async {
  final endpointUri = Uri.tryParse(httpUrl);
  if (endpointUri == null) {
    return 'Invalid MCP_HTTP_URL for ${server.name}: $httpUrl';
  }
  if (!_shouldAutoLaunchLocalHttpMcp(server, endpointUri)) return null;

  if (persistent && _mcpProxyLocalHttpProcesses.containsKey(server.id)) {
    return null;
  }

  final installType = server.installType.toLowerCase();
  if (installType != 'python' && installType != 'node') {
    return null;
  }

  final entryPoint = (server.entryPoint ?? '').trim();
  if (entryPoint.isEmpty) {
    return 'MCP local launch requested but entryPoint is missing for ${server.name}';
  }

  final resolvedEntryPoint = _resolveProxyEntryPoint(server);
  final launchArgs = _expandLaunchArgs(server.launchArgs, server.envVars);

  if (installType == 'python') {
    await _preparePythonLocalHttpMcpServer(server, resolvedEntryPoint);
  }

  final executable = installType == 'python'
      ? _pythonVenvExecutableForServerDir(p.dirname(resolvedEntryPoint))
      : 'node';
  final proc = await Process.start(
    executable,
    <String>[resolvedEntryPoint, ...launchArgs],
    runInShell: false,
    environment: _serverRuntimeEnv(server.envVars),
  );

  final key = persistent
      ? server.id
      : 'test-${server.id}-${DateTime.now().millisecondsSinceEpoch}';
  _mcpProxyLocalHttpStdoutSubs[key] = proc.stdout
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter())
      .listen((line) => log.debug('[MCP:${server.name}:stdout] $line'));
  _mcpProxyLocalHttpStderrSubs[key] = proc.stderr
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter())
      .listen((line) => log.debug('[MCP:${server.name}:stderr] $line'));

  if (persistent) {
    _mcpProxyLocalHttpProcesses[server.id] = proc;
    proc.exitCode.then((code) {
      log.warning('[API] Local HTTP MCP ${server.name} exited with code $code');
      _cancelLocalHttpIdleShutdown(server.id);
      _mcpProxyLocalHttpProcesses.remove(server.id);
      _mcpProxyLocalHttpStdoutSubs.remove(server.id)?.cancel();
      _mcpProxyLocalHttpStderrSubs.remove(server.id)?.cancel();
    });
  }

  final ready = await _waitForLocalHttpMcpReady(endpointUri);
  if (!ready) {
    proc.kill();
    await _mcpProxyLocalHttpStdoutSubs.remove(key)?.cancel();
    await _mcpProxyLocalHttpStderrSubs.remove(key)?.cancel();
    if (persistent) {
      _mcpProxyLocalHttpProcesses.remove(server.id);
    }
    return 'Local MCP process for ${server.name} did not become ready at $httpUrl';
  }

  if (!persistent) {
    return {'process': proc, 'tempServerId': key};
  }
  return null;
}

Future<Response> _handleGetMcpServerTools(
  Request request,
  String serverId,
) async {
  final normServerId = _normalizeServerId(serverId);
  final internalImpl = _mcpProxyInternals[normServerId];
  if (internalImpl != null) {
    await internalImpl.refresh();
    return _json({
      'server_id': normServerId,
      'tools': internalImpl.tools.map((t) => t.toJson()).toList(),
    });
  }

  final client = _mcpProxyClients[normServerId];
  if (client != null) {
    return _json({
      'server_id': normServerId,
      'tools': client.availableTools.map((t) => t.toJson()).toList(),
    });
  }

  final tools = _mcpProxyTools[normServerId];
  if (tools != null) {
    return _json({
      'server_id': normServerId,
      'tools': tools.map((t) => t.toJson()).toList(),
    });
  }

  if (_mcpProxyProcesses.containsKey(normServerId)) {
    return _json({'server_id': normServerId, 'tools': []});
  }

  return _jsonError('Server not running: $normServerId', status: 404);
}

Future<Response> _handleCallMcpTool(
  Request request,
  String serverId,
  String toolName,
) async {
  final normServerId = _normalizeServerId(serverId);
  final body = await _parseJsonBody(request);
  final arguments = (body?['arguments'] as Map<String, dynamic>?) ?? {};
  final tracksIdle = _mcpProxyLocalHttpProcesses.containsKey(normServerId);
  if (tracksIdle) {
    _cancelLocalHttpIdleShutdown(normServerId);
  }

  final internalImpl = _mcpProxyInternals[normServerId];
  if (internalImpl != null) {
    try {
      final raw = await internalImpl.callTool(toolName, arguments);
      final isError = raw['success'] == false;
      final text = isError
          ? (raw['error']?.toString() ?? jsonEncode(raw))
          : (raw['output']?.toString() ??
                raw['result']?.toString() ??
                jsonEncode(raw));
      final result = MCPToolResult(
        content: [MCPContent(type: 'text', text: text)],
        isError: isError,
      );
      return _json(result.toJson());
    } catch (e) {
      log.error('[API] Internal MCP tool call $normServerId/$toolName failed: $e');
      return _jsonError('Tool call failed: $e', status: 502);
    }
  }

  final client = _mcpProxyClients[normServerId];
  if (client != null) {
    try {
      final result = await client.callTool(toolName, arguments);
      return _json(result.toJson());
    } catch (e) {
      log.error('[API] MCP tool call $normServerId/$toolName failed: $e');
      return _jsonError('Tool call failed: $e', status: 502);
    } finally {
      if (tracksIdle) {
        _armLocalHttpIdleShutdown(normServerId);
      }
    }
  }

  final proc = _mcpProxyProcesses[normServerId];
  if (proc != null) {
    try {
      final result = await _callStdioProxyTool(proc, toolName, arguments);
      return _json(result.toJson());
    } catch (e) {
      log.error('[API] Stdio MCP tool call $normServerId/$toolName failed: $e');
      return _jsonError('Tool call failed: $e', status: 502);
    }
  }

  if (tracksIdle) {
    _armLocalHttpIdleShutdown(normServerId);
  }

  return _jsonError('Server not running: $normServerId', status: 404);
}

Future<MCPToolResult> _callStdioProxyTool(
  StdioMcpProcess proc,
  String name,
  Map<String, dynamic> arguments,
) async {
  final id = 'proxy-call-${DateTime.now().millisecondsSinceEpoch}';
  proc.writeLine(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {'name': name, 'arguments': arguments},
    }),
  );

  await for (final line in proc.lines.timeout(const Duration(seconds: 60))) {
    if (line.trim().isEmpty) continue;
    try {
      final j = jsonDecode(line) as Map<String, dynamic>;
      if (j['id'] == id) {
        if (j.containsKey('error')) {
          return MCPToolResult(
            content: [MCPContent(type: 'text', text: jsonEncode(j['error']))],
            isError: true,
          );
        }
        return MCPToolResult.fromJson(j['result'] as Map<String, dynamic>);
      }
    } catch (_) {}
  }

  return MCPToolResult(
    content: [
      MCPContent(type: 'text', text: '{"error":"Timeout calling $name"}'),
    ],
    isError: true,
  );
}

Future<Response> _handleMcpServerEvents(
  Request request,
  String serverId,
) async {
  final normServerId = _normalizeServerId(serverId);
  final proc = _mcpProxyProcesses[normServerId];
  if (proc == null) {
    if (!_mcpProxyClients.containsKey(normServerId)) {
      return _jsonError('Server not running: $normServerId', status: 404);
    }
    return _jsonError(
      'Event streaming is only available for stdio-based servers',
      status: 400,
    );
  }

  final stream = proc.lines.map<List<int>>(
    (line) => utf8.encode('data: ${line.replaceAll('\n', ' ')}\n\n'),
  );

  return Response(
    200,
    body: stream,
    headers: const {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'X-Accel-Buffering': 'no',
    },
  );
}

// ── Skills ──────────────────────────────────────────────────────────────────

/// GET /api/v1/skills — list all stored Tool Hints.
Future<Response> _handleListSkills(Request request) async {
  try {
    final db = ServerDuckDbService();
    final mcpType = request.url.queryParameters['mcp_type'];
    final skills = await db.getAllToolSkills(mcpType: mcpType);
    return _json({'skills': skills});
  } catch (e) {
    log.error('[API] GET /skills failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

/// PUT /api/v1/skills — upsert a skill record.
Future<Response> _handleSaveSkill(Request request) async {
  try {
    final db = ServerDuckDbService();
    final body = await request.readAsString();
    final json = jsonDecode(body) as Map<String, dynamic>;
    await db.saveToolSkill(json);
    return _json({'ok': true});
  } catch (e) {
    log.error('[API] PUT /skills failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

/// DELETE /api/v1/skills/:id — delete skill by id.
Future<Response> _handleDeleteSkill(Request request, String id) async {
  try {
    final db = ServerDuckDbService();
    await db.deleteToolSkill(id);
    return _json({'ok': true});
  } catch (e) {
    log.error('[API] DELETE /skills/$id failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

/// DELETE /api/v1/skills/tool/:name — delete all skills for a given tool name.
Future<Response> _handleDeleteSkillByToolName(
  Request request,
  String name,
) async {
  try {
    final db = ServerDuckDbService();
    await db.deleteToolSkillsByToolName(name);
    return _json({'ok': true});
  } catch (e) {
    log.error('[API] DELETE /skills/tool/$name failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

/// POST /api/v1/skills/build — start async skill generation, returns 202.
Future<Response> _handleBuildSkills(Request request) async {
  try {
    final body = await request.readAsString();
    final json = body.isNotEmpty
        ? jsonDecode(body) as Map<String, dynamic>
        : <String, dynamic>{};
    final addMissingOnly = (json['add_missing_only'] as bool?) ?? true;
    final clearBeforeBuild = (json['clear_before_build'] as bool?) ?? false;
    final clearCustom = (json['clear_custom'] as bool?) ?? false;
    final toolName = json['tool_name'] as String?;
    final mcpType = json['mcp_type'] as String?;
    // Defer execution to the next event loop iteration so we return 202 instantly.
    Timer.run(() {
      ServerSkillService.instance.buildSkills(
        addMissingOnly: addMissingOnly,
        toolName: toolName,
        mcpType: mcpType,
        clearBeforeBuild: clearBeforeBuild,
        clearCustom: clearCustom,
      );
    });
    return _json({'ok': true, 'message': 'Build started'}, status: 202);
  } catch (e) {
    log.error('[API] POST /skills/build failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

/// GET /api/v1/skills/build/status — return current build progress.
Future<Response> _handleGetSkillsBuildStatus(Request request) async {
  return _json(ServerSkillService.instance.getStatus());
}

// ── Playground Sessions ───────────────────────────────────────

Future<Response> _handleListPlaygroundSessions(Request request) async {
  try {
    final sessions = await ServerDuckDbService().getAllPlaygroundSessions();
    return _json({'sessions': sessions});
  } catch (e) {
    log.error('[API] GET /playground/sessions failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleSavePlaygroundSession(Request request) async {
  final body = await _parseJsonBody(request);
  if (body == null) return _jsonError('Invalid or missing JSON body');

  final id = body['id'] as String?;
  final name = body['name'] as String?;
  if (id == null || id.trim().isEmpty) {
    return _jsonError('Missing required field: id');
  }
  if (name == null || name.trim().isEmpty) {
    return _jsonError('Missing required field: name');
  }

  try {
    await ServerDuckDbService().savePlaygroundSession(body);
    return _json({'status': 'saved', 'id': id});
  } catch (e) {
    log.error('[API] POST /playground/sessions failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

Future<Response> _handleDeletePlaygroundSession(
  Request request,
  String id,
) async {
  try {
    await ServerDuckDbService().deletePlaygroundSession(id);
    return _json({'deleted': id});
  } catch (e) {
    log.error('[API] DELETE /playground/sessions/$id failed: $e');
    return _jsonError(e.toString(), status: 500);
  }
}

String _normalizeServerId(String id) {
  var s = id.trim();
  if (s.startsWith('https:/') && !s.startsWith('https://')) {
    s = s.replaceFirst('https:/', 'https://');
  } else if (s.startsWith('http:/') && !s.startsWith('http://')) {
    s = s.replaceFirst('http:/', 'http://');
  }
  return s;
}
