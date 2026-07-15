import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/app_logger.dart';
import '../../services/data_sources_settings_service.dart';
import '../internal_mcp_server.dart';

/// Internal MCP server for Google Calendar read/write operations.
///
/// Uses Google Calendar REST API v3 with OAuth2 bearer token.
/// Reuses the same Google OAuth credentials as Gmail/Drive.
/// Requires the 'https://www.googleapis.com/auth/calendar' scope —
/// re-authorize in Data Sources settings if needed.
class GoogleCalendarMcpServer extends InternalMcpServer {
  static const String _baseUrl = 'https://www.googleapis.com/calendar/v3';

  String? _accessToken;

  @override
  String get type => 'google_calendar';

  @override
  String get displayName => 'Google Calendar';

  @override
  String get description =>
      'Read and write Google Calendar events. '
      'Supports listing calendars, searching/listing events, creating, updating and deleting events.';

  @override
  String get iconName => 'calendar_today';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'accessToken': {'type': 'string', 'description': 'OAuth2 bearer token for Google Calendar API.'},
    },
    'required': [],
  };

  @override
  Map<String, dynamic> get defaultInitParams => {'accessToken': ''};

  @override
  String get defaultSystemPrompt =>
      'Google Calendar tools: use list_calendars to see all calendars, '
      'list_events (calendarId, timeMin, timeMax, q, maxResults) to fetch events, '
      'create_event (calendarId, summary, start, end, description, location) to add events, '
      'update_event to modify, delete_event to remove. '
      'Times must be ISO 8601 with timezone offset (e.g. 2026-02-24T10:00:00+01:00). '
      'For all-day events use allDay:true and pass dates as YYYY-MM-DD.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    final token = (initParams['accessToken'] as String?)?.trim();
    if (token != null && token.isNotEmpty) _accessToken = token;

    // Auto-load token from DataSources if not supplied
    if (_accessToken == null || _accessToken!.isEmpty) {
      final ds = DataSourcesSettingsService.instance;
      if (!ds.isLoaded) await ds.load();
      // On Android the refresh token is empty (GoogleSignIn handles refresh internally)
      // — refreshGmailAccessToken() does silent sign-in in that case, so always try it
      // when the stored access token is expired or missing.
      if (ds.isGmailAccessTokenExpired || ds.gmailAccessToken.trim().isEmpty) {
        await ds.refreshGmailAccessToken();
      }
      final stored = ds.gmailAccessToken.trim();
      if (stored.isNotEmpty) _accessToken = stored;
    }

    log.info('[Calendar MCP] Initialized (token: ${_accessToken != null ? "present" : "missing"})');
  }

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'list_calendars',
      description: 'List all Google calendars accessible to the user.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'accessToken': {'type': 'string', 'description': 'Optional token override.'},
        },
      },
    ),
    const McpToolDescriptor(
      name: 'list_events',
      description:
          'List or search events on a calendar. '
          'Use timeMin/timeMax (ISO 8601 with Z suffix, e.g. 2026-02-24T21:00:00Z) to filter by date range. '
          'Use q for free-text search. The server automatically normalizes timezone and precision.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'calendarId': {'type': 'string', 'description': 'Calendar ID. Use "primary" for the main calendar.', 'default': 'primary'},
          'q': {'type': 'string', 'description': 'Free-text search query.'},
          'timeMin': {
            'type': 'string',
            'description':
                'Lower bound for event start time. ISO 8601 with Z suffix (e.g. 2026-02-24T00:00:00Z). The server normalizes missing timezone.',
          },
          'timeMax': {
            'type': 'string',
            'description':
                'Upper bound for event start time. ISO 8601 with Z suffix (e.g. 2026-02-25T00:00:00Z). The server normalizes missing timezone.',
          },
          'maxResults': {'type': 'integer', 'description': 'Max events to return (default: 25, max: 250).', 'default': 25},
          'orderBy': {
            'type': 'string',
            'enum': ['startTime', 'updated'],
            'description': 'Order results by startTime or updated. Default: startTime.',
          },
          'accessToken': {'type': 'string', 'description': 'Optional token override.'},
        },
      },
    ),
    const McpToolDescriptor(
      name: 'get_event',
      description: 'Get a single calendar event by ID.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'calendarId': {'type': 'string', 'description': 'Calendar ID.', 'default': 'primary'},
          'eventId': {'type': 'string', 'description': 'Google Calendar event ID.'},
          'accessToken': {'type': 'string', 'description': 'Optional token override.'},
        },
        'required': ['eventId'],
      },
    ),
    const McpToolDescriptor(
      name: 'create_event',
      description: 'Create a new Google Calendar event.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'calendarId': {'type': 'string', 'description': 'Calendar ID. Use "primary" for the main calendar.', 'default': 'primary'},
          'summary': {'type': 'string', 'description': 'Event title / summary.'},
          'description': {'type': 'string', 'description': 'Event description.'},
          'location': {'type': 'string', 'description': 'Event location.'},
          'start': {'type': 'string', 'description': 'Start time ISO 8601 (e.g. 2026-02-24T10:00:00+01:00). For all-day: YYYY-MM-DD.'},
          'end': {'type': 'string', 'description': 'End time ISO 8601 (e.g. 2026-02-24T11:00:00+01:00). For all-day: YYYY-MM-DD.'},
          'allDay': {'type': 'boolean', 'description': 'Set true for all-day events; start/end should then be YYYY-MM-DD.'},
          'attendees': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'List of attendee email addresses.',
          },
          'accessToken': {'type': 'string', 'description': 'Optional token override.'},
        },
        'required': ['summary', 'start', 'end'],
      },
    ),
    const McpToolDescriptor(
      name: 'update_event',
      description: 'Update (patch) an existing Google Calendar event. Only supplied fields are changed.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'calendarId': {'type': 'string', 'description': 'Calendar ID.', 'default': 'primary'},
          'eventId': {'type': 'string', 'description': 'ID of the event to update.'},
          'summary': {'type': 'string', 'description': 'New event title.'},
          'description': {'type': 'string', 'description': 'New description.'},
          'location': {'type': 'string', 'description': 'New location.'},
          'start': {'type': 'string', 'description': 'New start time ISO 8601.'},
          'end': {'type': 'string', 'description': 'New end time ISO 8601.'},
          'allDay': {'type': 'boolean', 'description': 'Set true for all-day; start/end should then be YYYY-MM-DD.'},
          'accessToken': {'type': 'string', 'description': 'Optional token override.'},
        },
        'required': ['eventId'],
      },
    ),
    const McpToolDescriptor(
      name: 'delete_event',
      description: 'Delete a Google Calendar event permanently.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'calendarId': {'type': 'string', 'description': 'Calendar ID.', 'default': 'primary'},
          'eventId': {'type': 'string', 'description': 'ID of the event to delete.'},
          'accessToken': {'type': 'string', 'description': 'Optional token override.'},
        },
        'required': ['eventId'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> args) async {
    switch (toolName) {
      case 'list_calendars':
        return _listCalendars(args);
      case 'list_events':
        return _listEvents(args);
      case 'get_event':
        return _getEvent(args);
      case 'create_event':
        return _createEvent(args);
      case 'update_event':
        return _updateEvent(args);
      case 'delete_event':
        return _deleteEvent(args);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  // ─── Tool implementations ─────────────────────────────────────────────────

  Future<Map<String, dynamic>> _listCalendars(Map<String, dynamic> args) async {
    final token = _resolveToken(args);
    if (token == null || token.isEmpty) return _noTokenError();
    final uri = Uri.parse('$_baseUrl/users/me/calendarList');
    final resp = await _apiGet(uri, token);
    if (resp['error'] != null) return resp;
    final items = ((resp['data'] as Map)['items'] as List? ?? [])
        .map(
          (c) => {
            'id': c['id'],
            'summary': c['summary'],
            'primary': c['primary'] ?? false,
            'accessRole': c['accessRole'],
            'backgroundColor': c['backgroundColor'],
          },
        )
        .toList();
    return {'calendars': items, 'count': items.length};
  }

  Future<Map<String, dynamic>> _listEvents(Map<String, dynamic> args) async {
    final token = _resolveToken(args);
    if (token == null || token.isEmpty) return _noTokenError();
    final calendarId = Uri.encodeComponent(_calId(args));
    final params = <String, String>{
      'singleEvents': 'true',
      'maxResults': '${(args['maxResults'] as int?) ?? 25}',
      'orderBy': (args['orderBy'] as String?)?.isNotEmpty == true ? args['orderBy']! : 'startTime',
    };
    if ((args['q'] as String?)?.isNotEmpty == true) params['q'] = args['q']!;
    if ((args['timeMin'] as String?)?.isNotEmpty == true) params['timeMin'] = args['timeMin']!;
    if ((args['timeMax'] as String?)?.isNotEmpty == true) params['timeMax'] = args['timeMax']!;
    final uri = Uri.parse('$_baseUrl/calendars/$calendarId/events').replace(queryParameters: params);
    final resp = await _apiGet(uri, token);
    if (resp['error'] != null) return resp;
    final items = ((resp['data'] as Map)['items'] as List? ?? []).map((e) => _summariseEvent(e as Map<String, dynamic>)).toList();
    return {'events': items, 'count': items.length};
  }

  Future<Map<String, dynamic>> _getEvent(Map<String, dynamic> args) async {
    final token = _resolveToken(args);
    if (token == null || token.isEmpty) return _noTokenError();
    final calendarId = Uri.encodeComponent(_calId(args));
    final eventId = Uri.encodeComponent(args['eventId'] as String? ?? '');
    final uri = Uri.parse('$_baseUrl/calendars/$calendarId/events/$eventId');
    final resp = await _apiGet(uri, token);
    if (resp['error'] != null) return resp;
    return _summariseEvent(resp['data'] as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> _createEvent(Map<String, dynamic> args) async {
    final token = _resolveToken(args);
    if (token == null || token.isEmpty) return _noTokenError();
    final calendarId = Uri.encodeComponent(_calId(args));
    final allDay = args['allDay'] == true;
    final body = <String, dynamic>{
      'summary': args['summary'] ?? '',
      if ((args['description'] as String?)?.isNotEmpty == true) 'description': args['description'],
      if ((args['location'] as String?)?.isNotEmpty == true) 'location': args['location'],
      'start': allDay ? {'date': args['start']} : {'dateTime': _normalizeRfc3339(args['start'] as String? ?? '')},
      'end': allDay ? {'date': args['end']} : {'dateTime': _normalizeRfc3339(args['end'] as String? ?? '')},
    };
    if (args['attendees'] is List) {
      body['attendees'] = (args['attendees'] as List).map((e) => {'email': e}).toList();
    }
    final uri = Uri.parse('$_baseUrl/calendars/$calendarId/events');
    final resp = await _apiPost(uri, token, body);
    if (resp['error'] != null) return resp;
    return {'success': true, 'event': _summariseEvent(resp['data'] as Map<String, dynamic>)};
  }

  Future<Map<String, dynamic>> _updateEvent(Map<String, dynamic> args) async {
    final token = _resolveToken(args);
    if (token == null || token.isEmpty) return _noTokenError();
    final calendarId = Uri.encodeComponent(_calId(args));
    final eventId = Uri.encodeComponent(args['eventId'] as String? ?? '');
    final allDay = args['allDay'] == true;
    final body = <String, dynamic>{
      if (args['summary'] != null) 'summary': args['summary'],
      if (args['description'] != null) 'description': args['description'],
      if (args['location'] != null) 'location': args['location'],
      if (args['start'] != null) 'start': allDay ? {'date': args['start']} : {'dateTime': _normalizeRfc3339(args['start'] as String)},
      if (args['end'] != null) 'end': allDay ? {'date': args['end']} : {'dateTime': _normalizeRfc3339(args['end'] as String)},
    };
    final uri = Uri.parse('$_baseUrl/calendars/$calendarId/events/$eventId');
    final resp = await _apiPatch(uri, token, body);
    if (resp['error'] != null) return resp;
    return {'success': true, 'event': _summariseEvent(resp['data'] as Map<String, dynamic>)};
  }

  Future<Map<String, dynamic>> _deleteEvent(Map<String, dynamic> args) async {
    final token = _resolveToken(args);
    if (token == null || token.isEmpty) return _noTokenError();
    final calendarId = Uri.encodeComponent(_calId(args));
    final eventId = Uri.encodeComponent(args['eventId'] as String? ?? '');
    final uri = Uri.parse('$_baseUrl/calendars/$calendarId/events/$eventId');
    final resp = await _apiDelete(uri, token);
    if (resp['error'] != null) return resp;
    return {'success': true, 'message': 'Event $eventId deleted.'};
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  String _calId(Map<String, dynamic> args) => (args['calendarId'] as String?)?.trim().let((s) => s.isNotEmpty ? s : 'primary') ?? 'primary';

  Map<String, dynamic> _summariseEvent(Map<String, dynamic> e) {
    final start = e['start'] as Map? ?? {};
    final end = e['end'] as Map? ?? {};
    return {
      'id': e['id'],
      'summary': e['summary'],
      if (e['description'] != null) 'description': e['description'],
      if (e['location'] != null) 'location': e['location'],
      'start': start['dateTime'] ?? start['date'],
      'end': end['dateTime'] ?? end['date'],
      'status': e['status'],
      'htmlLink': e['htmlLink'],
      if (e['organizer'] != null) 'organizer': (e['organizer'] as Map)['email'],
      if (e['attendees'] != null) 'attendees': (e['attendees'] as List).map((a) => (a as Map)['email']).toList(),
    };
  }

  Map<String, dynamic> _noTokenError() => {
    'error':
        'No OAuth access token available. '
        'Authorize Google in Data Sources settings and ensure the calendar scope is included.',
  };

  String? _resolveToken(Map<String, dynamic> args) {
    final t = (args['accessToken'] as String?)?.trim();
    if (t != null && t.isNotEmpty) return t;
    return _accessToken;
  }

  /// Normalises a datetime string to RFC 3339 format required by Google Calendar API:
  /// - Truncates sub-millisecond precision (e.g. `.000864` → `.000`)
  /// - Appends `Z` (UTC) when no timezone offset is present
  ///
  /// Examples:
  ///   `2026-02-24T21:44:58.000864`  → `2026-02-24T21:44:58.000Z`
  ///   `2026-02-24T21:44:58`         → `2026-02-24T21:44:58Z`
  ///   `2026-02-24T21:44:58+01:00`   → unchanged
  ///   `2026-02-24T21:44:58Z`        → unchanged
  String _normalizeRfc3339(String dt) {
    if (dt.isEmpty) return dt;
    try {
      // DateTime.parse handles ISO 8601 including timezone offsets and microseconds.
      // toUtc().toIso8601String() yields 'YYYY-MM-DDTHH:mm:ss.mmmZ' — valid RFC 3339.
      return DateTime.parse(dt).toUtc().toIso8601String();
    } catch (_) {
      // Fallback: append Z if no timezone indicator is present after the date part.
      final afterDate = dt.length > 10 ? dt.substring(10) : '';
      final hasTimezone = afterDate.contains('Z') || afterDate.contains('+') || afterDate.contains('-');
      return hasTimezone ? dt : '${dt}Z';
    }
  }

  // ─── HTTP helpers with 401 auto-refresh ──────────────────────────────────

  Future<Map<String, dynamic>> _apiGet(Uri uri, String token, {bool retried = false}) async {
    try {
      final resp = await http.get(uri, headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'});
      if (resp.statusCode == 401 && !retried) return _refreshAndRetry(uri, 'GET', null);
      return _parseResponse(resp);
    } catch (e) {
      log.error('[Calendar MCP] GET error: $e');
      return {'error': 'Calendar request failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _apiPost(Uri uri, String token, Map<String, dynamic> body, {bool retried = false}) async {
    try {
      final resp = await http.post(
        uri,
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      if (resp.statusCode == 401 && !retried) return _refreshAndRetry(uri, 'POST', body);
      return _parseResponse(resp);
    } catch (e) {
      log.error('[Calendar MCP] POST error: $e');
      return {'error': 'Calendar request failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _apiPatch(Uri uri, String token, Map<String, dynamic> body, {bool retried = false}) async {
    try {
      final resp = await http.patch(
        uri,
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );
      if (resp.statusCode == 401 && !retried) return _refreshAndRetry(uri, 'PATCH', body);
      return _parseResponse(resp);
    } catch (e) {
      log.error('[Calendar MCP] PATCH error: $e');
      return {'error': 'Calendar request failed: $e'};
    }
  }

  Future<Map<String, dynamic>> _apiDelete(Uri uri, String token, {bool retried = false}) async {
    try {
      final resp = await http.delete(uri, headers: {'Authorization': 'Bearer $token'});
      if (resp.statusCode == 401 && !retried) return _refreshAndRetry(uri, 'DELETE', null);
      if (resp.statusCode == 204) return {'data': <String, dynamic>{}};
      return _parseResponse(resp);
    } catch (e) {
      log.error('[Calendar MCP] DELETE error: $e');
      return {'error': 'Calendar request failed: $e'};
    }
  }

  Map<String, dynamic> _parseResponse(http.Response resp) {
    final parsed = resp.body.isNotEmpty ? jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic> : <String, dynamic>{};
    if (resp.statusCode >= 200 && resp.statusCode < 300) return {'data': parsed};
    final msg = (parsed['error'] as Map?)?.containsKey('message') == true ? parsed['error']['message'] : resp.reasonPhrase;
    return {'error': 'Calendar API ${resp.statusCode}: $msg', 'statusCode': resp.statusCode};
  }

  Future<Map<String, dynamic>> _refreshAndRetry(Uri uri, String method, Map<String, dynamic>? body) async {
    log.info('[Calendar MCP] 401 received — attempting token refresh.');
    final ds = DataSourcesSettingsService.instance;
    final result = await ds.refreshGmailAccessToken();
    if (result['success'] != true) {
      return {'error': 'Calendar token expired and refresh failed: ${result['error']}'};
    }
    final newToken = ds.gmailAccessToken.trim();
    _accessToken = newToken;
    log.info('[Calendar MCP] Token refreshed, retrying.');
    switch (method) {
      case 'GET':
        return _apiGet(uri, newToken, retried: true);
      case 'POST':
        return _apiPost(uri, newToken, body!, retried: true);
      case 'PATCH':
        return _apiPatch(uri, newToken, body!, retried: true);
      case 'DELETE':
        return _apiDelete(uri, newToken, retried: true);
      default:
        return {'error': 'Unknown method $method'};
    }
  }
}

extension _StringLet on String {
  T let<T>(T Function(String) block) => block(this);
}
