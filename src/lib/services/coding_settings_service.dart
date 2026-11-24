import 'package:flutter_ui_mcp_core/flutter_ui_mcp_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tealkit_api/tealkit_api.dart';

import 'app_logger.dart';
import 'session_service.dart';

/// Persistent settings for Coding Mode & Agent execution limits.
///
/// Stored locally in [SharedPreferences] and optionally synchronized with
/// TealKit Server (`GET/PUT /api/v1/coding/settings`) when running in Server Mode.
class CodingSettingsService extends ChangeNotifier {
  static final CodingSettingsService instance = CodingSettingsService._();
  CodingSettingsService._();

  static const _kMaxToolIterations = 'coding_pref_max_tool_iterations';
  static const _kMaxSessionTurns = 'coding_pref_max_session_turns';
  static const _kTurnLimit = 'coding_pref_turn_limit';
  static const _kMaxSessionSizeMb = 'coding_pref_max_session_size_mb';
  static const _kProgressiveMcpDiscovery =
      'coding_pref_progressive_mcp_discovery';
  static const _kEnableEpisodicMemory = 'coding_pref_enable_episodic_memory';
  static const _kEnableSubAgents = 'coding_pref_enable_sub_agents';
  static const _kAutoApproveRead = 'coding_pref_auto_approve_read';
  static const _kAutoApproveWrite = 'coding_pref_auto_approve_write';
  static const _kAutoApproveExecute = 'coding_pref_auto_approve_execute';
  static const _kAutoApproveNetwork = 'coding_pref_auto_approve_network';

  bool _loaded = false;
  bool _syncedFromServer = false;

  /// Max tool call iterations per user turn (0 = unlimited).
  int _maxToolIterations = 50;

  /// Max session conversation turns before auto-rotation.
  int _maxSessionTurns = 500;

  /// Hard turn limit per session (0 = unlimited).
  int _turnLimit = 0;

  /// Max auto-saved session file size in MB.
  int _maxSessionSizeMb = 10;

  /// On-demand progressive MCP tool discovery instead of sending all schemas.
  bool _progressiveMcpDiscovery = false;

  /// Enable episodic memory archival & retrieval.
  bool _enableEpisodicMemory = true;

  /// Enable specialized sub-agents (`delegate_task`).
  bool _enableSubAgents = true;

  /// Tool Auto-Approval (Human-in-the-Loop) flags.
  bool _autoApproveRead = true;
  bool _autoApproveWrite = false;
  bool _autoApproveExecute = false;
  bool _autoApproveNetwork = true;

  bool get isLoaded => _loaded;
  bool get isSyncedFromServer => _syncedFromServer;
  int get maxToolIterations => _maxToolIterations;
  int get maxSessionTurns => _maxSessionTurns;
  int get turnLimit => _turnLimit;
  int get maxSessionSizeMb => _maxSessionSizeMb;
  bool get progressiveMcpDiscovery => _progressiveMcpDiscovery;
  bool get enableEpisodicMemory => _enableEpisodicMemory;
  bool get enableSubAgents => _enableSubAgents;
  bool get autoApproveRead => _autoApproveRead;
  bool get autoApproveWrite => _autoApproveWrite;
  bool get autoApproveExecute => _autoApproveExecute;
  bool get autoApproveNetwork => _autoApproveNetwork;

