import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/github_mcp_server_definition.dart';
import 'app_logger.dart';
import 'github_mcp_library_service.dart';

/// Loads the registry of available GitHub MCP servers from the remote URL,
/// with a bundled JSON as fallback.
///
/// Merges registry entries with the locally installed servers from
/// [GithubMcpLibraryService] so that install status / env vars are
/// preserved across refreshes.
class GithubMcpRegistryService {
  GithubMcpRegistryService._();
  static final instance = GithubMcpRegistryService._();

  static const _cacheKey = 'github_mcp_registry_cache';
  static const _cacheTimestampKey = 'github_mcp_registry_cache_ts';
  static const _cacheMaxAge = Duration(hours: 24);

  // Remote URL for updates — point to your own hosted file for control
  static const _remoteUrl = 'https://raw.githubusercontent.com/mcptoolkit/registry/main/registry.json';

  // Bundled fallback asset
  static const _bundledAsset = 'assets/github_mcp_registry.json';

  List<GithubMcpServerDefinition> _catalog = [];
  bool _loaded = false;

  List<GithubMcpServerDefinition> get catalog => List.unmodifiable(_catalog);
  bool get isLoaded => _loaded;

  // ─── Load ─────────────────────────────────────────────────────────────────

  /// Load registry and merge with installed servers.
  /// Safe to call multiple times — returns cached result after first load.
  Future<void> load({bool forceRefresh = false}) async {
    final lib = GithubMcpLibraryService.instance;
    await lib.load();

    final raw = await _fetchRegistry(forceRefresh: forceRefresh);
    _catalog = _mergeWithInstalled(raw, lib.servers);
    _loaded = true;
    log.info('[GhMcpRegistry] Catalog ready: ${_catalog.length} entries');
  }

  // ─── Fetch ────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> _fetchRegistry({bool forceRefresh = false}) async {
    // Try to use cache
    if (!forceRefresh) {
      final cached = await _readCache();
      if (cached != null) return cached;
    }

    // Try remote fetch
    try {
      final response = await http.get(Uri.parse(_remoteUrl)).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final parsed = _parseRegistryJson(response.body);
        if (parsed.isNotEmpty) {
          await _writeCache(response.body);
          log.info('[GhMcpRegistry] Fetched ${parsed.length} entries from remote');
          return parsed;
        }
      }
    } catch (e) {
      log.warning('[GhMcpRegistry] Remote fetch failed: $e — using bundled fallback');
    }

    // Fall back to bundled asset
    try {
      final raw = await rootBundle.loadString(_bundledAsset);
      final parsed = _parseRegistryJson(raw);
      log.info('[GhMcpRegistry] Loaded ${parsed.length} entries from bundled asset');
      return parsed;
    } catch (e) {
      log.error('[GhMcpRegistry] Failed to load bundled asset: $e');
      return [];
    }
  }

  List<Map<String, dynamic>> _parseRegistryJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded.containsKey('servers')) {
        final list = decoded['servers'] as List<dynamic>;
        return list.whereType<Map<String, dynamic>>().toList();
      }
      if (decoded is List) {
        return decoded.whereType<Map<String, dynamic>>().toList();
      }
    } catch (e) {
      log.warning('[GhMcpRegistry] JSON parse error: $e');
    }
    return [];
  }

  // ─── Merge ────────────────────────────────────────────────────────────────

  /// Registry entries + locally-installed overrides.
  List<GithubMcpServerDefinition> _mergeWithInstalled(
    List<Map<String, dynamic>> registryEntries,
    List<GithubMcpServerDefinition> installedServers,
  ) {
    final result = <GithubMcpServerDefinition>[];

    for (final entry in registryEntries) {
      final packageName = entry['packageName'] as String?;
      if (packageName == null) continue;

      final installed = installedServers.where((s) => s.packageName == packageName).firstOrNull;
      if (installed != null) {
        // Preserve user env vars, install status, active from local DB
        result.add(
          installed.copyWith(
            displayName: entry['displayName'] as String? ?? installed.displayName,
            description: entry['description'] as String? ?? installed.description,
          ),
        );
      } else {
        result.add(GithubMcpServerDefinition.fromRegistryEntry(entry));
      }
    }

    // Add any locally installed servers not in the registry (custom installs)
    for (final s in installedServers) {
      if (!result.any((r) => r.packageName == s.packageName)) {
        result.add(s);
      }
    }

    return result;
  }

  // ─── Cache ────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>?> _readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ts = prefs.getInt(_cacheTimestampKey);
      if (ts == null) return null;

      final age = DateTime.now().millisecondsSinceEpoch - ts;
      if (age > _cacheMaxAge.inMilliseconds) return null;

      final raw = prefs.getString(_cacheKey);
      if (raw == null) return null;

      return _parseRegistryJson(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(String raw) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, raw);
      await prefs.setInt(_cacheTimestampKey, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  List<GithubMcpServerDefinition> filterByCategory(String category) =>
      category == 'all' ? _catalog : _catalog.where((s) => s.category == category).toList();

  List<String> get categories {
    final cats = _catalog.map((s) => s.category).toSet().toList()..sort();
    return ['all', ...cats];
  }
}
