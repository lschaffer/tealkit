import 'dart:async';
import 'dart:convert';

import 'package:flutter_js/extensions/fetch.dart';
import 'package:flutter_js/flutter_js.dart';

class JsToolValidationResult {
  final bool valid;
  final List<String> errors;
  final List<String> warnings;
  final bool runtimeAvailable;
  final String? toolName;
  final String? description;
  final Map<String, dynamic>? inputSchema;

  const JsToolValidationResult({
    required this.valid,
    required this.errors,
    required this.warnings,
    required this.runtimeAvailable,
    this.toolName,
    this.description,
    this.inputSchema,
  });
}

class JsToolExecutionResult {
  final bool success;
  final String? error;
  final dynamic result;
  final List<String> logs;
  final int durationMs;

  const JsToolExecutionResult({required this.success, this.error, this.result, this.logs = const [], this.durationMs = 0});
}

class JsToolRuntimeService {
  JsToolRuntimeService._();
  static final JsToolRuntimeService instance = JsToolRuntimeService._();

  JavascriptRuntime? _runtime;
  bool _runtimeInitFailed = false;
  String? _runtimeInitError;

  static const int _maxScriptBytes = 64 * 1024;
  static const int _maxPayloadBytes = 256 * 1024;
  static final List<RegExp> _forbiddenPatterns = [
    RegExp(r'\brequire\s*\('),
    RegExp(r'\bimport\s+'),
    RegExp(r'\bprocess\b'),
    RegExp(r'\bchild_process\b'),
    RegExp(r'\bfs\b'),
    RegExp(r'\bnet\b'),
    RegExp(r'\btls\b'),
    RegExp(r'\bdgram\b'),
    RegExp(r'\bworker_threads\b'),
  ];

  Future<JavascriptRuntime?> _ensureRuntime() async {
    if (_runtime != null) return _runtime;
    if (_runtimeInitFailed) return null;

    try {
      final runtime = await _createRuntimeWithFallback();
      _runtime = runtime;
      _runtimeInitError = null;
      return runtime;
    } catch (error) {
      _runtimeInitFailed = true;
      _runtimeInitError = error.toString();
      return null;
    }
  }

  Future<JavascriptRuntime> _createRuntimeWithFallback() async {
    try {
      final quickJsRuntime = getJavascriptRuntime(xhr: true);
      await quickJsRuntime.enableFetch();
      quickJsRuntime.enableHandlePromises();
      return quickJsRuntime;
    } catch (quickJsError) {
      final javaScriptCoreRuntime = getJavascriptRuntime(forceJavascriptCoreOnAndroid: true, xhr: true);
      try {
        await javaScriptCoreRuntime.enableFetch();
        javaScriptCoreRuntime.enableHandlePromises();
        return javaScriptCoreRuntime;
      } catch (jscError) {
        throw 'QuickJS init failed: $quickJsError | JavaScriptCore init failed: $jscError';
      }
    }
  }

  Future<bool> isRuntimeAvailable() async {
    return await _ensureRuntime() != null;
  }

