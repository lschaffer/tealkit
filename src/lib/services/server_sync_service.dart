import '../database/task_database_service_duckdb.dart';
import '../services/app_logger.dart';
import '../database/duckdb_service.dart';
import '../services/js_tool_library_service.dart';
import '../services/llm_settings_service.dart';
import '../services/shell_script_service.dart';
import '../services/server_api_client.dart';

/// Pushes the current local state (tasks + settings) to the remote server.
///
/// Call [syncAll] right after a successful [ServerModeNotifier.connect()].
/// Safe to call multiple times — the server performs upserts.
class ServerSyncService {
  ServerSyncService._();

  /// Sync state after connecting to a remote server.
  ///
  /// Intentionally does not push local state to the server.
  ///
  /// This prevents accidental overwrites after local vault restores.
  /// Remote sync is performed explicitly by import/restore flows while
  /// connected in server mode.
  static Future<String> syncOnConnect(ServerApiClient client) async {
    log.info('[ServerSync] syncOnConnect: automatic local->remote sync disabled.');
    return '0 tasks synced';
  }

  /// Push all local tasks and settings to [client].
  ///
  /// Returns a brief summary string, e.g. `"3 tasks synced"`.
  /// Throws [ApiException] or [Exception] on failure.
  static Future<String> syncAll(ServerApiClient client) async {
    final tasksResult = await _syncTasks(client);
    await _syncSettings(client);
    await _syncShellScripts(client);
    await _syncPyTools(client);
    await _syncJsTools(client);
    return tasksResult;
  }

  // ── Tasks ─────────────────────────────────────────────────────

  static Future<String> _syncTasks(ServerApiClient client) async {
    final db = TaskDatabaseService();
    final exportedTasks = await db.exportTasks(stripSecrets: false);
    if (exportedTasks.isEmpty) {
      log.info('[ServerSync] No local tasks to sync.');
      return '0 tasks synced';
    }

    log.info('[ServerSync] Syncing ${exportedTasks.length} tasks…');
    final result = await client.syncTasks(exportedTasks);
    final inserted = result['inserted'] as int? ?? 0;
    final updated = result['updated'] as int? ?? 0;
    final errors = (result['errors'] as List?)?.cast<String>() ?? <String>[];

    if (errors.isNotEmpty) {
      log.warning('[ServerSync] Task sync errors: ${errors.join(', ')}');
    }
    log.info('[ServerSync] Tasks synced — inserted=$inserted updated=$updated errors=${errors.length}');
    return '${inserted + updated} tasks synced';
  }

  // ── Settings ──────────────────────────────────────────────────

  static Future<void> _syncSettings(ServerApiClient client) async {
    final payload = _buildSettingsPayload();
    if (payload.isEmpty) return;
    log.info('[ServerSync] Syncing settings sections: ${payload.keys.join(', ')}');
    await client.syncSettings(payload);
    log.info('[ServerSync] Settings synced.');
  }

  static Future<void> _syncPyTools(ServerApiClient client) async {
    final rows = await DuckDbService().getAllPyTools();
    if (rows.isEmpty) {
      log.info('[ServerSync] No Python tools to sync.');
      return;
    }
    log.info('[ServerSync] Syncing ${rows.length} Python tools...');
    final result = await client.syncPyTools(rows);
    log.info('[ServerSync] Python tools synced — inserted=${result['inserted'] ?? 0} updated=${result['updated'] ?? 0}');
  }

  static Future<void> _syncShellScripts(ServerApiClient client) async {
    await ScriptLibraryService.instance.load();
    final rows = ScriptLibraryService.instance.exportToJson();
    if (rows.isEmpty) {
      log.info('[ServerSync] No SSH scripts to sync.');
      return;
    }
    log.info('[ServerSync] Syncing ${rows.length} SSH scripts...');
    final result = await client.syncShellScripts(rows);
    log.info('[ServerSync] SSH scripts synced — inserted=${result['inserted'] ?? 0} updated=${result['updated'] ?? 0}');
  }

  static Future<void> _syncJsTools(ServerApiClient client) async {
    await JsToolLibraryService.instance.load();
    final rows = JsToolLibraryService.instance.exportToJson();
    if (rows.isEmpty) {
      log.info('[ServerSync] No JavaScript tools to sync.');
      return;
    }
    log.info('[ServerSync] Syncing ${rows.length} JavaScript tools...');
    final result = await client.syncJsTools(rows.cast<Map<String, dynamic>>());
    log.info('[ServerSync] JavaScript tools synced — inserted=${result['inserted'] ?? 0} updated=${result['updated'] ?? 0}');
  }

  static Map<String, dynamic> _buildSettingsPayload() {
    final llm = LlmSettingsService.instance;

    final llmPayload = <String, dynamic>{};
    if (llm.provider != LlmProvider.none) llmPayload['provider'] = llm.provider.configKey;
    if (llm.model.isNotEmpty) llmPayload['model'] = llm.model;
    if (llm.apiKey.isNotEmpty) llmPayload['api_key'] = llm.apiKey;
    if (llm.baseUrl.isNotEmpty) llmPayload['base_url'] = llm.baseUrl;
    llmPayload['temperature'] = llm.temperature;
    llmPayload['max_tokens'] = llm.maxTokens;
    llmPayload['is_slm'] = llm.isSlm;

    if (llm.provider2 != LlmProvider.none) llmPayload['provider2'] = llm.provider2.configKey;
    if (llm.model2.isNotEmpty) llmPayload['model2'] = llm.model2;
    if (llm.apiKey2.isNotEmpty) llmPayload['api_key2'] = llm.apiKey2;
    if (llm.baseUrl2.isNotEmpty) llmPayload['base_url2'] = llm.baseUrl2;

    return {'llm': llmPayload};
  }
}
