import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/app_logger.dart';
import '../../services/data_sources_settings_service.dart';
import '../internal_mcp_server.dart';

/// Internal MCP server for Home Assistant (local REST API).
///
/// Connects to a local (or Nabu Casa cloud) Home Assistant instance via its
/// long-lived access token and exposes device control, state reading and
/// automation triggering as MCP tools.
///
/// Init parameters:
///   • haBaseUrl   – Base URL of the HA instance, e.g. "http://homeassistant.local:8123"
///   • haToken     – Long-lived access token from HA profile settings
class HomeAssistantMcpServer extends InternalMcpServer {
  String _baseUrl = '';
  String _token = '';

  // Cached entity list so we don't re-fetch on every call.
  List<Map<String, dynamic>> _entityCache = [];
  DateTime? _entityCacheTime;
  static const _cacheTtl = Duration(minutes: 5);

  @override
  String get type => 'home_assistant';

  @override
  String get displayName => 'Home Assistant';

  @override
  String get description =>
      'Control smart home devices via a local Home Assistant instance. '
      'Read states, switch devices, adjust lights, thermostats, covers and '
      'trigger automations — all via the HA REST API.';

  @override
  String get iconName => 'home';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'haBaseUrl': {
        'type': 'string',
        'description':
            'Base URL of your Home Assistant instance, e.g. "http://homeassistant.local:8123" '
            'or "https://xxxx.ui.nabu.casa".',
      },
      'haToken': {
        'type': 'string',
        'description': 'Long-lived access token. Create one in HA → Profile → Long-Lived Access Tokens.',
        'sensitive': true,
      },
    },
    'required': ['haBaseUrl', 'haToken'],
  };

  @override
  Map<String, dynamic> get defaultInitParams => {'haBaseUrl': '', 'haToken': ''};

  @override
  String get defaultSystemPrompt =>
      'Home Assistant tools allow you to control smart home devices, read sensor '
      'states and trigger automations.\n'
      'USAGE RULES:\n'
      '1. Always call list_ha_entities first if you do not know the entity_id of '
      '   a device. Filter by domain (light, switch, climate, cover, etc.).\n'
      '2. To turn something on/off use control_ha_entity with service "turn_on" or '
      '   "turn_off". For lights you can also pass brightness (0–255) or '
      '   color_temp via serviceData.\n'
      '3. For CLIMATE / THERMOSTAT entities use these domain-specific services:\n'
      '   - set_hvac_mode: serviceData {hvac_mode: "heat"|"cool"|"heat_cool"|"auto"|"off"}\n'
      '   - set_temperature CRITICAL RULES:\n'
      '     • ALWAYS call get_ha_entity_state first to read the current HVAC mode.\n'
      '     • If current state is "heat_cool": you MUST use '
      '       {target_temp_high: <n>, target_temp_low: <n>}. '
      '       Using {temperature: <n>} alone in heat_cool mode will ALWAYS fail with HTTP 500.\n'
      '     • If current state is "heat" or "cool": use {temperature: <n>}.\n'
      '   - set_fan_mode: serviceData {fan_mode: "on"|"auto"}\n'
      '   - set_preset_mode: serviceData {preset_mode: "away"|"home"|"sleep"|"eco"}\n'
      '4. To read a single state use get_ha_entity_state.\n'
      '5. To trigger an automation use trigger_ha_automation.\n'
      '6. Always confirm the action you took and the new state to the user.\n'
      '7. Never expose the access token in your responses.\n'
      '8. NOTE: The HA demo instance (demo.home-assistant.io or local demo) has '
      '   virtual entities that may reject some service calls with HTTP 500 — '
      '   this is a demo limitation, not a configuration error.';

  @override
  String? validateInitParams(Map<String, dynamic> params) {
    final url = (params['haBaseUrl'] as String? ?? '').trim();
    final token = (params['haToken'] as String? ?? '').trim();
    // Empty params are OK if the global settings are configured.
    if (url.isEmpty && token.isEmpty) return null;
    if (url.isEmpty) return 'haBaseUrl is required (e.g. http://homeassistant.local:8123).';
    if (token.isEmpty) return 'haToken is required.';
    // Basic URL sanity check
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return 'haBaseUrl must be a valid URL with http:// or https://.';
    return null;
  }

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    _baseUrl = (initParams['haBaseUrl'] as String? ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    _token = (initParams['haToken'] as String? ?? '').trim();

    // Fall back to global data-source settings if task-level params are empty.
    if (_baseUrl.isEmpty || _token.isEmpty) {
      final svc = DataSourcesSettingsService.instance;
      if (!svc.isLoaded) await svc.load();
      if (_baseUrl.isEmpty) _baseUrl = svc.haBaseUrl.replaceAll(RegExp(r'/+$'), '');
      if (_token.isEmpty) _token = svc.haToken;
    }

    _entityCache = [];
    _entityCacheTime = null;
    log.info('[HA MCP] Initialized with baseUrl=$_baseUrl, hasToken=${_token.isNotEmpty}');
  }

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'list_ha_entities',
      description:
          'List Home Assistant entities. Optionally filter by domain (light, switch, sensor, '
          'climate, cover, automation, script, media_player, fan, lock, alarm_control_panel).',
      inputSchema: {
        'type': 'object',
        'properties': {
          'domain': {'type': 'string', 'description': 'Optional domain filter, e.g. "light" or "switch".'},
          'area': {'type': 'string', 'description': 'Optional area/room name filter (case-insensitive).'},
          'search': {'type': 'string', 'description': 'Optional free-text search in entity id or friendly name.'},
          'limit': {'type': 'integer', 'default': 50, 'description': 'Max number of results (default 50).'},
        },
        'required': [],
      },
    ),
    const McpToolDescriptor(
      name: 'get_ha_entity_state',
      description: 'Get the current state and attributes of a single Home Assistant entity.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'entity_id': {'type': 'string', 'description': 'Full entity id, e.g. "light.living_room".'},
        },
        'required': ['entity_id'],
      },
    ),
    const McpToolDescriptor(
      name: 'control_ha_entity',
      description:
          'Call a Home Assistant service to control a device. '
          'Common services: turn_on, turn_off, toggle. '
          'For lights: pass brightness (0-255) or rgb_color in serviceData. '
          'For climate/thermostats: use set_hvac_mode (serviceData: {hvac_mode: "heat"|"cool"|"heat_cool"|"off"}). '
          'For set_temperature: FIRST check entity state — if mode is "heat_cool" use '
          '{target_temp_high: <n>, target_temp_low: <n>}; if mode is "heat" or "cool" use {temperature: <n>}. '
          'Using {temperature} in heat_cool mode causes HTTP 500. '
          'set_preset_mode (serviceData: {preset_mode: "away"|"home"|"sleep"}). '
          'The service domain is derived automatically from entity_id.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'entity_id': {'type': 'string', 'description': 'Entity id, e.g. "light.bedroom".'},
          'service': {'type': 'string', 'description': 'Service name without domain, e.g. "turn_on", "turn_off", "toggle".'},
          'serviceData': {
            'type': 'object',
            'description':
                'Optional extra service data, e.g. {"brightness": 200} or '
                '{"temperature": 21} for climate.',
          },
        },
        'required': ['entity_id', 'service'],
      },
    ),
    const McpToolDescriptor(
      name: 'trigger_ha_automation',
      description: 'Trigger a Home Assistant automation by entity_id.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'entity_id': {'type': 'string', 'description': 'Automation entity id, e.g. "automation.morning_routine".'},
        },
        'required': ['entity_id'],
      },
    ),
    const McpToolDescriptor(
      name: 'get_ha_history',
      description: 'Get state history for an entity over the past N hours.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'entity_id': {'type': 'string'},
          'hours': {'type': 'integer', 'default': 6, 'description': 'How many hours of history to retrieve (default 6, max 72).'},
        },
        'required': ['entity_id'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    if (_baseUrl.isEmpty || _token.isEmpty) {
      return {'error': 'Home Assistant not configured. Please set haBaseUrl and haToken.'};
    }

    switch (toolName) {
      case 'list_ha_entities':
        return _listEntities(arguments);
      case 'get_ha_entity_state':
        return _getEntityState(arguments);
      case 'control_ha_entity':
        return _controlEntity(arguments);
      case 'trigger_ha_automation':
        return _triggerAutomation(arguments);
      case 'get_ha_history':
        return _getHistory(arguments);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  // ─── HTTP helpers ─────────────────────────────────────────────────────────

  Map<String, String> get _headers => {'Authorization': 'Bearer $_token', 'Content-Type': 'application/json'};

  Future<http.Response> _get(String path) => http.get(Uri.parse('$_baseUrl$path'), headers: _headers).timeout(const Duration(seconds: 15));

  Future<http.Response> _post(String path, Map<String, dynamic> body) =>
      http.post(Uri.parse('$_baseUrl$path'), headers: _headers, body: jsonEncode(body)).timeout(const Duration(seconds: 15));

  Map<String, dynamic> _handleError(http.Response res, String context) {
    log.warning('[HA MCP] $context → HTTP ${res.statusCode}: ${res.body.length > 200 ? res.body.substring(0, 200) : res.body}');
    return {
      'error': 'HA API error ($context): HTTP ${res.statusCode}',
      'detail': res.body.length > 400 ? '${res.body.substring(0, 400)}…' : res.body,
    };
  }

  // ─── Entity list ──────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> _fetchAllEntities() async {
    final now = DateTime.now();
    if (_entityCacheTime != null && now.difference(_entityCacheTime!) < _cacheTtl && _entityCache.isNotEmpty) {
      return _entityCache;
    }

    final res = await _get('/api/states');
    if (res.statusCode != 200) throw Exception('HA /api/states → HTTP ${res.statusCode}');
    final raw = jsonDecode(res.body) as List;
    _entityCache = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    _entityCacheTime = now;
    return _entityCache;
  }

  Future<Map<String, dynamic>> _listEntities(Map<String, dynamic> args) async {
    try {
      final domainFilter = (args['domain'] as String?)?.trim().toLowerCase();
      final areaFilter = (args['area'] as String?)?.trim().toLowerCase();
      final searchFilter = (args['search'] as String?)?.trim().toLowerCase();
      final limit = ((args['limit'] as int?) ?? 50).clamp(1, 500);

      final all = await _fetchAllEntities();

      var filtered = all
          .where((e) {
            final entityId = (e['entity_id'] as String? ?? '').toLowerCase();
            final friendlyName = ((e['attributes'] as Map?)?['friendly_name'] as String? ?? '').toLowerCase();
            final area = ((e['attributes'] as Map?)?['area'] as String? ?? '').toLowerCase();

            if (domainFilter != null && !entityId.startsWith('$domainFilter.')) return false;
            if (areaFilter != null && !area.contains(areaFilter) && !friendlyName.contains(areaFilter)) return false;
            if (searchFilter != null && !entityId.contains(searchFilter) && !friendlyName.contains(searchFilter)) return false;
            return true;
          })
          .take(limit)
          .toList();

      return {
        'count': filtered.length,
        'entities': filtered.map((e) {
          final attrs = (e['attributes'] as Map?) ?? {};
          return {
            'entity_id': e['entity_id'],
            'state': e['state'],
            'friendly_name': attrs['friendly_name'],
            'domain': (e['entity_id'] as String).split('.').first,
          };
        }).toList(),
      };
    } catch (e) {
      log.warning('[HA MCP] list_ha_entities failed: $e');
      return {'error': e.toString()};
    }
  }

  // ─── Single state ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _getEntityState(Map<String, dynamic> args) async {
    final entityId = (args['entity_id'] as String?)?.trim();
    if (entityId == null || entityId.isEmpty) return {'error': 'entity_id is required.'};

    try {
      final res = await _get('/api/states/$entityId');
      if (res.statusCode != 200) return _handleError(res, 'get_state($entityId)');
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      return {
        'entity_id': data['entity_id'],
        'state': data['state'],
        'attributes': data['attributes'],
        'last_changed': data['last_changed'],
        'last_updated': data['last_updated'],
      };
    } catch (e) {
      log.warning('[HA MCP] get_ha_entity_state failed: $e');
      return {'error': e.toString()};
    }
  }

  // ─── Service call ─────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _controlEntity(Map<String, dynamic> args) async {
    final entityId = (args['entity_id'] as String?)?.trim();
    final service = (args['service'] as String?)?.trim();
    if (entityId == null || entityId.isEmpty) return {'error': 'entity_id is required.'};
    if (service == null || service.isEmpty) return {'error': 'service is required.'};

    // Derive domain from entity_id (e.g. "light.bedroom" → domain = "light")
    final parts = entityId.split('.');
    if (parts.length < 2) return {'error': 'entity_id must be in the form "domain.name".'};
    final domain = parts.first;

    final body = <String, dynamic>{'entity_id': entityId};
    final extraData = args['serviceData'];
    if (extraData is Map) {
      body.addAll(Map<String, dynamic>.from(extraData));
    }

    try {
      // Invalidate cache so next list reflects the new state.
      _entityCacheTime = null;

      final res = await _post('/api/services/$domain/$service', body);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return _handleError(res, 'control($entityId, $service)');
      }

      // Re-fetch the entity state to confirm the change.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final stateRes = await _get('/api/states/$entityId');
      final newState = stateRes.statusCode == 200 ? (jsonDecode(stateRes.body) as Map)['state'] : 'unknown';

      log.info('[HA MCP] $entityId → $service → new state: $newState');
      return {'success': true, 'entity_id': entityId, 'service': service, 'newState': newState};
    } catch (e) {
      log.warning('[HA MCP] control_ha_entity failed: $e');
      return {'error': e.toString()};
    }
  }

  // ─── Trigger automation ───────────────────────────────────────────────────

  Future<Map<String, dynamic>> _triggerAutomation(Map<String, dynamic> args) async {
    final entityId = (args['entity_id'] as String?)?.trim();
    if (entityId == null || entityId.isEmpty) return {'error': 'entity_id is required.'};

    try {
      final res = await _post('/api/services/automation/trigger', {'entity_id': entityId});
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return _handleError(res, 'trigger_automation($entityId)');
      }
      log.info('[HA MCP] Triggered automation: $entityId');
      return {'success': true, 'entity_id': entityId};
    } catch (e) {
      log.warning('[HA MCP] trigger_ha_automation failed: $e');
      return {'error': e.toString()};
    }
  }

  // ─── History ──────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _getHistory(Map<String, dynamic> args) async {
    final entityId = (args['entity_id'] as String?)?.trim();
    if (entityId == null || entityId.isEmpty) return {'error': 'entity_id is required.'};
    final hours = ((args['hours'] as int?) ?? 6).clamp(1, 72);

    final since = DateTime.now().toUtc().subtract(Duration(hours: hours)).toIso8601String();

    try {
      final res = await _get('/api/history/period/$since?filter_entity_id=$entityId&minimal_response=true');
      if (res.statusCode != 200) return _handleError(res, 'history($entityId)');

      final raw = jsonDecode(res.body) as List;
      final entries = raw.isEmpty ? <dynamic>[] : raw.first as List;
      final trimmed = entries.map((e) => {'state': e['state'], 'last_changed': e['last_changed']}).toList();

      return {'entity_id': entityId, 'hours': hours, 'count': trimmed.length, 'history': trimmed};
    } catch (e) {
      log.warning('[HA MCP] get_ha_history failed: $e');
      return {'error': e.toString()};
    }
  }
}