  Future<JsToolValidationResult> validateToolCode(String jsCode) async {
    final errors = <String>[];
    final warnings = <String>[];

    final trimmed = jsCode.trim();
    if (trimmed.isEmpty) {
      return const JsToolValidationResult(valid: false, errors: ['JavaScript code is empty.'], warnings: [], runtimeAvailable: false);
    }

    final bytes = utf8.encode(trimmed).length;
    if (bytes > _maxScriptBytes) {
      errors.add('Script too large ($bytes bytes). Max allowed is $_maxScriptBytes bytes.');
    }

    if (!trimmed.contains('generatedTool')) {
      errors.add('Code must define a generatedTool object.');
    }

    for (final pattern in _forbiddenPatterns) {
      if (pattern.hasMatch(trimmed)) {
        errors.add('Forbidden JavaScript token detected: ${pattern.pattern}');
      }
    }

    final runtimeAvailable = await isRuntimeAvailable();
    if (!runtimeAvailable) {
      warnings.add('Embedded JavaScript runtime not available. Deep sandbox validation is skipped.');
      return JsToolValidationResult(valid: errors.isEmpty, errors: errors, warnings: warnings, runtimeAvailable: false);
    }

    final sandboxResult = await _runSandbox(jsCode: trimmed, mode: 'validate', args: const {});
    if (!sandboxResult.success) {
      errors.add(sandboxResult.error ?? 'Validation failed in sandbox runtime.');
      return JsToolValidationResult(valid: false, errors: errors, warnings: warnings, runtimeAvailable: true);
    }

    final payload = sandboxResult.result;
    if (payload is! Map<String, dynamic>) {
      errors.add('Sandbox validation returned an invalid payload.');
      return JsToolValidationResult(valid: false, errors: errors, warnings: warnings, runtimeAvailable: true);
    }

    final toolName = (payload['name'] as String?)?.trim();
    final description = (payload['description'] as String?)?.trim();
    final inputSchema = (payload['inputSchema'] is Map)
        ? (payload['inputSchema'] as Map).cast<String, dynamic>()
        : <String, dynamic>{'type': 'object', 'properties': {}};

    if (toolName == null || toolName.isEmpty) {
      errors.add('generatedTool.name is missing or empty.');
    }
    if (description == null || description.isEmpty) {
      warnings.add('generatedTool.description is empty.');
    }
    if (inputSchema['type'] == null) {
      warnings.add('inputSchema has no explicit type; expected an object schema.');
    }

    return JsToolValidationResult(
      valid: errors.isEmpty,
      errors: errors,
      warnings: warnings,
      runtimeAvailable: true,
      toolName: toolName,
      description: description,
      inputSchema: inputSchema,
    );
  }

  Future<JsToolExecutionResult> testExecute({required String jsCode, required Map<String, dynamic> args, int timeoutMs = 8000}) async {
    return _runSandbox(jsCode: jsCode, mode: 'execute', args: args, timeoutMs: timeoutMs.clamp(250, 15000));
  }

