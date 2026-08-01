import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/workflow_task.dart';
// app_logger and credential_cipher imports removed for tealkit_api

/// Thrown when the server returns a 4xx or 5xx response.
class ApiException implements Exception {
  final int statusCode;
  final String message;

  const ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Thin HTTP client for the TealKit server REST API.
///
/// All methods throw [ApiException] on 4xx/5xx responses and rethrow
/// [Exception] on network errors.  Connection timeouts default to 60 s.
class ServerApiClient {
  static void Function(String message)? logCallback;

  static void _logWarning(String message) {
    logCallback?.call(message);
  }

  final String serverUrl;
  final String? apiKey;

  static const _timeout = Duration(seconds: 30); // Reduced from 60s to fail faster
  static const _healthTimeout = Duration(seconds: 5); // Quick health check
  static const _sslTimeout = Duration(seconds: 15); // SSL/TLS handshake timeout

  ServerApiClient({required this.serverUrl, this.apiKey});

  // ── Helpers ───────────────────────────────────────────────────

  String _url(String path) {
    final base = serverUrl.trimRight().replaceAll(RegExp(r'/+$'), '');
    return '$base$path';
  }

  Map<String, String> get _headers {
    final h = <String, String>{'Content-Type': 'application/json', 'Accept': 'application/json'};
    if (apiKey != null && apiKey!.isNotEmpty) {
      h['Authorization'] = 'Bearer $apiKey';
    }
    return h;
  }

  void _checkStatus(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    String message = 'HTTP ${response.statusCode}';
    try {
      final body = jsonDecode(response.body) as Map?;
      message = body?['error']?.toString() ?? message;
    } catch (_) {}
    throw ApiException(response.statusCode, message);
  }

  Map<String, dynamic> _taskTransportJson(WorkflowTask task) {
    final json = task.toJson();
    json['internal_mcps'] = task.internalMcps.map(_internalMcpTransportJson).toList();
    final rawExecutors = json['agents'];
    if (rawExecutors is List) {
      json['agents'] = task.agents.map((exec) {
        final execJson = exec.toJson();
        execJson['internal_mcps'] = exec.internalMcps.map(_internalMcpTransportJson).toList();
        return execJson;
      }).toList();
    }
    return json;
  }

  Map<String, dynamic> _normalizeTaskTransportJson(Map<String, dynamic> taskJson) {
    return taskJson;
  }

  Map<String, dynamic> _internalMcpTransportJson(InternalMcpEntry entry) => {
    'id': entry.id,
    'mcp_type': entry.mcpType,
    'label': entry.label,
    'init_params': entry.initParams,
    if (entry.systemPrompt != null) 'system_prompt': entry.systemPrompt,
    'enabled': entry.enabled,
  };

  // ── Health ────────────────────────────────────────────────────

  /// Returns `true` if the server is reachable and healthy.
  Future<bool> ping() async {
    try {
      final r = await http.get(Uri.parse(_url('/health')), headers: _headers).timeout(_healthTimeout);
      return r.statusCode == 200;
    } catch (e) {
      _logWarning('[ServerApiClient] ping timeout after ${_healthTimeout.inSeconds}s: $e');
      return false;
    }
  }

  /// Get health status payload from `/health`.
  Future<Map<String, dynamic>> getHealthStatus({Duration? timeout}) async {
    try {
      final r = await http.get(Uri.parse(_url('/health')), headers: _headers).timeout(timeout ?? _healthTimeout);
      if (r.statusCode == 200) {
        return jsonDecode(r.body) as Map<String, dynamic>;
      }
    } catch (e) {
      _logWarning('[ServerApiClient] getHealthStatus failed: $e');
    }
    return const {};
  }

