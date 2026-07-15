import 'dart:convert';

import 'package:enough_mail/enough_mail.dart';

import '../../services/app_logger.dart';
import '../../services/data_sources_settings_service.dart';
import '../internal_mcp_server.dart';

/// Internal MCP server for IMAP email search and reading.
///
/// Uses the IMAP credentials stored in [DataSourcesSettingsService]
/// (host, port, username, password, SSL flag). Works with any standard
/// IMAP server — Gmail, Outlook, custom mail servers, etc.
class ImapMcpServer extends InternalMcpServer {
  @override
  String get type => 'imap';

  @override
  String get displayName => 'IMAP Email';

  @override
  String get description =>
      'Search and read emails from any IMAP mailbox. '
      'Uses the IMAP credentials configured in Settings → Data Sources.';

  @override
  String get iconName => 'email';

  @override
  Map<String, dynamic> get initParamSchema => {'type': 'object', 'properties': {}, 'required': []};

  @override
  Map<String, dynamic> get defaultInitParams => {};

  @override
  String get defaultSystemPrompt =>
      'IMAP email tools: '
      'Use list_folders to discover available mailbox folders. '
      'Use search_emails to find messages — combine from/to/subject/body/since/before/unseen filters. '
      'Date format for since/before: YYYY-MM-DD. '
      'Use read_email with the uid and folder returned by search_emails to retrieve the full message body.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    log.info('[IMAP MCP] Initialized');
  }

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'list_folders',
      description:
          'List all available IMAP folders / mailboxes on the server. '
          'Call this first if you need to search in a folder other than INBOX.',
      inputSchema: {'type': 'object', 'properties': {}, 'required': []},
    ),
    const McpToolDescriptor(
      name: 'search_emails',
      description:
          'Search emails in an IMAP mailbox. '
          'Returns uid, from, to, subject, date and seen-status for each match. '
          'Pass the uid to read_email to get the full body.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'folder': {
            'type': 'string',
            'description': 'Mailbox folder to search (default: INBOX). Use list_folders to discover folder names.',
            'default': 'INBOX',
          },
          'from': {'type': 'string', 'description': 'Filter by sender address or name (partial match).'},
          'to': {'type': 'string', 'description': 'Filter by recipient address or name (partial match).'},
          'subject': {'type': 'string', 'description': 'Filter by subject keyword.'},
          'body': {'type': 'string', 'description': 'Full-text search in message body.'},
          'since': {'type': 'string', 'description': 'Return emails on or after this date. Format: YYYY-MM-DD.'},
          'before': {'type': 'string', 'description': 'Return emails before this date. Format: YYYY-MM-DD.'},
          'unseen': {'type': 'boolean', 'description': 'If true, return only unread (unseen) emails.'},
          'maxResults': {'type': 'integer', 'description': 'Maximum number of results to return (default: 20, max: 50).', 'default': 20},
        },
        'required': [],
      },
    ),
    const McpToolDescriptor(
      name: 'read_email',
      description:
          'Read the full content of a specific email. '
          'Use the uid and folder from the search_emails result.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'uid': {'type': 'integer', 'description': 'The UID of the email (from search_emails result).'},
          'folder': {'type': 'string', 'description': 'Mailbox folder (default: INBOX).', 'default': 'INBOX'},
        },
        'required': ['uid'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    final settings = DataSourcesSettingsService.instance;
    final host = settings.imapHost.trim();
    final port = settings.imapPort;
    final username = settings.imapUsername.trim();
    final password = settings.imapPassword.trim();
    final useSsl = settings.imapUseSsl;

    if (host.isEmpty || username.isEmpty || password.isEmpty) {
      return _error(
        'IMAP credentials not configured. '
        'Please set IMAP host, username and password in Settings → Data Sources.',
      );
    }

    switch (toolName) {
      case 'list_folders':
        return _listFolders(host, port, username, password, useSsl);
      case 'search_emails':
        return _searchEmails(host, port, username, password, useSsl, arguments);
      case 'read_email':
        return _readEmail(host, port, username, password, useSsl, arguments);
      default:
        return _error('Unknown IMAP tool: $toolName');
    }
  }

  // ─────────────────────────────────────────────────────────────
  // list_folders
  // ─────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _listFolders(String host, int port, String username, String password, bool useSsl) async {
    final client = ImapClient(isLogEnabled: false);
    try {
      await client.connectToServer(host, port, isSecure: useSsl);
      await client.login(username, password);
      final listResult = await client.listMailboxes();
      await client.logout();

      final folders = listResult.map((m) => m.path).toList();
      log.info('[IMAP MCP] list_folders → ${folders.length} folders');
      return _ok({'folders': folders});
    } catch (e, st) {
      log.error('[IMAP MCP] list_folders error: $e', e, st);
      await _safeLogout(client);
      return _error('IMAP error listing folders: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────
  // search_emails
  // ─────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _searchEmails(
    String host,
    int port,
    String username,
    String password,
    bool useSsl,
    Map<String, dynamic> args,
  ) async {
    final folder = _argStr(args, 'folder', 'INBOX');
    final from = _argStr(args, 'from', '');
    final to = _argStr(args, 'to', '');
    final subject = _argStr(args, 'subject', '');
    final body = _argStr(args, 'body', '');
    final since = _argStr(args, 'since', '');
    final before = _argStr(args, 'before', '');
    final unseen = args['unseen'] as bool? ?? false;
    final maxResults = (args['maxResults'] as int? ?? 20).clamp(1, 50);

    // Build IMAP search criteria.
    // IMPORTANT: Gmail (and many servers) do NOT support CHARSET UTF-8 or
    // Build a raw 7-bit ASCII IMAP criteria string.
    // We avoid SearchQueryBuilder because SearchQueryBuilder.from('', SearchQueryType.subject)
    // always injects an implicit "SUBJECT \"\"" term that Gmail/other servers reject.
    // All text values are normalized to ASCII (ö→o, ü→u …) for maximum compatibility.
    final parts = <String>[];
    if (from.isNotEmpty) parts.add('FROM "${_toAsciiSearch(from)}"');
    if (to.isNotEmpty) parts.add('TO "${_toAsciiSearch(to)}"');
    if (subject.isNotEmpty) parts.add('SUBJECT "${_toAsciiSearch(subject)}"');
    if (body.isNotEmpty) parts.add('BODY "${_toAsciiSearch(body)}"');
    if (since.isNotEmpty) {
      final d = _parseYmd(since);
      if (d != null) parts.add('SINCE ${_imapDate(d)}');
    }
    if (before.isNotEmpty) {
      final d = _parseYmd(before);
      if (d != null) parts.add('BEFORE ${_imapDate(d)}');
    }
    if (unseen) parts.add('UNSEEN');
    final criteria = parts.isEmpty ? 'ALL' : parts.join(' ');

    log.info('[IMAP MCP] search_emails folder=$folder criteria="$criteria" max=$maxResults');

    final client = ImapClient(isLogEnabled: false);
    try {
      await client.connectToServer(host, port, isSecure: useSsl);
      await client.login(username, password);
      await client.selectMailboxByPath(folder);

      // Use UID SEARCH so returned IDs are real UIDs (needed for read_email with isUid:true).
      // Use raw criteria string to avoid SearchQueryBuilder injecting implicit terms.
      final searchResult = await client.uidSearchMessages(searchCriteria: criteria);
      final allUids = searchResult.matchingSequence?.toList() ?? [];

      if (allUids.isEmpty) {
        await client.logout();
        return _ok({'messages': <dynamic>[], 'total': 0, 'folder': folder});
      }

      // Take the last N (highest UID = most recent in most servers).
      final sliced = allUids.length > maxResults ? allUids.sublist(allUids.length - maxResults) : allUids;

      final seq = MessageSequence.fromIds(sliced, isUid: true);
      // Use UID FETCH so msg.uid is always populated.
      // RFC 3501: multiple fetch items MUST be in parentheses → "(UID ENVELOPE FLAGS)"
      final fetchResult = await client.uidFetchMessages(seq, '(UID ENVELOPE FLAGS)');
      await client.logout();

      final messages = (fetchResult.messages).reversed.map((msg) {
        return {
          'uid': msg.uid,
          'id': msg.uid.toString(), // widget reads 'id' to identify each message
          'folder': folder, // needed so the detail dialog can call read_email
          'seq': msg.sequenceId,
          'from': _fmtAddresses(msg.from),
          'to': _fmtAddresses(msg.to),
          'subject': msg.decodeSubject() ?? '',
          'date': msg.decodeDate()?.toIso8601String() ?? '',
          'seen': msg.isSeen,
        };
      }).toList();

      log.info('[IMAP MCP] search_emails → ${messages.length} of ${allUids.length} results');
      return _ok({'messages': messages, 'total': allUids.length, 'returned': messages.length, 'folder': folder});
    } catch (e, st) {
      log.error('[IMAP MCP] search_emails error: $e', e, st);
      await _safeLogout(client);
      return _error('IMAP search error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────
  // read_email
  // ─────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _readEmail(
    String host,
    int port,
    String username,
    String password,
    bool useSsl,
    Map<String, dynamic> args,
  ) async {
    final uid = args['uid'] as int?;
    if (uid == null) return _error('Parameter "uid" is required.');
    final requestedFolder = _argStr(args, 'folder', 'INBOX');

    log.info('[IMAP MCP] read_email uid=$uid folder=$requestedFolder');

    // Folders to try in order. Gmail archives mean the UID may only exist in
    // [Gmail]/All Mail even if the search was run against INBOX.
    final foldersToTry = <String>{requestedFolder};
    if (requestedFolder == 'INBOX') {
      foldersToTry.addAll(['[Gmail]/All Mail', 'All Mail', 'INBOX']);
    }
    // Always try [Gmail]/All Mail as last resort on Gmail servers.
    foldersToTry.add('[Gmail]/All Mail');

    final client = ImapClient(isLogEnabled: false);
    try {
      await client.connectToServer(host, port, isSecure: useSsl);
      await client.login(username, password);

      MimeMessage? msg;
      String foundFolder = requestedFolder;

      for (final folder in foldersToTry) {
        try {
          await client.selectMailboxByPath(folder);
          // Use uidFetchMessages (explicit UID FETCH) — fetchMessages may treat
          // the id as a sequential message number even when isUid:true is set.
          final fetchResult = await client.uidFetchMessages(MessageSequence.fromId(uid, isUid: true), '(UID ENVELOPE FLAGS BODY[])');
          if (fetchResult.messages.isNotEmpty) {
            msg = fetchResult.messages.first;
            foundFolder = folder;
            log.info('[IMAP MCP] read_email found uid=$uid in folder=$foundFolder');
            break;
          }
        } catch (_) {
          // Folder may not exist on this server — try next.
        }
      }

      await client.logout();

      if (msg == null) {
        return _error('Email uid=$uid not found in folder "$requestedFolder".');
      }

      // Extract plain-text and HTML parts separately.
      String body = msg.decodeTextPlainPart() ?? '';
      String htmlBody = msg.decodeTextHtmlPart() ?? '';

      // If no plain text, create a readable version from HTML for the LLM.
      if (body.isEmpty && htmlBody.isNotEmpty) {
        body = htmlBody.replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      }
      const maxBodyLen = 6000;
      if (body.length > maxBodyLen) {
        body = '${body.substring(0, maxBodyLen)}\n[truncated — body too long]';
      }
      if (htmlBody.length > maxBodyLen * 2) {
        htmlBody = '${htmlBody.substring(0, maxBodyLen * 2)}\n<!-- truncated -->';
      }

      final attachments = <String>[];
      _collectAttachmentNames(msg, attachments);

      return _ok({
        'uid': msg.uid != 0 ? msg.uid : uid,
        'folder': foundFolder,
        'from': _fmtAddresses(msg.from),
        'to': _fmtAddresses(msg.to),
        'cc': _fmtAddresses(msg.cc),
        'subject': msg.decodeSubject() ?? '',
        'date': msg.decodeDate()?.toIso8601String() ?? '',
        'seen': msg.isSeen,
        'body': body,
        'htmlBody': htmlBody,
        'attachments': attachments,
      });
    } catch (e, st) {
      log.error('[IMAP MCP] read_email error: $e', e, st);
      await _safeLogout(client);
      return _error('IMAP read error: $e');
    }
  }

  // ─────────────────────────────────────────────────────────────
  // Helpers
  // ─────────────────────────────────────────────────────────────

  Map<String, dynamic> _ok(Map<String, dynamic> data) => {
    'content': [
      {'type': 'text', 'text': const JsonEncoder.withIndent('  ').convert(data)},
    ],
  };

  Map<String, dynamic> _error(String message) => {
    'isError': true,
    'content': [
      {'type': 'text', 'text': message},
    ],
  };

  /// Converts a string to 7-bit ASCII by mapping common diacritic characters
  /// to their base letter equivalents.  This is used for IMAP SEARCH terms
  /// because Gmail (and many servers) reject CHARSET UTF-8 / literal syntax.
  static const _diacriticMap = <int, String>{
    // Lowercase
    0xe0: 'a', 0xe1: 'a', 0xe2: 'a', 0xe3: 'a', 0xe4: 'a', 0xe5: 'a', // à á â ã ä å
    0xe6: 'ae', // æ
    0xe7: 'c', // ç
    0xe8: 'e', 0xe9: 'e', 0xea: 'e', 0xeb: 'e', // è é ê ë
    0xec: 'i', 0xed: 'i', 0xee: 'i', 0xef: 'i', // ì í î ï
    0xf0: 'd', // ð
    0xf1: 'n', // ñ
    0xf2: 'o', 0xf3: 'o', 0xf4: 'o', 0xf5: 'o', 0xf6: 'o', 0xf8: 'o', // ò ó ô õ ö ø
    0xf9: 'u', 0xfa: 'u', 0xfb: 'u', 0xfc: 'u', // ù ú û ü
    0xfd: 'y', 0xff: 'y', // ý ÿ
    0xdf: 'ss', // ß
    // Uppercase
    0xc0: 'A', 0xc1: 'A', 0xc2: 'A', 0xc3: 'A', 0xc4: 'A', 0xc5: 'A',
    0xc6: 'AE',
    0xc7: 'C',
    0xc8: 'E', 0xc9: 'E', 0xca: 'E', 0xcb: 'E',
    0xcc: 'I', 0xcd: 'I', 0xce: 'I', 0xcf: 'I',
    0xd0: 'D',
    0xd1: 'N',
    0xd2: 'O', 0xd3: 'O', 0xd4: 'O', 0xd5: 'O', 0xd6: 'O', 0xd8: 'O',
    0xd9: 'U', 0xda: 'U', 0xdb: 'U', 0xdc: 'U',
    0xdd: 'Y',
  };

  String _toAsciiSearch(String s) {
    final buf = StringBuffer();
    for (final r in s.runes) {
      if (r < 128) {
        buf.writeCharCode(r);
      } else {
        buf.write(_diacriticMap[r] ?? '');
      }
    }
    return buf.toString();
  }

  String _argStr(Map<String, dynamic> args, String key, String fallback) {
    final raw = args[key];
    if (raw == null) return fallback;
    // LLM may send a List of address objects — extract the first name/email string
    if (raw is List) {
      final parts = raw
          .map((e) {
            if (e is Map) {
              final name = (e['name'] ?? e['displayName'] ?? '').toString().trim();
              final email = (e['email'] ?? e['address'] ?? '').toString().trim();
              if (name.isNotEmpty) return name;
              return email;
            }
            return e.toString();
          })
          .where((s) => s.isNotEmpty)
          .join(', ');
      return parts.isNotEmpty ? parts : fallback;
    }
    final v = raw.toString().trim();
    return v.isNotEmpty ? v : fallback;
  }

  String _fmtAddresses(List<MailAddress>? addresses) {
    if (addresses == null || addresses.isEmpty) return '';
    return addresses
        .map((a) {
          final name = (a.personalName ?? '').trim();
          final email = a.email.trim();
          if (name.isNotEmpty && email.isNotEmpty) return '$name <$email>';
          return email.isNotEmpty ? email : name;
        })
        .join(', ');
  }

  /// Recursively collect attachment filenames from MIME parts.
  void _collectAttachmentNames(MimePart part, List<String> result) {
    final cd = part.getHeaderValue('content-disposition') ?? '';
    final filename = part.decodeFileName();
    if (filename != null && filename.isNotEmpty) {
      result.add(filename);
    } else if (cd.toLowerCase().startsWith('attachment')) {
      result.add(part.mediaType.text);
    }
    for (final child in part.parts ?? const <MimePart>[]) {
      _collectAttachmentNames(child, result);
    }
  }

  DateTime? _parseYmd(String s) {
    try {
      return DateTime.parse(s);
    } catch (_) {
      return null;
    }
  }

  /// Formats a [DateTime] as an IMAP date literal: `dd-Mon-yyyy` (e.g. `20-Feb-2026`).
  /// No quotes — they are added by the caller when needed.
  String _imapDate(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day.toString().padLeft(2, '0')}-${months[d.month - 1]}-${d.year}';
  }

  Future<void> _safeLogout(ImapClient client) async {
    try {
      await client.logout();
    } catch (_) {}
  }
}