  Future<JsToolExecutionResult> _runSandbox({
    required String jsCode,
    required String mode,
    required Map<String, dynamic> args,
    int timeoutMs = 8000,
  }) async {
    try {
      final runtime = await _ensureRuntime();
      if (runtime == null) {
        final details = (_runtimeInitError ?? '').trim();
        final message = details.isEmpty
            ? 'Embedded JavaScript runtime is not available.'
            : 'Embedded JavaScript runtime is not available. $details';
        return JsToolExecutionResult(success: false, error: message);
      }

      final source = _buildSandboxSource(jsCode: jsCode, mode: mode, args: args);

      var evalResult = await runtime.evaluateAsync(source);
      if (evalResult.isPromise) {
        evalResult = await runtime.handlePromise(evalResult, timeout: Duration(milliseconds: timeoutMs + 1000));
      } else if (evalResult.rawResult is Future) {
        // QuickJsRuntime2 converts JS Promises to Dart Futures directly via _jsToDart.
        // The Dart Completer inside is only resolved when QuickJS processes pending jobs
        // via executePendingJob(). We must pump that loop while awaiting, otherwise the
        // Future never completes — even for purely synchronous tools like a calculator.
        var pumpDone = false;
        Future<void> pump() async {
          while (!pumpDone) {
            runtime.executePendingJob();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }

        pump(); // fire-and-forget pump loop
        try {
          final dynamic res = await (evalResult.rawResult as Future).timeout(Duration(milliseconds: timeoutMs + 1000));
          pumpDone = true;
          evalResult = JsEvalResult('$res', res);
        } on TimeoutException {
          pumpDone = true;
          return JsToolExecutionResult(success: false, error: 'Sandbox execution timed out.');
        }
      }

      if (evalResult.isError) {
        return JsToolExecutionResult(success: false, error: evalResult.stringResult);
      }

      final raw = evalResult.stringResult.trim();
      if (raw.isEmpty) {
        return const JsToolExecutionResult(success: false, error: 'Sandbox returned empty output.');
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const JsToolExecutionResult(success: false, error: 'Sandbox returned invalid JSON.');
      }

      final success = decoded['ok'] == true;
      final logs = (decoded['logs'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
      final durationMs = (decoded['durationMs'] as num?)?.toInt() ?? 0;

      dynamic result = decoded['result'];
      if (result is String) {
        final trimmed = result.trim();
        if (trimmed.length <= _maxPayloadBytes) {
          try {
            result = jsonDecode(trimmed);
          } catch (_) {}
        }
      }

      return JsToolExecutionResult(
        success: success,
        error: decoded['error']?.toString(),
        result: success ? result : null,
        logs: logs,
        durationMs: durationMs,
      );
    } on TimeoutException catch (e) {
      return JsToolExecutionResult(success: false, error: e.message ?? 'Sandbox execution timed out.');
    } catch (e) {
      return JsToolExecutionResult(success: false, error: 'Sandbox error: $e');
    }
  }

  String _buildSandboxSource({required String jsCode, required String mode, required Map<String, dynamic> args}) {
    final argsJson = jsonEncode(args);
    final modeJson = jsonEncode(mode);

    return '''
(() => {
  const __args = $argsJson;
  const __mode = $modeJson;
  const __maxPayload = $_maxPayloadBytes;
  const __started = Date.now();
  const __logs = [];

  const __console = {
    log: (...items) => __logs.push(items.map((i) => String(i)).join(' ')),
  };

  try {
    globalThis.console = __console;
  } catch (_) {}

  try {
    $jsCode
    const __tool = (typeof generatedTool !== 'undefined') ? generatedTool : globalThis.generatedTool;

    if (!__tool || typeof __tool !== 'object') {
      return JSON.stringify({ ok: false, error: 'generatedTool object not found.', logs: __logs, durationMs: Date.now() - __started });
    }
    if (typeof __tool.execute !== 'function') {
      return JSON.stringify({ ok: false, error: 'generatedTool.execute must be a function.', logs: __logs, durationMs: Date.now() - __started });
    }

    if (__mode === 'validate') {
      return JSON.stringify({
        ok: true,
        result: {
          name: typeof __tool.name === 'string' ? __tool.name : '',
          description: typeof __tool.description === 'string' ? __tool.description : '',
          inputSchema: (__tool.inputSchema && typeof __tool.inputSchema === 'object') ? __tool.inputSchema : { type: 'object', properties: {} },
        },
        logs: __logs,
        durationMs: Date.now() - __started,
      });
    }

    // Call execute and detect sync vs async at runtime.
    // If execute() returns a plain value (sync tool like a calculator), we return
    // a JSON string immediately — evaluate() resolves synchronously, no Dart Future involved.
    // If execute() returns a Promise/thenable (fetch-based tool), we return that Promise
    // so QuickJS can resolve it asynchronously via executePendingJob().
    const __execResult = __tool.execute(__args);
    const __isPromise = __execResult !== null && typeof __execResult === 'object' && typeof __execResult.then === 'function';

    if (!__isPromise) {
      // Sync path — return immediately as plain string
      let resultValue = __execResult;
      if (typeof resultValue !== 'string') {
        resultValue = JSON.stringify(resultValue);
      }
      const __length = String(resultValue).length;
      if (__length > __maxPayload) {
        return JSON.stringify({ ok: false, error: 'Result too large (' + __length + ' bytes).', logs: __logs, durationMs: Date.now() - __started });
      }
      return JSON.stringify({ ok: true, result: resultValue, logs: __logs, durationMs: Date.now() - __started });
    }

    // Async path — return the Promise; Dart will await + pump executePendingJob()
    return __execResult
      .then((value) => {
        let resultValue = value;
        if (typeof resultValue !== 'string') {
          resultValue = JSON.stringify(resultValue);
        }
        const __length = String(resultValue).length;
        if (__length > __maxPayload) {
          return JSON.stringify({ ok: false, error: 'Result too large (' + __length + ' bytes).', logs: __logs, durationMs: Date.now() - __started });
        }
        return JSON.stringify({ ok: true, result: resultValue, logs: __logs, durationMs: Date.now() - __started });
      })
      .catch((error) => {
        return JSON.stringify({ ok: false, error: String((error && error.message) || error), logs: __logs, durationMs: Date.now() - __started });
      });
  } catch (error) {
    return JSON.stringify({ ok: false, error: String((error && error.message) || error), logs: __logs, durationMs: Date.now() - __started });
  }
})()
''';
  }
}
