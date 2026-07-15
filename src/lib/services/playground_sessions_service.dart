import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'app_logger.dart';
import 'server_api_client.dart';

// ════════════════════════════════════════════════════════════════════════════
// Model
// ════════════════════════════════════════════════════════════════════════════

/// A saved playground setup: tools + prompts, no chat history.
class SavedPlaygroundSession {
  const SavedPlaygroundSession({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.systemPrompt,
    required this.initialPrompt,
    required this.internalMcpTypes,
    required this.mcpInitParams,
    required this.externalServerUrls,
    this.mode = 'local',
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final String systemPrompt;
  final String initialPrompt;
  final List<String> internalMcpTypes;
  final Map<String, Map<String, dynamic>> mcpInitParams;
  final List<String> externalServerUrls;

  /// Either `'local'` (embedded/mobile LLM) or `'server'` (remote server mode).
  final String mode;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'systemPrompt': systemPrompt,
    'initialPrompt': initialPrompt,
    'internalMcpTypes': internalMcpTypes,
    'mcpInitParams': mcpInitParams,
    'externalServerUrls': externalServerUrls,
    'mode': mode,
  };

  factory SavedPlaygroundSession.fromJson(Map<String, dynamic> json) => SavedPlaygroundSession(
    id: (json['id'] as String?)?.isNotEmpty == true ? json['id'] as String : const Uuid().v4(),
    name: (json['name'] as String?) ?? '',
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
    systemPrompt: (json['systemPrompt'] as String?) ?? '',
    initialPrompt: (json['initialPrompt'] as String?) ?? '',
    internalMcpTypes: (json['internalMcpTypes'] as List?)?.cast<String>() ?? [],
    mcpInitParams: _parseMcpInitParams(json['mcpInitParams']),
    externalServerUrls: (json['externalServerUrls'] as List?)?.cast<String>() ?? [],
    mode: (json['mode'] as String?) ?? 'local',
  );

  static Map<String, Map<String, dynamic>> _parseMcpInitParams(dynamic raw) {
    if (raw is! Map) return {};
    final result = <String, Map<String, dynamic>>{};
    final mapRaw = raw as Map<Object?, Object?>;
    for (final e in mapRaw.entries) {
      if (e.value is Map) {
        result[e.key as String] = Map<String, dynamic>.from(e.value as Map);
      }
    }
    return result;
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Service
// ════════════════════════════════════════════════════════════════════════════

class PlaygroundSessionsService {
  PlaygroundSessionsService._();
  static final instance = PlaygroundSessionsService._();

  static const String _prefsKey = 'playground_saved_sessions';

  List<SavedPlaygroundSession> _sessions = [];
  bool _loaded = false;

  List<SavedPlaygroundSession> get sessions => List.unmodifiable(_sessions);

  /// Returns only sessions matching [mode] (`'local'` or `'server'`).
  List<SavedPlaygroundSession> sessionsForMode(String mode) => List.unmodifiable(_sessions.where((s) => s.mode == mode));

  Future<void> load([ServerApiClient? client]) async {
    if (client != null) {
      try {
        final list = await client.getPlaygroundSessions();
        _sessions.removeWhere((s) => s.mode == 'server');
        _sessions.addAll(list.map(SavedPlaygroundSession.fromJson));
        _loaded = true;
      } catch (e) {
        log.warning('[PlaygroundSessions] Remote load failed: $e');
      }
      return;
    }

    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        _sessions = list.whereType<Map<String, dynamic>>().map(SavedPlaygroundSession.fromJson).toList();
      }
      _loaded = true;
    } catch (e) {
      log.warning('[PlaygroundSessions] Load failed: $e');
    }
  }

  Future<void> reload([ServerApiClient? client]) async {
    _loaded = false;
    await load(client);
  }

  void _invalidateCache() => _loaded = false;

  Future<void> saveSession(SavedPlaygroundSession session, [ServerApiClient? client]) async {
    if (client != null) {
      try {
        await client.savePlaygroundSession(session.toJson());
        final idx = _sessions.indexWhere((s) => s.id == session.id);
        if (idx >= 0) {
          _sessions[idx] = session;
        } else {
          _sessions.insert(0, session);
        }
      } catch (e) {
        log.warning('[PlaygroundSessions] Remote save failed: $e');
        rethrow;
      }
      return;
    }

    await load();
    final idx = _sessions.indexWhere((s) => s.id == session.id);
    if (idx >= 0) {
      _sessions[idx] = session;
    } else {
      _sessions.insert(0, session);
    }
    await _persist();
  }

  Future<void> deleteSession(String id, [ServerApiClient? client]) async {
    if (client != null) {
      try {
        await client.deletePlaygroundSession(id);
        _sessions.removeWhere((s) => s.id == id);
      } catch (e) {
        log.warning('[PlaygroundSessions] Remote delete failed: $e');
        rethrow;
      }
      return;
    }

    await load();
    _sessions.removeWhere((s) => s.id == id);
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(_sessions.map((s) => s.toJson()).toList()));
    } catch (e) {
      log.warning('[PlaygroundSessions] Persist failed: $e');
    }
  }

  // ── Vault integration ──────────────────────────────────────────────────

  List<Map<String, dynamic>> exportToJson() {
    return _sessions.map((s) => s.toJson()).toList();
  }

  /// Imports sessions from a JSON list (e.g. from vault restore).
  /// Existing sessions with the same id are kept (not overwritten).
  Future<int> importFromJson(List<Map<String, dynamic>> jsonList) async {
    await load();
    int added = 0;
    for (final json in jsonList) {
      final session = SavedPlaygroundSession.fromJson(json);
      if (!_sessions.any((s) => s.id == session.id)) {
        _sessions.add(session);
        added++;
      }
    }
    if (added > 0) await _persist();
    _invalidateCache();
    return added;
  }
}
