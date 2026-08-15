import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/app_logger.dart';
import '../../services/data_sources_settings_service.dart';
import '../internal_mcp_server.dart';

/// Internal MCP server for Gmail search/read operations.
///
/// Uses Gmail REST API with OAuth2 bearer token.
/// Token can be passed via init params or per-tool argument `accessToken`.
class GmailMcpServer extends InternalMcpServer {
  static const String _baseUrl = 'https://gmail.googleapis.com/gmail/v1/users';

  String _userId = 'me';
  String? _accessToken;

  @override
  String get type => 'gmail';

  @override
  String get displayName => 'Gmail';

  @override
  String get description =>
      'Search and read Gmail messages via Gmail API (OAuth2). '
      'Supports Gmail query syntax using the standard q parameter.';

  @override
  String get iconName => 'email';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'userId': {
        'type': 'string',
        'description': 'Gmail user id. Usually "me".',
        'default': 'me',
      },
      'accessToken': {
        'type': 'string',
        'description': 'OAuth2 bearer access token for Gmail API.',
      },
    },
    'required': [],
  };

  @override
  Map<String, dynamic> get defaultInitParams => {
    'userId': 'me',
    'accessToken': '',
  };

  @override
  String get defaultSystemPrompt =>
      'Gmail tools: use search_gmail with Gmail q syntax '
      '(e.g. from:someone@example.com, is:unread, has:attachment, subject:invoice). '
      'Do NOT add time filters (newer_than, older_than, after, before) unless the user explicitly requests them. '
      'Return ALL matching messages within the requested maxResults limit. '
      'Summaries should include sender, subject, date, and key points.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    _userId = (initParams['userId'] as String? ?? 'me').trim();
    if (_userId.isEmpty) _userId = 'me';

    final token = (initParams['accessToken'] as String?)?.trim();
    if (token != null && token.isNotEmpty) {
      _accessToken = token;
    }

    log.info('[Gmail MCP] Initialized for userId=$_userId');
  }

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'search_gmail',
      description:
          'Search Gmail messages using Gmail API q parameter. '
          'Example queries: "from:john@example.com", "from:amazon has:attachment", "is:unread subject:invoice". '
          'Only add time filters (newer_than, older_than) when the user explicitly asks for recent or old emails.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'q': {
            'type': 'string',
            'description': 'Gmail query string (standard Gmail search syntax).',
          },
          'maxResults': {
            'type': 'integer',
            'description': 'Maximum results (default: 20, max: 100).',
            'default': 20,
          },
          'labelIds': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Optional label filters (e.g. INBOX, UNREAD).',
          },
          'includeBody': {
            'type': 'boolean',
            'description':
                'Include extracted plain text body (default: false).',
            'default': false,
          },
          'accessToken': {
            'type': 'string',
            'description':
                'Optional token override. If omitted, uses init accessToken.',
          },
        },
        'required': ['q'],
      },
    ),
    const McpToolDescriptor(
      name: 'get_gmail_message',
      description: 'Fetch one Gmail message by id.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'description': 'Gmail message id.'},
          'format': {
            'type': 'string',
            'enum': ['metadata', 'full', 'minimal'],
            'default': 'full',
          },
          'accessToken': {
            'type': 'string',
            'description': 'Optional token override.',
          },
        },
        'required': ['id'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    switch (toolName) {
      case 'search_gmail':
        return _searchGmail(arguments);
      case 'get_gmail_message':
        return _getGmailMessage(arguments);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  Future<Map<String, dynamic>> _searchGmail(Map<String, dynamic> args) async {
    final rawQuery = (args['q'] as String?)?.trim();
    if (rawQuery == null || rawQuery.isEmpty) {
      return {'error': 'Parameter "q" is required for Gmail search.'};
    }

    final query = _normalizeGmailQuery(rawQuery);
    if (query.isEmpty) {
      return {'error': 'Gmail query is empty after normalization.'};
    }

    final token = _resolveToken(args);
    if (token == null || token.isEmpty) {
      return {
        'error':
            'No OAuth access token available. Pass `accessToken` in tool args or initialize gmail MCP with accessToken.',
      };
    }

    final maxResults = ((args['maxResults'] as int?) ?? 20).clamp(1, 100);
    final includeBody = args['includeBody'] == true;
    final labelIds =
        (args['labelIds'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];

    final listUri = Uri.parse('$_baseUrl/$_userId/messages').replace(
      queryParameters: {
        'q': query,
        'maxResults': '$maxResults',
        if (labelIds.isNotEmpty) 'labelIds': labelIds.join(','),
      },
    );

    final listResp = await _gmailGet(listUri, token);
    if (listResp['error'] != null) return listResp;

    final messagesRaw =
        (listResp['data'] as Map<String, dynamic>)['messages']
            as List<dynamic>? ??
        const [];
    if (messagesRaw.isEmpty) {
      return {
        'originalQuery': rawQuery,
        'query': query,
        'maxResults': maxResults,
        'totalEstimated':
            (listResp['data'] as Map<String, dynamic>)['resultSizeEstimate'] ??
            0,
        'messages': <Map<String, dynamic>>[],
      };
    }

    final messages = <Map<String, dynamic>>[];
    for (final entry in messagesRaw) {
      final id = (entry as Map<String, dynamic>)['id']?.toString();
      if (id == null || id.isEmpty) continue;

      final detail = await _fetchMessageSummary(
        id,
        token,
        includeBody: includeBody,
      );
      if (detail['error'] == null) {
        messages.add(detail);
      }
    }

    return {
      'originalQuery': rawQuery,
      'query': query,
      'maxResults': maxResults,
      'totalEstimated':
          (listResp['data'] as Map<String, dynamic>)['resultSizeEstimate'] ??
          messages.length,
      'returned': messages.length,
      'messages': messages,
    };
  }

  String _normalizeGmailQuery(String query) {
    var normalized = query.trim();
    if (normalized.isEmpty) return normalized;

    final lower = normalized.toLowerCase();

    if (RegExp(r'\bafter:yesterday\b').hasMatch(lower) &&
        RegExp(r'\bbefore:today\b').hasMatch(lower)) {
      normalized = normalized.replaceAll(
        RegExp(r'\bafter:yesterday\b', caseSensitive: false),
        '',
      );
      normalized = normalized.replaceAll(
        RegExp(r'\bbefore:today\b', caseSensitive: false),
        '',
      );
      normalized = '$normalized newer_than:2d older_than:1d';
    } else {
      normalized = normalized.replaceAll(
        RegExp(r'\bafter:today\b', caseSensitive: false),
        'newer_than:1d',
      );
      normalized = normalized.replaceAll(
        RegExp(r'\bbefore:today\b', caseSensitive: false),
        'older_than:1d',
      );
      normalized = normalized.replaceAll(
        RegExp(r'\bafter:yesterday\b', caseSensitive: false),
        'newer_than:2d',
      );
      normalized = normalized.replaceAll(
        RegExp(r'\bbefore:yesterday\b', caseSensitive: false),
        'older_than:2d',
      );
    }

    normalized = normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized;
  }

  Future<Map<String, dynamic>> _getGmailMessage(
    Map<String, dynamic> args,
  ) async {
    final id = (args['id'] as String?)?.trim();
    if (id == null || id.isEmpty) {
      return {'error': 'Parameter "id" is required.'};
    }

    final format = (args['format'] as String? ?? 'full').trim();
    final token = _resolveToken(args);
    if (token == null || token.isEmpty) {
      return {
        'error':
            'No OAuth access token available. Pass `accessToken` in tool args or initialize gmail MCP with accessToken.',
      };
    }

    final uri = Uri.parse(
      '$_baseUrl/$_userId/messages/$id',
    ).replace(queryParameters: {'format': format});
    final resp = await _gmailGet(uri, token);
    if (resp['error'] != null) return resp;

    final data = resp['data'] as Map<String, dynamic>;
    return {
      'id': data['id'],
      'threadId': data['threadId'],
      'labelIds': data['labelIds'],
      'snippet': data['snippet'],
      'historyId': data['historyId'],
      'internalDate': data['internalDate'],
      'payload': data['payload'],
      if (format == 'full')
        'plainTextBody': _extractPlainTextBody(
          data['payload'] as Map<String, dynamic>?,
        ),
    };
  }

  Future<Map<String, dynamic>> _fetchMessageSummary(
    String messageId,
    String accessToken, {
    required bool includeBody,
  }) async {
    final metadataUri = Uri.parse(
      '$_baseUrl/$_userId/messages/$messageId',
    ).replace(queryParameters: {'format': 'metadata'});

    final resp = await _gmailGet(metadataUri, accessToken);
    if (resp['error'] != null) return resp;

    final data = resp['data'] as Map<String, dynamic>;
    String? htmlBody;
    final payload = data['payload'] as Map<String, dynamic>? ?? const {};
    final attachmentCount = _countAttachments(payload);
    final headers = (payload['headers'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (h) => MapEntry(
            (h['name'] ?? '').toString().toLowerCase(),
            (h['value'] ?? '').toString(),
          ),
        )
        .fold<Map<String, String>>(<String, String>{}, (acc, e) {
          acc[e.key] = e.value;
          return acc;
        });

    String? body;
    if (includeBody) {
      final fullResp = await _gmailGet(
        Uri.parse(
          '$_baseUrl/$_userId/messages/$messageId',
        ).replace(queryParameters: {'format': 'full'}),
        accessToken,
      );
      if (fullResp['error'] == null) {
        final fullPayload =
            (fullResp['data'] as Map<String, dynamic>)['payload']
                as Map<String, dynamic>?;
        body = _extractPlainTextBody(fullPayload);
        htmlBody = _extractHtmlBody(fullPayload);
      }
    }

    final snippet = (data['snippet'] ?? '').toString();
    final subject = _pickSubject(headers['subject'] ?? '', snippet);
    final attachmentNames = _extractAttachmentNames(payload);

    return {
      'id': data['id'],
      'threadId': data['threadId'],
      'subject': subject,
      'from': headers['from'] ?? '',
      'to': headers['to'] ?? '',
      'cc': headers['cc'] ?? '',
      'date': headers['date'] ?? '',
      'snippet': snippet,
      'internalDate': data['internalDate'],
      'hasAttachments': attachmentCount > 0,
      'attachmentCount': attachmentCount,
      if (attachmentNames.isNotEmpty) 'attachmentNames': attachmentNames,
      if (includeBody) 'body': body ?? '',
      if (includeBody) 'htmlBody': htmlBody ?? '',
    };
  }

  String _pickSubject(String headerSubject, String snippet) {
    final subject = headerSubject.trim();
    if (subject.isNotEmpty) return subject;

    final fallback = snippet.trim();
    if (fallback.isEmpty) return '';

    if (fallback.length <= 120) return fallback;
    return fallback.substring(0, 120).trimRight();
  }

  /// Recursively collect all attachment filenames from payload parts.
  List<String> _extractAttachmentNames(Map<String, dynamic>? payload) {
    if (payload == null) return const [];
    final result = <String>[];
    final filename = (payload['filename'] ?? '').toString().trim();
    final mimeType = (payload['mimeType'] ?? '').toString().trim();
    final body = payload['body'] as Map<String, dynamic>?;
    final attachmentId = (body?['attachmentId'] ?? '').toString().trim();
    if (filename.isNotEmpty) {
      final label = mimeType.isNotEmpty ? '$filename ($mimeType)' : filename;
      result.add(label);
    } else if (attachmentId.isNotEmpty &&
        mimeType.isNotEmpty &&
        !mimeType.startsWith('multipart')) {
      result.add(mimeType);
    }
    final parts = payload['parts'] as List<dynamic>? ?? const [];
    for (final part in parts.whereType<Map<String, dynamic>>()) {
      result.addAll(_extractAttachmentNames(part));
    }
    return result;
  }

  int _countAttachments(Map<String, dynamic>? payload) {
    if (payload == null) return 0;

    var count = 0;

    final filename = (payload['filename'] ?? '').toString().trim();
    final body = payload['body'] as Map<String, dynamic>?;
    final attachmentId = (body?['attachmentId'] ?? '').toString().trim();

    if (filename.isNotEmpty || attachmentId.isNotEmpty) {
      count++;
    }

    final parts = payload['parts'] as List<dynamic>? ?? const [];
    for (final part in parts.whereType<Map<String, dynamic>>()) {
      count += _countAttachments(part);
    }

    return count;
  }

  Future<Map<String, dynamic>> _gmailGet(Uri uri, String token) async {
    return _gmailGetWithRetry(uri, token, retried: false);
  }

  Future<Map<String, dynamic>> _gmailGetWithRetry(
    Uri uri,
    String token, {
    required bool retried,
  }) async {
    try {
      final response = await http.get(
        uri,
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );

      final parsed = response.body.isNotEmpty
          ? jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>
          : <String, dynamic>{};

      // Auto-refresh on 401 and retry once.
      if (response.statusCode == 401 && !retried) {
        log.info('[Gmail MCP] 401 received — attempting token refresh.');
        final ds = DataSourcesSettingsService.instance;
        final result = await ds.refreshGmailAccessToken();
        if (result['success'] == true) {
          final newToken = ds.gmailAccessToken.trim();
          _accessToken = newToken;
          log.info('[Gmail MCP] Token refreshed, retrying request.');
          return await _gmailGetWithRetry(uri, newToken, retried: true);
        }
        log.warning('[Gmail MCP] Token refresh failed: ${result['error']}');
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return {'data': parsed};
      }

      return {
        'error':
            'Gmail API error ${response.statusCode}: ${parsed['error'] ?? response.reasonPhrase}',
        'statusCode': response.statusCode,
      };
    } catch (e) {
      log.error('[Gmail MCP] Request failed: $e');
      return {'error': 'Gmail request failed: $e'};
    }
  }

  String? _resolveToken(Map<String, dynamic> args) {
    final tokenFromArgs = (args['accessToken'] as String?)?.trim();
    if (tokenFromArgs != null && tokenFromArgs.isNotEmpty) return tokenFromArgs;
    return _accessToken;
  }

  /// Extract the best HTML body from a Gmail message payload.
  String _extractHtmlBody(Map<String, dynamic>? payload) {
    if (payload == null) return '';

    final body = payload['body'] as Map<String, dynamic>?;
    final bodyData = body?['data']?.toString();
    final mimeType = payload['mimeType']?.toString() ?? '';

    if (bodyData != null && bodyData.isNotEmpty && mimeType == 'text/html') {
      return _decodeBase64Url(bodyData);
    }

    final parts = payload['parts'] as List<dynamic>? ?? const [];
    // Prefer explicit text/html parts
    for (final part in parts.whereType<Map<String, dynamic>>()) {
      final mt = part['mimeType']?.toString() ?? '';
      if (mt == 'text/html') {
        final data = (part['body'] as Map<String, dynamic>?)?['data']
            ?.toString();
        if (data != null && data.isNotEmpty) {
          return _decodeBase64Url(data);
        }
      }
    }
    // Recurse into multipart containers
    for (final part in parts.whereType<Map<String, dynamic>>()) {
      final nested = _extractHtmlBody(part);
      if (nested.trim().isNotEmpty) return nested;
    }

    return '';
  }

  String _extractPlainTextBody(Map<String, dynamic>? payload) {
    if (payload == null) return '';

    final body = payload['body'] as Map<String, dynamic>?;
    final bodyData = body?['data']?.toString();
    final mimeType = payload['mimeType']?.toString() ?? '';

    if (bodyData != null &&
        bodyData.isNotEmpty &&
        (mimeType == 'text/plain' || mimeType.isEmpty)) {
      return _decodeBase64Url(bodyData);
    }

    final parts = payload['parts'] as List<dynamic>? ?? const [];
    for (final part in parts.whereType<Map<String, dynamic>>()) {
      final mt = part['mimeType']?.toString() ?? '';
      if (mt == 'text/plain') {
        final data = (part['body'] as Map<String, dynamic>?)?['data']
            ?.toString();
        if (data != null && data.isNotEmpty) {
          return _decodeBase64Url(data);
        }
      }
      final nested = _extractPlainTextBody(part);
      if (nested.trim().isNotEmpty) return nested;
    }

    return '';
  }

  String _decodeBase64Url(String value) {
    try {
      final normalized = base64.normalize(
        value.replaceAll('-', '+').replaceAll('_', '/'),
      );
      return utf8.decode(base64Decode(normalized), allowMalformed: true);
    } catch (_) {
      return '';
    }
  }
}