  Map<String, dynamic> toJson() => {
        'max_tool_iterations': _maxToolIterations,
        'max_session_turns': _maxSessionTurns,
        'turn_limit': _turnLimit,
        'max_session_size_mb': _maxSessionSizeMb,
        'progressive_mcp_discovery': _progressiveMcpDiscovery,
        'enable_episodic_memory': _enableEpisodicMemory,
        'enable_sub_agents': _enableSubAgents,
        'auto_approve_read': _autoApproveRead,
        'auto_approve_write': _autoApproveWrite,
        'auto_approve_execute': _autoApproveExecute,
        'auto_approve_network': _autoApproveNetwork,
      };

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _maxToolIterations =
          (prefs.getInt(_kMaxToolIterations) ?? 50).clamp(0, 1000);
      _maxSessionTurns =
          (prefs.getInt(_kMaxSessionTurns) ?? 500).clamp(10, 10000);
      _turnLimit = (prefs.getInt(_kTurnLimit) ?? 0).clamp(0, 10000);
      _maxSessionSizeMb =
          (prefs.getInt(_kMaxSessionSizeMb) ?? 10).clamp(1, 500);
      _progressiveMcpDiscovery =
          prefs.getBool(_kProgressiveMcpDiscovery) ?? false;
      _enableEpisodicMemory = prefs.getBool(_kEnableEpisodicMemory) ?? true;
      _enableSubAgents = prefs.getBool(_kEnableSubAgents) ?? true;
      _autoApproveRead = prefs.getBool(_kAutoApproveRead) ?? true;
      _autoApproveWrite = prefs.getBool(_kAutoApproveWrite) ?? false;
      _autoApproveExecute = prefs.getBool(_kAutoApproveExecute) ?? false;
      _autoApproveNetwork = prefs.getBool(_kAutoApproveNetwork) ?? true;
      _loaded = true;
      notifyListeners();
    } catch (e) {
      log.warning('[CodingSettings] Failed to load: $e');
    }
  }

  Future<void> _persistLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kMaxToolIterations, _maxToolIterations);
      await prefs.setInt(_kMaxSessionTurns, _maxSessionTurns);
      await prefs.setInt(_kTurnLimit, _turnLimit);
      await prefs.setInt(_kMaxSessionSizeMb, _maxSessionSizeMb);
      await prefs.setBool(_kProgressiveMcpDiscovery, _progressiveMcpDiscovery);
      await prefs.setBool(_kEnableEpisodicMemory, _enableEpisodicMemory);
      await prefs.setBool(_kEnableSubAgents, _enableSubAgents);
      await prefs.setBool(_kAutoApproveRead, _autoApproveRead);
      await prefs.setBool(_kAutoApproveWrite, _autoApproveWrite);
      await prefs.setBool(_kAutoApproveExecute, _autoApproveExecute);
      await prefs.setBool(_kAutoApproveNetwork, _autoApproveNetwork);
    } catch (e) {
      log.warning('[CodingSettings] Failed to save locally: $e');
    }
  }

  Future<void> _syncSessionService() async {
    try {
      final s = SessionService.instance;
      if (s.maxSessionTurns != _maxSessionTurns ||
          s.maxSessionSizeMb != _maxSessionSizeMb) {
        await s.updateSettings(
          autoSaveEnabled: s.autoSaveEnabled,
          autoSaveDir: s.autoSaveDir,
          autoSavePattern: s.autoSavePattern,
          promptContinueLastSession: s.promptContinueLastSession,
          maxSessionSizeMb: _maxSessionSizeMb,
          maxSessionTurns: _maxSessionTurns,
        );
      }
    } catch (e) {
      log.warning('[CodingSettings] SessionService sync failed: $e');
    }
  }

  /// Updates settings locally, syncs [SessionService], and optionally pushes
  /// them to TealKit Server when [serverClient] is provided.
  Future<bool> update({
    int? maxToolIterations,
    int? maxSessionTurns,
    int? turnLimit,
    int? maxSessionSizeMb,
    bool? progressiveMcpDiscovery,
    bool? enableEpisodicMemory,
    bool? enableSubAgents,
    bool? autoApproveRead,
    bool? autoApproveWrite,
    bool? autoApproveExecute,
    bool? autoApproveNetwork,
    ServerApiClient? serverClient,
  }) async {
    if (maxToolIterations != null) {
      _maxToolIterations = maxToolIterations.clamp(0, 1000);
    }
    if (maxSessionTurns != null) {
      _maxSessionTurns = maxSessionTurns.clamp(10, 10000);
    }
    if (turnLimit != null) {
      _turnLimit = turnLimit.clamp(0, 10000);
    }
    if (maxSessionSizeMb != null) {
      _maxSessionSizeMb = maxSessionSizeMb.clamp(1, 500);
    }
    if (progressiveMcpDiscovery != null) {
      _progressiveMcpDiscovery = progressiveMcpDiscovery;
    }
    if (enableEpisodicMemory != null) {
      _enableEpisodicMemory = enableEpisodicMemory;
    }
    if (enableSubAgents != null) {
      _enableSubAgents = enableSubAgents;
    }
    if (autoApproveRead != null) _autoApproveRead = autoApproveRead;
    if (autoApproveWrite != null) _autoApproveWrite = autoApproveWrite;
    if (autoApproveExecute != null) _autoApproveExecute = autoApproveExecute;
    if (autoApproveNetwork != null) _autoApproveNetwork = autoApproveNetwork;

    _loaded = true;
    await _persistLocal();
    await _syncSessionService();

    var serverSaved = true;
    if (serverClient != null) {
      try {
        await serverClient.saveServerCodingSettings(toJson());
        _syncedFromServer = true;
      } catch (e) {
        serverSaved = false;
        log.warning('[CodingSettings] Failed to save to server: $e');
      }
    }

    notifyListeners();
    return serverSaved;
  }

  /// Pulls coding settings from TealKit Server and updates local cache.
  Future<bool> syncFromServer(ServerApiClient client) async {
    try {
      final data = await client.getServerCodingSettings();
      if (data.isNotEmpty) {
        _applyFromMap(data);
        await _persistLocal();
        await _syncSessionService();
      }
      _syncedFromServer = true;
      _loaded = true;
      notifyListeners();
      return true;
    } catch (e) {
      log.warning('[CodingSettings] Failed to sync from server: $e');
      return false;
    }
  }

  void _applyFromMap(Map<String, dynamic> data) {
    if (data['max_tool_iterations'] is num) {
      _maxToolIterations =
          (data['max_tool_iterations'] as num).toInt().clamp(0, 1000);
    }
    if (data['max_session_turns'] is num) {
      _maxSessionTurns =
          (data['max_session_turns'] as num).toInt().clamp(10, 10000);
    }
    if (data['turn_limit'] is num) {
      _turnLimit = (data['turn_limit'] as num).toInt().clamp(0, 10000);
    }
    if (data['max_session_size_mb'] is num) {
      _maxSessionSizeMb =
          (data['max_session_size_mb'] as num).toInt().clamp(1, 500);
    }
    if (data['progressive_mcp_discovery'] is bool) {
      _progressiveMcpDiscovery = data['progressive_mcp_discovery'] as bool;
    }
    if (data['enable_episodic_memory'] is bool) {
      _enableEpisodicMemory = data['enable_episodic_memory'] as bool;
    }
    if (data['enable_sub_agents'] is bool) {
      _enableSubAgents = data['enable_sub_agents'] as bool;
    }
    if (data['auto_approve_read'] is bool) {
      _autoApproveRead = data['auto_approve_read'] as bool;
    }
    if (data['auto_approve_write'] is bool) {
      _autoApproveWrite = data['auto_approve_write'] as bool;
    }
    if (data['auto_approve_execute'] is bool) {
      _autoApproveExecute = data['auto_approve_execute'] as bool;
    }
    if (data['auto_approve_network'] is bool) {
      _autoApproveNetwork = data['auto_approve_network'] as bool;
    }
  }

  /// Applies all coding settings directly onto a live [PlaygroundController].
  void applyToController(PlaygroundController controller) {
    if (controller.maxToolIterations != _maxToolIterations) {
      controller.maxToolIterations = _maxToolIterations;
    }
    if (controller.maxTurns != _maxSessionTurns) {
      controller.maxTurns = _maxSessionTurns;
    }
    if (controller.turnLimit != _turnLimit) {
      controller.turnLimit = _turnLimit;
    }
    if (controller.progressiveMcpDiscovery != _progressiveMcpDiscovery) {
      controller.progressiveMcpDiscovery = _progressiveMcpDiscovery;
    }
    if (controller.enableEpisodicMemory != _enableEpisodicMemory) {
      controller.enableEpisodicMemory = _enableEpisodicMemory;
    }
    if (controller.enableSubAgents != _enableSubAgents) {
      controller.enableSubAgents = _enableSubAgents;
    }

    final perms = controller.permissions;
    var permsChanged = false;
    if (perms.autoApproveRead != _autoApproveRead) {
      perms.autoApproveRead = _autoApproveRead;
      permsChanged = true;
    }
    if (perms.autoApproveWrite != _autoApproveWrite) {
      perms.autoApproveWrite = _autoApproveWrite;
      permsChanged = true;
    }
    if (perms.autoApproveExecute != _autoApproveExecute) {
      perms.autoApproveExecute = _autoApproveExecute;
      permsChanged = true;
    }
    if (perms.autoApproveNetwork != _autoApproveNetwork) {
      perms.autoApproveNetwork = _autoApproveNetwork;
      permsChanged = true;
    }
    if (permsChanged) {
      perms.save();
    }
  }
}