  /// Returns `true` only when an authenticated API endpoint accepts the API key.
  ///
  /// This validates authorization, not just network reachability.
  Future<bool> validateAuthorization({Duration? timeout}) async {
    final requestTimeout = timeout ?? _sslTimeout; // Use SSL timeout by default (faster than _timeout)
    try {
      await getLlmSettings(timeout: requestTimeout);
      return true;
    } on ApiException catch (e) {
      if (e.statusCode == 401 || e.statusCode == 403) {
        _logWarning('[ServerApiClient] authorization denied: ${e.statusCode} ${e.message}');
        return false;
      }
      _logWarning('[ServerApiClient] authorization check API error: ${e.statusCode} ${e.message}');
      return false;
    } catch (e) {
      _logWarning('[ServerApiClient] authorization check timeout/network error after ${requestTimeout.inSeconds}s: $e');
      return false;
    }
  }

  // ── Tasks ─────────────────────────────────────────────────────

  Future<List<WorkflowTask>> getAllTasks() async {
    final r = await http.get(Uri.parse(_url('/api/v1/tasks')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final list = body['tasks'] as List? ?? [];
    return list
        .whereType<Map<String, dynamic>>()
        .map((json) => WorkflowTask.fromJson(_normalizeTaskTransportJson(json)))
        .toList();
  }

  Future<WorkflowTask?> getTask(String id, {Duration? timeout}) async {
    final r = await http.get(Uri.parse(_url('/api/v1/tasks/$id')), headers: _headers).timeout(timeout ?? _timeout);
    if (r.statusCode == 404) return null;
    _checkStatus(r);
    return WorkflowTask.fromJson(_normalizeTaskTransportJson(jsonDecode(r.body) as Map<String, dynamic>));
  }

  /// Creates or updates a task on the server.
  Future<void> saveTask(WorkflowTask task) async {
    final payload = _taskTransportJson(task);
    // Try PUT first (update); fall back to POST (create) on 404.
    final r = await http.put(Uri.parse(_url('/api/v1/tasks/${task.id}')), headers: _headers, body: jsonEncode(payload)).timeout(_timeout);

    if (r.statusCode == 404) {
      final r2 = await http.post(Uri.parse(_url('/api/v1/tasks')), headers: _headers, body: jsonEncode(payload)).timeout(_timeout);
      _checkStatus(r2);
      return;
    }
    _checkStatus(r);
  }

  Future<void> deleteTask(String id) async {
    final r = await http.delete(Uri.parse(_url('/api/v1/tasks/$id')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
  }

  Future<void> toggleTask(String taskId, bool enabled) async {
    final r = await http
        .put(Uri.parse(_url('/api/v1/tasks/$taskId')), headers: _headers, body: jsonEncode({'enabled': enabled}))
        .timeout(_timeout);
    _checkStatus(r);
  }

  Future<String> runTask(String taskId) async {
    final r = await http.post(Uri.parse(_url('/api/v1/tasks/$taskId/run')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return body['run_id'] as String? ?? '';
  }

  Future<void> cancelTask(String taskId) async {
    final r = await http.post(Uri.parse(_url('/api/v1/tasks/$taskId/cancel')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
  }

  Future<bool> getTaskRunStatus(String taskId, {Duration? timeout}) async {
    final r = await http.get(Uri.parse(_url('/api/v1/tasks/$taskId/run-status')), headers: _headers).timeout(timeout ?? _timeout);
    if (r.statusCode == 404) return false;
    _checkStatus(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return body['running'] == true;
  }

  Future<Map<String, dynamic>?> getTaskOutput(String taskId, {Duration? timeout}) async {
    final r = await http.get(Uri.parse(_url('/api/v1/tasks/$taskId/output')), headers: _headers).timeout(timeout ?? _timeout);
    if (r.statusCode == 404) return null;
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Fetch execution history for a task from the server.
  /// Returns execution logs with timestamps, success status, results, and errors.
  Future<Map<String, dynamic>?> getTaskExecutionLogs(String taskId, {Duration? timeout}) async {
    final r = await http.get(Uri.parse(_url('/api/v1/tasks/$taskId/execution-logs')), headers: _headers).timeout(timeout ?? _timeout);
    if (r.statusCode == 404) return null;
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Fetch list of output files for a task from the server.
  /// Returns a list of output files with timestamps and sizes.
  Future<Map<String, dynamic>?> getTaskOutputFiles(String taskId, {Duration? timeout}) async {
    final r = await http.get(Uri.parse(_url('/api/v1/tasks/$taskId/output-files')), headers: _headers).timeout(timeout ?? _timeout);
    if (r.statusCode == 404) return null;
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Download a specific output file from the server.
  /// Returns the file contents as bytes.
  /// [taskId] is the task ID, [runId] is the run timestamp (YYYYMMDD-HHMMSS format),
  /// [fileName] is the filename (e.g., "output.log", "usd_eur_rate.json").
  Future<Uint8List> downloadTaskOutputFile(String taskId, String runId, String fileName, {Duration? timeout}) async {
    final encodedFileName = Uri.encodeComponent(fileName);
    final url = _url('/api/v1/tasks/$taskId/output/$runId/$encodedFileName');
    final r = await http.get(Uri.parse(url), headers: _headers).timeout(timeout ?? _timeout);

    if (r.statusCode == 404) {
      throw ApiException(404, 'File not found: $fileName');
    }
    if (r.statusCode == 400) {
      throw ApiException(400, 'Invalid filename');
    }
    _checkStatus(r);
    return r.bodyBytes;
  }

  /// Download a specific output file and get it as a String (for text files).
  Future<String> downloadTaskOutputFileAsText(String taskId, String runId, String fileName, {Duration? timeout}) async {
    final bytes = await downloadTaskOutputFile(taskId, runId, fileName, timeout: timeout);
    return utf8.decode(bytes);
  }

  /// Fetch scheduler log entries from the server.
  Future<Map<String, dynamic>> getSchedulerLog({int limit = 50, int offset = 0, Duration? timeout}) async {
    final r = await http
        .get(Uri.parse(_url('/api/v1/scheduler/log?limit=$limit&offset=$offset')), headers: _headers)
        .timeout(timeout ?? _timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // ── Sync ──────────────────────────────────────────────────────

  /// Push [tasks] to the server in a single bulk-upsert call.
  Future<Map<String, dynamic>> syncTasks(List<Map<String, dynamic>> tasks) async {
    final normalizedTasks = tasks.map(_normalizeTaskTransportJson).toList();
    final r = await http
        .post(Uri.parse(_url('/api/v1/sync/tasks')), headers: _headers, body: jsonEncode({'tasks': normalizedTasks}))
        .timeout(const Duration(seconds: 60));
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Push settings sections to the server.  Only keys present in [payload]
  /// will be updated.  Expected keys: `llm`, `data_sources`, `preferences`, `external_tools`.
  Future<void> syncSettings(Map<String, dynamic> payload) async {
    final r = await http.post(Uri.parse(_url('/api/v1/sync/settings')), headers: _headers, body: jsonEncode(payload)).timeout(_timeout);
    _checkStatus(r);
  }

  /// Push Python tool definitions to the server.
  Future<Map<String, dynamic>> syncPyTools(List<Map<String, dynamic>> tools) async {
    final r = await http
        .post(Uri.parse(_url('/api/v1/sync/py_tools')), headers: _headers, body: jsonEncode({'tools': tools}))
        .timeout(const Duration(seconds: 60));
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Initialize the virtual environment for a Python tool on the server.
  Future<Map<String, dynamic>> initPyTool(String toolId) async {
    final r = await http
        .post(Uri.parse(_url('/api/v1/py_tools/${Uri.encodeComponent(toolId)}/init')), headers: _headers)
        .timeout(const Duration(seconds: 360));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Run a Python tool on the server and return the result.
  Future<Map<String, dynamic>> runPyTool(String toolId, Map<String, dynamic> args, {int? timeoutSeconds}) async {
    final body = <String, dynamic>{'args': args};
    if (timeoutSeconds != null) body['timeoutSeconds'] = timeoutSeconds;
    final r = await http
        .post(Uri.parse(_url('/api/v1/py_tools/${Uri.encodeComponent(toolId)}/run')), headers: _headers, body: jsonEncode(body))
        .timeout(Duration(seconds: (timeoutSeconds ?? 60) + 10));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Push JavaScript tool definitions to the server.
  Future<Map<String, dynamic>> syncJsTools(List<Map<String, dynamic>> tools) async {
    final r = await http
        .post(Uri.parse(_url('/api/v1/sync/js_tools')), headers: _headers, body: jsonEncode({'tools': tools}))
        .timeout(const Duration(seconds: 60));
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Push SSH shell script definitions to the server.
  Future<Map<String, dynamic>> syncShellScripts(List<Map<String, dynamic>> scripts) async {
    final r = await http
        .post(Uri.parse(_url('/api/v1/sync/ssh_scripts')), headers: _headers, body: jsonEncode({'scripts': scripts}))
        .timeout(const Duration(seconds: 60));
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Fetch SSH shell script definitions from the server.
  Future<List<Map<String, dynamic>>> getShellScripts() async {
    final r = await http
        .get(Uri.parse(_url('/api/v1/sync/ssh_scripts')), headers: _headers)
        .timeout(_timeout);
    _checkStatus(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final list = body['scripts'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Fetch Python tool definitions from the server.
  Future<List<Map<String, dynamic>>> getPyTools() async {
    final r = await http
        .get(Uri.parse(_url('/api/v1/sync/py_tools')), headers: _headers)
        .timeout(_timeout);
    _checkStatus(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final list = body['tools'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Fetch JavaScript tool definitions from the server.
  Future<List<Map<String, dynamic>>> getJsTools() async {
    final r = await http
        .get(Uri.parse(_url('/api/v1/sync/js_tools')), headers: _headers)
        .timeout(_timeout);
    _checkStatus(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final list = body['tools'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  /// Fetches the current LLM settings stored on the server.
  /// Returns a map with keys: provider, model, api_key, base_url, temperature,
  /// max_tokens, is_slm, provider2, model2, api_key2, base_url2, temperature2,
  /// max_tokens2, is_slm2.
  Future<Map<String, dynamic>> getLlmSettings({Duration? timeout}) async {
    final r = await http.get(Uri.parse(_url('/api/v1/settings/llm')), headers: _headers).timeout(timeout ?? _timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Replace the current LLM settings on the server.
  Future<void> putLlmSettings(Map<String, dynamic> body) async {
    final r = await http.put(Uri.parse(_url('/api/v1/settings/llm')), headers: _headers, body: jsonEncode(body)).timeout(_timeout);
    _checkStatus(r);
  }

  /// Proxies an Ollama model list request through the server so that the client
  /// does not need direct network access to the Ollama host.
  ///
  /// [baseUrl] – Ollama base URL (e.g. http://localhost:11434).
  /// [apiKey]  – Optional Bearer token for Ollama.
  Future<List<String>> fetchOllamaModels({String? baseUrl, String? apiKey}) async {
    final queryParams = <String, String>{};
    if (baseUrl != null && baseUrl.isNotEmpty) queryParams['base_url'] = baseUrl;
    if (apiKey != null && apiKey.isNotEmpty) queryParams['api_key'] = apiKey;
    final uri = Uri.parse(_url('/api/v1/ollama/models')).replace(queryParameters: queryParams.isEmpty ? null : queryParams);
    final r = await http.get(uri, headers: _headers).timeout(_timeout);
    _checkStatus(r);
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    return (data['models'] as List<dynamic>? ?? []).map((e) => e as String).toList();
  }

  /// Starts a server-side model download job.
  Future<Map<String, dynamic>> startServerModelDownload({
    required String url,
    required String filename,
    String? displayName,
    int? sizeBytes,
  }) async {
    final payload = <String, dynamic>{'url': url, 'filename': filename};
    if (displayName != null && displayName.isNotEmpty) payload['display_name'] = displayName;
    if (sizeBytes != null && sizeBytes > 0) payload['size_bytes'] = sizeBytes;

    final r = await http.post(Uri.parse(_url('/api/v1/models/downloads')), headers: _headers, body: jsonEncode(payload)).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Returns the current status/progress of a server-side model download job.
  Future<Map<String, dynamic>> getServerModelDownloadJob(String jobId) async {
    final r = await http.get(Uri.parse(_url('/api/v1/models/downloads/$jobId')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Requests cancellation of a server-side model download job.
  Future<Map<String, dynamic>> cancelServerModelDownload(String jobId) async {
    final r = await http.post(Uri.parse(_url('/api/v1/models/downloads/$jobId/cancel')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Lists downloaded model files available on the server.
  Future<List<Map<String, dynamic>>> listServerModelFiles() async {
    final r = await http.get(Uri.parse(_url('/api/v1/models/files')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final files = body['files'] as List<dynamic>? ?? const <dynamic>[];
    return files.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// Deletes a downloaded model file from the server.
  Future<void> deleteServerModelFile(String filename) async {
    final encoded = Uri.encodeComponent(filename);
    final r = await http.delete(Uri.parse(_url('/api/v1/models/files/$encoded')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
  }

  /// Checks if the embedded LLM is loaded on the server and returns filename.
  /// Returns a map: {'loaded': bool, 'filename': String?}
  Future<Map<String, dynamic>> getServerLoadedModel() async {
    final r = await http.get(Uri.parse(_url('/api/v1/models/loaded')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Loads a GGUF model into memory on the server.
  Future<Map<String, dynamic>> loadServerModel(String filename, {int? gpuLayers}) async {
    final r = await http.post(
      Uri.parse(_url('/api/v1/models/load')),
      headers: _headers,
      body: jsonEncode({
        'filename': filename,
        'gpuLayers': ?gpuLayers,
      }),
    ).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Disposes/unloads the loaded model on the server.
  Future<Map<String, dynamic>> unloadServerModel() async {
    final r = await http.post(Uri.parse(_url('/api/v1/models/unload')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Checks if the server supports GPU acceleration and retrieves VRAM info.
  Future<Map<String, dynamic>> getServerGpuCapabilities() async {
    final r = await http.get(Uri.parse(_url('/api/v1/models/gpu')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Fetches custom GGUF models configured on the server.
  Future<List<Map<String, dynamic>>> getServerCustomModels() async {
    final r = await http.get(Uri.parse(_url('/api/v1/models/custom')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final models = data['models'] as List<dynamic>? ?? const <dynamic>[];
    return models.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// Saves custom GGUF models to the server.
  Future<void> saveServerCustomModels(List<Map<String, dynamic>> models) async {
    final r = await http.post(
      Uri.parse(_url('/api/v1/models/custom')),
      headers: _headers,
      body: jsonEncode({'models': models}),
    ).timeout(_timeout);
    _checkStatus(r);
  }

  /// Fetch all data sources settings from the server.
  /// Returns a structured map with keys: email, web_search, website_index,
  /// document_index, cloud_storage, location, ssh, slack, home_assistant, whatsapp.
  Future<Map<String, dynamic>> getDataSourcesSettings({Duration? timeout}) async {
    final r = await http.get(Uri.parse(_url('/api/v1/settings/data-sources')), headers: _headers).timeout(timeout ?? _timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Push data sources settings to the server.
  Future<void> putDataSourcesSettings(Map<String, dynamic> body) async {
    final r = await http.put(Uri.parse(_url('/api/v1/settings/data-sources')), headers: _headers, body: jsonEncode(body)).timeout(_timeout);
    _checkStatus(r);
  }

  /// Fetch external tools settings from the server.
  Future<Map<String, dynamic>> getExternalToolsSettings({Duration? timeout}) async {
    final r = await http.get(Uri.parse(_url('/api/v1/settings/external-tools')), headers: _headers).timeout(timeout ?? _timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Push external tools settings to the server.
  Future<void> putExternalToolsSettings(Map<String, dynamic> body) async {
    final r = await http
        .put(Uri.parse(_url('/api/v1/settings/external-tools')), headers: _headers, body: jsonEncode(body))
        .timeout(_timeout);
    _checkStatus(r);
  }

  // ── Indexing ──────────────────────────────────────────────────

  /// Start website indexing on the server. Returns immediately (202 Accepted).
  /// [urls] is a comma-separated list of seed URLs.
  Future<Map<String, dynamic>> startWebsiteIndex({required String urls, required int maxPages}) async {
    final r = await http
        .post(Uri.parse(_url('/api/v1/index/website/start')), headers: _headers, body: jsonEncode({'urls': urls, 'max_pages': maxPages}))
        .timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Request cancellation of the running website indexer.
  Future<void> stopWebsiteIndex() async {
    final r = await http.post(Uri.parse(_url('/api/v1/index/website/stop')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
  }

  /// Poll website indexing progress.
  Future<Map<String, dynamic>> getWebsiteIndexStatus({Duration? timeout}) async {
    final r = await http.get(Uri.parse(_url('/api/v1/index/website/status')), headers: _headers).timeout(timeout ?? _timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Start document indexing on the server. Returns immediately (202 Accepted).
  /// [rootPaths] is semicolon-separated, [fileTypes] is comma-separated.
  Future<Map<String, dynamic>> startDocumentIndex({required String rootPaths, required String fileTypes}) async {
    final r = await http
        .post(
          Uri.parse(_url('/api/v1/index/document/start')),
          headers: _headers,
          body: jsonEncode({'root_paths': rootPaths, 'file_types': fileTypes}),
        )
        .timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Request cancellation of the running document indexer.
  Future<void> stopDocumentIndex() async {
    final r = await http.post(Uri.parse(_url('/api/v1/index/document/stop')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
  }

  /// Poll document indexing progress.
  Future<Map<String, dynamic>> getDocumentIndexStatus() async {
    final r = await http.get(Uri.parse(_url('/api/v1/index/document/status')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Search the server's website index with hybrid semantic + keyword ranking.
  Future<Map<String, dynamic>> searchWebsiteIndex({
    required String query,
    String? domain,
    int limit = 20,
    String searchMode = 'hybrid',
  }) async {
    final r = await http
        .post(
          Uri.parse(_url('/api/v1/index/website/search')),
          headers: _headers,
          body: jsonEncode({
            'query': query,
            if (domain != null && domain.isNotEmpty) 'domain': domain,
            'limit': limit,
            'search_mode': searchMode,
          }),
        )
        .timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// List pages in the server's website index.
  Future<Map<String, dynamic>> listWebsiteIndexPages({String? domain, int limit = 50}) async {
    final params = <String, String>{'limit': '$limit'};
    if (domain != null && domain.isNotEmpty) params['domain'] = domain;
    final uri = Uri.parse(_url('/api/v1/index/website/pages')).replace(queryParameters: params);
    final r = await http.get(uri, headers: _headers).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Get full stored content for a single indexed URL from the server.
  Future<Map<String, dynamic>> getWebsiteIndexPage(String url) async {
    final uri = Uri.parse(_url('/api/v1/index/website/page')).replace(queryParameters: {'url': url});
    final r = await http.get(uri, headers: _headers).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Purge stale website rows not belonging to currently configured website seeds.
  Future<Map<String, dynamic>> purgeStaleWebsiteIndex() async {
    final r = await http.post(Uri.parse(_url('/api/v1/index/website/purge-stale')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // ── Document index search ──────────────────────────────────────

  /// Search the server's document index with hybrid semantic + keyword ranking.
  Future<Map<String, dynamic>> searchDocumentIndex({
    required String query,
    String? fileType,
    int limit = 20,
    String searchMode = 'hybrid',
  }) async {
    final r = await http
        .post(
          Uri.parse(_url('/api/v1/index/document/search')),
          headers: _headers,
          body: jsonEncode({
            'query': query,
            if (fileType != null && fileType.isNotEmpty) 'file_type': fileType,
            'limit': limit,
            'search_mode': searchMode,
          }),
        )
        .timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// List documents in the server's document index.
  Future<Map<String, dynamic>> listDocumentIndexEntries({String? fileType, int limit = 100}) async {
    final params = <String, String>{'limit': '$limit'};
    if (fileType != null && fileType.isNotEmpty) params['file_type'] = fileType;
    final uri = Uri.parse(_url('/api/v1/index/document/list')).replace(queryParameters: params);
    final r = await http.get(uri, headers: _headers).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Get full stored content for a single indexed document from the server.
  Future<Map<String, dynamic>> getDocumentIndexEntry(String filePath) async {
    final uri = Uri.parse(_url('/api/v1/index/document/entry')).replace(queryParameters: {'file_path': filePath});
    final r = await http.get(uri, headers: _headers).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Purge stale document rows not belonging to currently configured document roots.
  Future<Map<String, dynamic>> purgeStaleDocumentIndex() async {
    final r = await http.post(Uri.parse(_url('/api/v1/index/document/purge-stale')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // ── MCP Registry (install / manage) ──────────────────────────

  /// Returns all GitHub MCP server definitions stored on the server.
  Future<List<Map<String, dynamic>>> listRegistryServers() async {
    final r = await http.get(Uri.parse(_url('/api/v1/mcp/registry')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return (body['servers'] as List? ?? []).cast<Map<String, dynamic>>();
  }

  /// Send a server definition to the server for installation via uvx / npm / pip.
  /// Returns `{'success': bool, 'logs': [...], 'server': {...}, 'error': '...'}`.
  Future<Map<String, dynamic>> installRegistryServer(Map<String, dynamic> serverJson) async {
    final r = await http
        .post(Uri.parse(_url('/api/v1/mcp/registry')), headers: _headers, body: jsonEncode(serverJson))
        .timeout(const Duration(minutes: 6));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Update env vars and/or active state for an installed server on the server.
  Future<Map<String, dynamic>> updateRegistryServer(String id, {Map<String, String>? envVars, bool? isActive}) async {
    final payload = <String, dynamic>{};
    if (envVars != null) payload['env_vars'] = envVars;
    if (isActive != null) payload['is_active'] = isActive;
    final r = await http.put(Uri.parse(_url('/api/v1/mcp/registry/$id')), headers: _headers, body: jsonEncode(payload)).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Uninstall and remove an MCP server from the server.
  Future<void> removeRegistryServer(String id) async {
    final r = await http.delete(Uri.parse(_url('/api/v1/mcp/registry/$id')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
  }

  /// Launch the server, run MCP handshake, and return discovered tools.
  /// Returns `{'success': bool, 'tools': [...], 'error': '...'}`.
  Future<Map<String, dynamic>> testRegistryServer(String id) async {
    final r = await http.post(Uri.parse(_url('/api/v1/mcp/registry/$id/test')), headers: _headers).timeout(const Duration(seconds: 60));
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // ── MCP Proxy Runtime (for remote interactive sessions) ───────────────

  /// Starts an MCP proxy session for a server (GitHub MCP, external MCP, or
  /// supported internal MCP) on the TealKit server.
  Future<Map<String, dynamic>> startMcpServer(String serverId, {Map<String, dynamic>? initParams}) async {
    final encoded = Uri.encodeComponent(serverId);
    final r = await http
        .post(
          Uri.parse(_url('/api/v1/mcp/servers/$encoded/start')),
          headers: _headers,
          body: jsonEncode({if (initParams != null && initParams.isNotEmpty) 'initParams': initParams}),
        )
        .timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Stops a previously started MCP proxy server.
  Future<void> stopMcpServer(String serverId) async {
    final encoded = Uri.encodeComponent(serverId);
    final r = await http.post(Uri.parse(_url('/api/v1/mcp/servers/$encoded/stop')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
  }

  /// Returns the currently available tools for a running MCP proxy server.
  Future<List<Map<String, dynamic>>> getMcpServerTools(String serverId) async {
    final encoded = Uri.encodeComponent(serverId);
    final r = await http.get(Uri.parse(_url('/api/v1/mcp/servers/$encoded/tools')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return (body['tools'] as List? ?? []).whereType<Map<String, dynamic>>().toList();
  }

  /// Calls a tool on a running MCP proxy server.
  Future<Map<String, dynamic>> callMcpServerTool(String serverId, String toolName, Map<String, dynamic> arguments) async {
    final encoded = Uri.encodeComponent(serverId);
    final encodedTool = Uri.encodeComponent(toolName);
    final r = await http
        .post(
          Uri.parse(_url('/api/v1/mcp/servers/$encoded/tools/$encodedTool/call')),
          headers: _headers,
          body: jsonEncode({'arguments': arguments}),
        )
        .timeout(const Duration(seconds: 90));
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // ── Skills ────────────────────────────────────────────────────

  /// Fetch all tool skills stored on the server.
  Future<List<Map<String, dynamic>>> getAllSkills({String? mcpType}) async {
    final params = mcpType != null ? '?mcp_type=${Uri.encodeComponent(mcpType)}' : '';
    final r = await http.get(Uri.parse(_url('/api/v1/skills$params')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return (body['skills'] as List? ?? []).whereType<Map<String, dynamic>>().toList();
  }

  /// Upsert a single tool skill on the server.
  Future<void> saveSkill(Map<String, dynamic> skillJson) async {
    final r = await http.put(Uri.parse(_url('/api/v1/skills')), headers: _headers, body: jsonEncode(skillJson)).timeout(_timeout);
    _checkStatus(r);
  }

  /// Delete a skill by ID on the server.
  Future<void> deleteSkill(String id) async {
    final r = await http.delete(Uri.parse(_url('/api/v1/skills/${Uri.encodeComponent(id)}')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
  }

  /// Delete all skills for a given tool name on the server.
  Future<void> deleteSkillByToolName(String toolName) async {
    final r = await http
        .delete(Uri.parse(_url('/api/v1/skills/tool/${Uri.encodeComponent(toolName)}')), headers: _headers)
        .timeout(_timeout);
    _checkStatus(r);
  }

  /// Trigger a server-side skill build pass.
  /// [addMissingOnly] — if true, only add skills for tools that have none yet.
  /// [toolName] + [mcpType] — optional, to regenerate a single tool.
  /// Returns immediately; poll [getServerSkillsBuildStatus] for progress.
  Future<Map<String, dynamic>> buildServerSkills({
    bool addMissingOnly = true,
    String? toolName,
    String? mcpType,
    bool clearBeforeBuild = false,
    bool clearCustom = false,
  }) async {
    final body = <String, dynamic>{
      'add_missing_only': addMissingOnly,
      'clear_before_build': clearBeforeBuild,
      'clear_custom': clearCustom,
    };
    if (toolName != null) body['tool_name'] = toolName;
    if (mcpType != null) body['mcp_type'] = mcpType;
    final r = await http.post(Uri.parse(_url('/api/v1/skills/build')), headers: _headers, body: jsonEncode(body)).timeout(_timeout);
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  /// Poll the current server-side skill build progress.
  /// Returns a map with keys: running (bool), processed (int), total (int), current_tool (String).
  Future<Map<String, dynamic>> getServerSkillsBuildStatus({Duration? timeout}) async {
    final r = await http
        .get(Uri.parse(_url('/api/v1/skills/build/status')), headers: _headers)
        .timeout(timeout ?? const Duration(seconds: 10));
    _checkStatus(r);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // ── Playground Sessions ───────────────────────────────────────

  Future<List<Map<String, dynamic>>> getPlaygroundSessions() async {
    final r = await http.get(Uri.parse(_url('/api/v1/playground/sessions')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    final list = body['sessions'] as List? ?? [];
    return list.whereType<Map<String, dynamic>>().toList();
  }

  Future<void> savePlaygroundSession(Map<String, dynamic> sessionJson) async {
    final r = await http.post(
      Uri.parse(_url('/api/v1/playground/sessions')),
      headers: _headers,
      body: jsonEncode(sessionJson),
    ).timeout(_timeout);
    _checkStatus(r);
  }

  Future<void> deletePlaygroundSession(String id) async {
    final r = await http.delete(Uri.parse(_url('/api/v1/playground/sessions/$id')), headers: _headers).timeout(_timeout);
    _checkStatus(r);
  }
}
