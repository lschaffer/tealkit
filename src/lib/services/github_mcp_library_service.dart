import '../database/duckdb_service.dart';
import '../models/github_mcp_server_definition.dart';
import 'app_logger.dart';

/// CRUD service for GitHub MCP server definitions.
///
/// Persists metadata in DuckDB (github_mcp_servers table).
/// Does NOT manage installation or processes — see [GithubMcpRuntimeService].
class GithubMcpLibraryService {
  GithubMcpLibraryService._();
  static final instance = GithubMcpLibraryService._();

  List<GithubMcpServerDefinition> _servers = [];

  List<GithubMcpServerDefinition> get servers => List.unmodifiable(_servers);
  List<GithubMcpServerDefinition> get installedServers => _servers.where((s) => s.isInstalled).toList();
  List<GithubMcpServerDefinition> get activeServers => _servers.where((s) => s.isInstalled && s.isActive).toList();

  // ─── Load ─────────────────────────────────────────────────────────────────

  Future<void> load() async {
    try {
      final db = DuckDbService();
      final rows = await db.getAllGithubMcpServers();
      _servers = rows.map(GithubMcpServerDefinition.fromJson).toList();
      log.info('[GhMcpLibrary] Loaded ${_servers.length} servers');
    } catch (e) {
      log.error('[GhMcpLibrary] Failed to load: $e');
    }
  }

  // ─── Save (create / update) ───────────────────────────────────────────────

  Future<GithubMcpServerDefinition> save(GithubMcpServerDefinition def) async {
    final db = DuckDbService();
    await db.saveGithubMcpServer(def.toJson());

    final idx = _servers.indexWhere((s) => s.id == def.id);
    if (idx >= 0) {
      _servers[idx] = def;
    } else {
      _servers.add(def);
    }
    log.info('[GhMcpLibrary] Saved server: ${def.id} "${def.displayName}"');
    return def;
  }

  // ─── Delete ───────────────────────────────────────────────────────────────

  Future<void> delete(String id) async {
    final db = DuckDbService();
    await db.deleteGithubMcpServer(id);
    _servers.removeWhere((s) => s.id == id);
    log.info('[GhMcpLibrary] Deleted server: $id');
  }

  // ─── Mark installed ───────────────────────────────────────────────────────

  Future<GithubMcpServerDefinition> markInstalled(String id, {required Map<String, String> envVars, bool activate = true}) async {
    final idx = _servers.indexWhere((s) => s.id == id);
    if (idx < 0) throw StateError('Server $id not found in library');

    final updated = _servers[idx].copyWith(isInstalled: true, isActive: activate, envVars: envVars, installedAt: DateTime.now());
    return save(updated);
  }

  Future<GithubMcpServerDefinition> setActive(String id, {required bool active}) async {
    final idx = _servers.indexWhere((s) => s.id == id);
    if (idx < 0) throw StateError('Server $id not found in library');
    final updated = _servers[idx].copyWith(isActive: active);
    return save(updated);
  }

  Future<GithubMcpServerDefinition> updateEnvVars(String id, Map<String, String> envVars) async {
    final idx = _servers.indexWhere((s) => s.id == id);
    if (idx < 0) throw StateError('Server $id not found in library');
    final updated = _servers[idx].copyWith(envVars: envVars);
    return save(updated);
  }

  GithubMcpServerDefinition? findById(String id) => _servers.where((s) => s.id == id).firstOrNull;

  /// Returns true if a server with this packageName already exists in library.
  bool isKnown(String packageName) => _servers.any((s) => s.packageName == packageName);

  /// Returns the library entry for a given packageName, or null.
  GithubMcpServerDefinition? findByPackage(String packageName) => _servers.where((s) => s.packageName == packageName).firstOrNull;
}
