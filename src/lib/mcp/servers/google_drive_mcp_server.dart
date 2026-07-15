import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/app_logger.dart';
import '../../services/data_sources_settings_service.dart';
import '../internal_mcp_server.dart';

/// Internal MCP server for searching, reading, and writing files in Google Drive.
///
/// Uses the Google Drive API (v3) with OAuth2 credentials from the global
/// [DataSourcesSettingsService]. Provides:
///   • Search files by name or content
///   • List files in a folder
///   • Read file content (text extraction)
///   • Upload / overwrite a text file (requires drive.file scope)
///
/// Init parameters:
///   • folderPath: Optional folder path to restrict search (e.g. "My Documents")
///   • fileTypes:  Comma-separated MIME types or extensions to filter
class GoogleDriveMcpServer extends InternalMcpServer {
  static const String _driveBaseUrl = 'https://www.googleapis.com/drive/v3';

  String _folderPath = '';
  List<String> _fileTypes = [];

  @override
  String get type => 'google_drive';

  @override
  String get displayName => 'Google Drive';

  @override
  String get description =>
      'Search and read files from Google Drive. '
      'Uses Google Drive API with OAuth2 credentials configured in Data Sources settings.';

  @override
  String get iconName => 'add_to_drive';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'folderPath': {
        'type': 'string',
        'description':
            'Optional folder path to restrict search scope '
            '(e.g. "My Documents/Reports"). Leave empty to search all files.',
        'default': '',
      },
      'fileTypes': {
        'type': 'string',
        'description':
            'Comma-separated file extensions to include '
            '(e.g. "txt,md,docx,xlsx,pdf,csv"). Leave empty for all supported types.',
        'default': 'txt,md,docx,xlsx,pdf,csv',
      },
    },
    'required': [],
  };

  @override
  Map<String, dynamic> get defaultInitParams => {'folderPath': '', 'fileTypes': 'txt,md,docx,xlsx,pdf,csv'};

  @override
  String get defaultSystemPrompt =>
      'Google Drive tools: use search_drive to find files (recursive by default, '
      'searches all subfolders), list_drive_folder to browse folders (set recursive=true '
      'to include all subfolders), read_drive_file for file content, '
      'upload_to_drive to create or overwrite a plain-text/markdown file in a specific folder, '
      'and delete_drive_file to move a file to trash (or permanently delete when permanently=true). '
      'search_drive accepts a folderPath to narrow the search scope. '
      'Return file names and relevant excerpts.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    _folderPath = (initParams['folderPath'] as String? ?? '').trim();
    final fileTypesStr = initParams['fileTypes'] as String? ?? 'txt,md,docx,xlsx,pdf,csv';
    _fileTypes = fileTypesStr.split(',').map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList();

    log.info('[Google Drive MCP] Initializing – folder="$_folderPath", fileTypes=${_fileTypes.join(",")}');

    // Validate that Google Drive credentials are configured globally
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isGoogleDriveConfigured) {
      log.warning('[Google Drive MCP] Google Drive not configured in Data Sources settings');
    }
  }

  @override
  String? validateInitParams(Map<String, dynamic> params) {
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isGoogleDriveConfigured) {
      return 'Google Drive credentials not configured. Go to Data Sources on the start screen.';
    }
    return null;
  }

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'search_drive',
      description:
          'Search for files in Google Drive by name or content. '
          'Returns a list of matching files with their IDs, names, and MIME types. '
          'By default searches recursively across ALL subfolders.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'Search query (supports Google Drive search syntax, e.g. "name contains \'report\'" or free text).',
          },
          'folderPath': {
            'type': 'string',
            'description':
                'Optional folder path to search in (e.g. "THIES/Thiesai"). '
                'When recursive is true (default), also searches all subfolders. '
                'Leave empty to search entire Drive.',
          },
          'recursive': {
            'type': 'boolean',
            'description':
                'When true (default), searches recursively in ALL subfolders under the specified folder. '
                'When false, only searches direct children of the folder.',
            'default': true,
          },
          'maxResults': {'type': 'integer', 'description': 'Maximum number of results to return (default: 20, max: 100).', 'default': 20},
        },
        'required': ['query'],
      },
    ),
    const McpToolDescriptor(
      name: 'list_drive_folder',
      description:
          'List files in a specific Google Drive folder. Returns file names, types, and sizes. '
          'Supports recursive listing to include all files in subfolders.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'folderPath': {'type': 'string', 'description': 'Folder path or ID. Use empty string for root.'},
          'recursive': {
            'type': 'boolean',
            'description':
                'When true, recursively lists ALL files in ALL subfolders. '
                'When false (default), only lists direct children.',
            'default': false,
          },
          'maxResults': {'type': 'integer', 'description': 'Maximum total files to return (default: 50, max: 500).', 'default': 50},
        },
        'required': [],
      },
    ),
    const McpToolDescriptor(
      name: 'read_drive_file',
      description:
          'Read the text content of a file from Google Drive. '
          'Supports Google Docs, Sheets, PDF, TXT, MD, DOCX, XLSX, CSV.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'fileId': {'type': 'string', 'description': 'The Google Drive file ID (obtained from search_drive or list_drive_folder).'},
        },
        'required': ['fileId'],
      },
    ),
    const McpToolDescriptor(
      name: 'delete_drive_file',
      description:
          'Move a file or folder to the Google Drive trash, or permanently delete it. '
          'By default moves to trash (recoverable). '
          'Set permanently=true to delete forever. '
          'Requires the fileId obtained from search_drive or list_drive_folder.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'fileId': {'type': 'string', 'description': 'The Google Drive file or folder ID to delete.'},
          'permanently': {
            'type': 'boolean',
            'description': 'When true, permanently deletes the file instead of moving it to trash. Default: false.',
            'default': false,
          },
        },
        'required': ['fileId'],
      },
    ),
    McpToolDescriptor(
      name: 'upload_to_drive',
      description:
          'Create or overwrite a plain-text or Markdown file in Google Drive. '
          'Use this to save task results, summaries, or reports to a Drive folder. '
          'Requires the drive.file OAuth scope (re-authorize in Data Sources if needed).',
      inputSchema: const {
        'type': 'object',
        'properties': {
          'fileName': {'type': 'string', 'description': 'Name of the file to create or overwrite (e.g. "report.md" or "summary.txt").'},
          'content': {'type': 'string', 'description': 'Text content to write to the file.'},
          'folderPath': {
            'type': 'string',
            'description': 'Optional Drive folder name or path to upload into. Leave empty for root "My Drive".',
          },
          'mimeType': {
            'type': 'string',
            'description': 'MIME type of the file. Defaults to "text/plain". Use "text/markdown" for .md files.',
            'default': 'text/plain',
          },
        },
        'required': ['fileName', 'content'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    log.info('[Google Drive MCP] executeTool: $toolName');

    switch (toolName) {
      case 'search_drive':
        return _searchDrive(arguments);
      case 'list_drive_folder':
        return _listDriveFolder(arguments);
      case 'read_drive_file':
        return _readDriveFile(arguments);
      case 'delete_drive_file':
        return _deleteDriveFile(arguments);
      case 'upload_to_drive':
        return _uploadToDrive(arguments);
      default:
        return {'error': 'Unknown tool: $toolName'};
    }
  }

  @override
  Future<void> dispose() async {
    // Clean up any cached state
  }

  Future<Map<String, dynamic>> _searchDrive(Map<String, dynamic> args) async {
    final query = (args['query'] as String?)?.trim();
    if (query == null || query.isEmpty) {
      return {'error': 'Parameter "query" is required.'};
    }

    final maxResults = ((args['maxResults'] as int?) ?? 20).clamp(1, 100);
    final recursive = args['recursive'] as bool? ?? true;
    final explicitFolder = (args['folderPath'] as String?)?.trim();
    final folderToSearch = (explicitFolder != null && explicitFolder.isNotEmpty) ? explicitFolder : _folderPath;

    final tokenResult = await _resolveAccessToken();
    if (tokenResult['error'] != null) return tokenResult;
    final token = tokenResult['accessToken'] as String;

    // Resolve the target folder
    final folderId = await _resolveFolderId(token, folderToSearch);
    if (folderId is Map<String, dynamic>) return folderId;

    if (recursive && folderId != null) {
      // Recursive mode: collect all subfolder IDs first, then search across all of them
      log.info('[Google Drive MCP] Recursive search in folder $folderToSearch (id=$folderId)');
      final allFolderIds = await _collectSubfolderIds(token, folderId as String, maxDepth: 10);
      allFolderIds.insert(0, folderId);
      log.info('[Google Drive MCP] Searching across ${allFolderIds.length} folders (incl. subfolders)');

      // Search across all folders using OR clauses for parent IDs
      final allFiles = <Map<String, dynamic>>[];
      // Drive API has query length limits, so batch parent IDs in groups
      const batchSize = 20;
      for (var i = 0; i < allFolderIds.length && allFiles.length < maxResults; i += batchSize) {
        final batch = allFolderIds.sublist(i, (i + batchSize).clamp(0, allFolderIds.length));
        final parentClauses = batch.map((id) => "'$id' in parents").join(' or ');
        final driveQuery = _buildSearchQuery(query, null, parentClause: '($parentClauses)');
        final remaining = maxResults - allFiles.length;
        final response = await _driveGet('/files', token, {
          'q': driveQuery,
          'pageSize': '$remaining',
          'orderBy': 'modifiedTime desc',
          'fields': 'files(id,name,mimeType,size,modifiedTime,webViewLink,iconLink,parents)',
          'supportsAllDrives': 'true',
          'includeItemsFromAllDrives': 'true',
        });
        if (response['error'] != null) {
          log.warning('[Google Drive MCP] Batch search error: ${response['error']}');
          continue;
        }
        final data = response['data'] as Map<String, dynamic>;
        final files = (data['files'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((file) => _mapFileMetadata(file))
            .toList();
        allFiles.addAll(files);
      }

      return {
        'query': query,
        'folderPath': folderToSearch,
        'recursive': true,
        'foldersSearched': allFolderIds.length,
        'returned': allFiles.length,
        'files': allFiles.take(maxResults).toList(),
      };
    }

    // Non-recursive: search only direct children
    final driveQuery = _buildSearchQuery(query, folderId as String?);
    final response = await _driveGet('/files', token, {
      'q': driveQuery,
      'pageSize': '$maxResults',
      'orderBy': 'modifiedTime desc',
      'fields': 'files(id,name,mimeType,size,modifiedTime,webViewLink,iconLink,parents),nextPageToken',
      'supportsAllDrives': 'true',
      'includeItemsFromAllDrives': 'true',
    });
    if (response['error'] != null) return response;

    final data = response['data'] as Map<String, dynamic>;
    final files = (data['files'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((file) => _mapFileMetadata(file))
        .toList();

    return {'query': query, 'returned': files.length, 'files': files, 'nextPageToken': data['nextPageToken']};
  }

  Future<Map<String, dynamic>> _listDriveFolder(Map<String, dynamic> args) async {
    final folderPath = (args['folderPath'] as String?)?.trim() ?? _folderPath;
    final recursive = args['recursive'] as bool? ?? false;
    final maxResults = ((args['maxResults'] as int?) ?? 50).clamp(1, 500);

    final tokenResult = await _resolveAccessToken();
    if (tokenResult['error'] != null) return tokenResult;
    final token = tokenResult['accessToken'] as String;

    final folderId = await _resolveFolderId(token, folderPath);
    if (folderId is Map<String, dynamic>) return folderId;
    final parentId = (folderId as String?) ?? 'root';

    if (recursive) {
      log.info('[Google Drive MCP] Recursive listing of folder $folderPath (id=$parentId)');
      final allFiles = <Map<String, dynamic>>[];
      await _listFolderRecursive(token, parentId, folderPath.isEmpty ? '/' : folderPath, allFiles, maxResults, 0, 10);

      return {
        'folderPath': folderPath.isEmpty ? '/' : folderPath,
        'folderId': parentId,
        'recursive': true,
        'returned': allFiles.length,
        'files': allFiles,
      };
    }

    // Non-recursive: list direct children only
    final driveQuery = "'$parentId' in parents and trashed=false";
    final response = await _driveGet('/files', token, {
      'q': driveQuery,
      'pageSize': '$maxResults',
      'orderBy': 'folder,name',
      'fields': 'files(id,name,mimeType,size,modifiedTime,webViewLink,iconLink,parents),nextPageToken',
      'supportsAllDrives': 'true',
      'includeItemsFromAllDrives': 'true',
    });
    if (response['error'] != null) return response;

    final data = response['data'] as Map<String, dynamic>;
    final files = (data['files'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((file) => _mapFileMetadata(file))
        .toList();

    return {
      'folderPath': folderPath.isEmpty ? '/' : folderPath,
      'folderId': parentId,
      'returned': files.length,
      'files': files,
      'nextPageToken': data['nextPageToken'],
    };
  }

  /// Recursively list all files in a folder and its subfolders.
  Future<void> _listFolderRecursive(
    String token,
    String folderId,
    String currentPath,
    List<Map<String, dynamic>> allFiles,
    int maxResults,
    int depth,
    int maxDepth,
  ) async {
    if (depth > maxDepth || allFiles.length >= maxResults) return;

    final driveQuery = "'$folderId' in parents and trashed=false";
    final remaining = maxResults - allFiles.length;
    final response = await _driveGet('/files', token, {
      'q': driveQuery,
      'pageSize': '${remaining.clamp(1, 200)}',
      'orderBy': 'folder,name',
      'fields': 'files(id,name,mimeType,size,modifiedTime,webViewLink,iconLink,parents)',
      'supportsAllDrives': 'true',
      'includeItemsFromAllDrives': 'true',
    });
    if (response['error'] != null) {
      log.warning('[Google Drive MCP] Error listing $currentPath: ${response['error']}');
      return;
    }

    final data = response['data'] as Map<String, dynamic>;
    final files = (data['files'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>().toList();

    final subfolders = <Map<String, dynamic>>[];
    for (final file in files) {
      if (allFiles.length >= maxResults) break;
      final mapped = _mapFileMetadata(file);
      mapped['path'] = '$currentPath/${file['name'] ?? ''}';
      if (mapped['isFolder'] == true) {
        subfolders.add(file);
      }
      allFiles.add(mapped);
    }

    // Recurse into subfolders
    for (final subfolder in subfolders) {
      if (allFiles.length >= maxResults) break;
      final subId = subfolder['id']?.toString() ?? '';
      final subName = subfolder['name']?.toString() ?? '';
      if (subId.isNotEmpty) {
        await _listFolderRecursive(token, subId, '$currentPath/$subName', allFiles, maxResults, depth + 1, maxDepth);
      }
    }
  }

  /// Collect all subfolder IDs recursively under a given parent folder.
  Future<List<String>> _collectSubfolderIds(String token, String parentId, {int maxDepth = 10}) async {
    final result = <String>[];
    await _collectSubfolderIdsRecursive(token, parentId, result, 0, maxDepth);
    return result;
  }

  Future<void> _collectSubfolderIdsRecursive(String token, String parentId, List<String> result, int depth, int maxDepth) async {
    if (depth > maxDepth || result.length > 200) return;

    final q = "'$parentId' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false";
    final response = await _driveGet('/files', token, {
      'q': q,
      'pageSize': '100',
      'fields': 'files(id,name)',
      'supportsAllDrives': 'true',
      'includeItemsFromAllDrives': 'true',
    });
    if (response['error'] != null) return;

    final data = response['data'] as Map<String, dynamic>;
    final folders = (data['files'] as List<dynamic>? ?? const []).whereType<Map<String, dynamic>>().toList();

    for (final folder in folders) {
      final id = folder['id']?.toString() ?? '';
      if (id.isNotEmpty) {
        result.add(id);
        await _collectSubfolderIdsRecursive(token, id, result, depth + 1, maxDepth);
      }
    }
  }

  Future<Map<String, dynamic>> _readDriveFile(Map<String, dynamic> args) async {
    final fileId = (args['fileId'] as String?)?.trim();
    if (fileId == null || fileId.isEmpty) {
      return {'error': 'Parameter "fileId" is required.'};
    }

    final tokenResult = await _resolveAccessToken();
    if (tokenResult['error'] != null) return tokenResult;
    final token = tokenResult['accessToken'] as String;

    final metadataResp = await _driveGet('/files/$fileId', token, {
      'fields': 'id,name,mimeType,size,modifiedTime,webViewLink,iconLink',
      'supportsAllDrives': 'true',
    });
    if (metadataResp['error'] != null) return metadataResp;

    final metadata = metadataResp['data'] as Map<String, dynamic>;
    final mimeType = (metadata['mimeType'] ?? '').toString();
    final fileName = (metadata['name'] ?? '').toString();

    String contentText = '';

    if (mimeType.startsWith('application/vnd.google-apps')) {
      contentText = await _exportGoogleWorkspaceFile(token, fileId, mimeType);
    } else {
      contentText = await _downloadFileAsText(token, fileId);
    }

    if (contentText.trim().isEmpty) {
      return {
        'id': metadata['id'],
        'name': fileName,
        'mimeType': mimeType,
        'size': metadata['size'],
        'modifiedTime': metadata['modifiedTime'],
        'webViewLink': metadata['webViewLink'],
        'error':
            'Could not extract readable text from this file type. '
            'Try a text/Docs/Sheets/CSV file or open via webViewLink.',
      };
    }

    final normalized = contentText.replaceAll('\r\n', '\n').trim();
    final snippet = normalized.length > 800 ? '${normalized.substring(0, 800)}…' : normalized;

    return {
      'id': metadata['id'],
      'name': fileName,
      'mimeType': mimeType,
      'size': metadata['size'],
      'modifiedTime': metadata['modifiedTime'],
      'webViewLink': metadata['webViewLink'],
      'snippet': snippet,
      'content': normalized,
    };
  }

  Future<Map<String, dynamic>> _resolveAccessToken() async {
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isLoaded) {
      await ds.load();
    }

    if (!ds.isGoogleDriveConfigured) {
      return {'error': 'Google Drive is not enabled/configured in Data Sources.'};
    }

    if (ds.isGmailAccessTokenExpired) {
      final refresh = await ds.refreshGmailAccessToken();
      if (refresh['success'] != true) {
        return {'error': 'Google token refresh failed: ${refresh['error'] ?? 'unknown error'}'};
      }
    }

    final token = ds.gmailAccessToken.trim();
    if (token.isEmpty) {
      return {'error': 'No Google OAuth access token available.'};
    }
    return {'accessToken': token};
  }

  /// Lists immediate subfolder names directly under [parentPath].
  ///
  /// [parentPath] may be empty / null (= Drive root), a slash-separated
  /// virtual path like "MyFolder/SubFolder", or a raw Drive folder ID.
  ///
  /// Returns `{'folders': List<String>}` on success or `{'error': String}`.
  static Future<Map<String, dynamic>> listSubfolders(String? parentPath) async {
    const driveBase = 'https://www.googleapis.com/drive/v3';

    // --- Auth ---
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isLoaded) await ds.load();
    if (!ds.isGoogleDriveConfigured) {
      return {'error': 'Google Drive not configured in Data Sources'};
    }
    if (ds.isGmailAccessTokenExpired) {
      final r = await ds.refreshGmailAccessToken();
      if (r['success'] != true) return {'error': 'Token refresh failed'};
    }
    final token = ds.gmailAccessToken.trim();
    if (token.isEmpty) {
      return {'error': 'No OAuth token – please authorise Google in Data Sources'};
    }

    // --- Local HTTP helper ---
    Future<Map<String, dynamic>> get(String path, Map<String, String> q) async {
      final uri = Uri.parse('$driveBase$path').replace(queryParameters: q);
      final r = await http.get(uri, headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'});
      if (r.statusCode != 200) return {'error': 'Drive API ${r.statusCode}'};
      return jsonDecode(r.body) as Map<String, dynamic>;
    }

    // --- Resolve parent folder ID ---
    String parentId = 'root';
    final normalised = (parentPath ?? '').trim();
    if (normalised.isNotEmpty && normalised != '/' && normalised.toLowerCase() != 'root') {
      final parts = normalised.split(RegExp(r'[\\/]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      String cur = 'root';
      for (final seg in parts) {
        final escaped = seg.replaceAll("'", "\\'");
        final data = await get('/files', {
          'q':
              "name='$escaped' and mimeType='application/vnd.google-apps.folder'"
              " and '$cur' in parents and trashed=false",
          'pageSize': '5',
          'fields': 'files(id)',
        });
        if (data['error'] != null) return data;
        final files = (data['files'] as List?) ?? [];
        if (files.isEmpty) return {'error': 'Folder not found: $seg'};
        cur = (files.first as Map<String, dynamic>)['id'] as String;
      }
      parentId = cur;
    }

    // --- List immediate subfolders ---
    final data = await get('/files', {
      'q':
          "'$parentId' in parents"
          " and mimeType='application/vnd.google-apps.folder' and trashed=false",
      'pageSize': '200',
      'fields': 'files(name)',
      'orderBy': 'name',
    });
    if (data['error'] != null) return data;
    final folders = (data['files'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((f) => f['name']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
    return {'folders': folders};
  }

  Future<dynamic> _resolveFolderId(String token, String? folderPath) async {
    final raw = (folderPath ?? '').trim();
    if (raw.isEmpty || raw == '/' || raw.toLowerCase() == 'root') {
      return null;
    }

    // Support explicit id forms: "id:abc123" or plain ID
    if (raw.startsWith('id:')) {
      return raw.substring(3).trim();
    }
    if (!raw.contains('/') && !raw.contains('\\') && RegExp(r'^[A-Za-z0-9_-]{10,}$').hasMatch(raw)) {
      return raw;
    }

    final parts = raw.split(RegExp(r'[\\/]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return null;

    String currentParent = 'root';
    for (final segment in parts) {
      // First try exact name match
      var q =
          "name='${_escQuery(segment)}' and mimeType='application/vnd.google-apps.folder' and '$currentParent' in parents and trashed=false";
      var response = await _driveGet('/files', token, {
        'q': q,
        'pageSize': '10',
        'fields': 'files(id,name)',
        'supportsAllDrives': 'true',
        'includeItemsFromAllDrives': 'true',
      });
      if (response['error'] != null) return response;
      var files = (response['data'] as Map<String, dynamic>)['files'] as List<dynamic>? ?? const [];

      // If exact match fails, try case-insensitive match using name contains
      if (files.isEmpty) {
        log.info('[Google Drive MCP] Exact folder match failed for "$segment", trying case-insensitive search');
        q = "name contains '${_escQuery(segment)}' and mimeType='application/vnd.google-apps.folder' and '$currentParent' in parents and trashed=false";
        response = await _driveGet('/files', token, {
          'q': q,
          'pageSize': '10',
          'fields': 'files(id,name)',
          'supportsAllDrives': 'true',
          'includeItemsFromAllDrives': 'true',
        });
        if (response['error'] != null) return response;
        files = (response['data'] as Map<String, dynamic>)['files'] as List<dynamic>? ?? const [];

        // Filter for case-insensitive exact match from the contains results
        if (files.isNotEmpty) {
          final exactMatch = files
              .whereType<Map<String, dynamic>>()
              .where((f) => (f['name']?.toString() ?? '').toLowerCase() == segment.toLowerCase())
              .toList();
          if (exactMatch.isNotEmpty) {
            files = exactMatch;
          }
          // If no exact case-insensitive match, use the first contains result
        }
      }

      if (files.isEmpty) {
        return {'error': 'Google Drive folder not found: "$segment" in path "$raw". Check the folder name and spelling.'};
      }
      final matchedName = (files.first as Map<String, dynamic>)['name']?.toString() ?? segment;
      if (matchedName.toLowerCase() != segment.toLowerCase()) {
        log.info('[Google Drive MCP] Fuzzy matched folder "$segment" -> "$matchedName"');
      }
      currentParent = (files.first as Map<String, dynamic>)['id']?.toString() ?? '';
      if (currentParent.isEmpty) {
        return {'error': 'Could not resolve folder path: $raw'};
      }
    }

    return currentParent;
  }

  String _buildSearchQuery(String query, String? folderId, {String? parentClause}) {
    final clauses = <String>['trashed=false'];

    // Use explicit parentClause (for recursive multi-folder search) or single folderId
    if (parentClause != null && parentClause.isNotEmpty) {
      clauses.add(parentClause);
    } else if (folderId != null && folderId.isNotEmpty) {
      clauses.add("'$folderId' in parents");
    }

    final qEscaped = _escQuery(query);
    clauses.add("(name contains '$qEscaped' or fullText contains '$qEscaped')");

    final typeClauses = _fileTypes
        .where((e) => e.isNotEmpty)
        .map((ext) => "name contains '.${_escQuery(ext.startsWith('.') ? ext.substring(1) : ext)}'")
        .toList();
    if (typeClauses.isNotEmpty) {
      clauses.add('(${typeClauses.join(' or ')})');
    }

    log.info('[Google Drive MCP] Search query: ${clauses.join(' and ')}');
    return clauses.join(' and ');
  }

  Map<String, dynamic> _mapFileMetadata(Map<String, dynamic> file) {
    return {
      'id': file['id'],
      'name': file['name'],
      'mimeType': file['mimeType'],
      'size': file['size'],
      'modifiedTime': file['modifiedTime'],
      'webViewLink': file['webViewLink'],
      'iconLink': file['iconLink'],
      'isFolder': (file['mimeType']?.toString() ?? '') == 'application/vnd.google-apps.folder',
    };
  }

  Future<Map<String, dynamic>> _driveGet(String path, String token, [Map<String, String>? queryParameters]) async {
    try {
      final uri = Uri.parse('$_driveBaseUrl$path').replace(queryParameters: queryParameters);
      var response = await http.get(uri, headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'});

      // Auto-refresh on 401 and retry once
      if (response.statusCode == 401) {
        log.info('[Google Drive MCP] 401 received — attempting token refresh');
        final ds = DataSourcesSettingsService.instance;
        if (ds.gmailRefreshToken.trim().isNotEmpty) {
          final refreshResult = await ds.refreshGmailAccessToken();
          if (refreshResult['success'] == true) {
            final newToken = ds.gmailAccessToken.trim();
            if (newToken.isNotEmpty) {
              log.info('[Google Drive MCP] Token refreshed — retrying request');
              response = await http.get(uri, headers: {'Authorization': 'Bearer $newToken', 'Accept': 'application/json'});
            }
          } else {
            log.warning('[Google Drive MCP] Token refresh failed: ${refreshResult['error']}');
          }
        }
      }

      final bodyText = utf8.decode(response.bodyBytes, allowMalformed: true);
      final payload = bodyText.isNotEmpty ? jsonDecode(bodyText) : null;

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return {'data': payload is Map<String, dynamic> ? payload : <String, dynamic>{}};
      }

      final errorMessage = payload is Map<String, dynamic>
          ? (payload['error'] is Map<String, dynamic>
                ? ((payload['error'] as Map<String, dynamic>)['message']?.toString() ?? response.reasonPhrase)
                : payload['error']?.toString())
          : response.reasonPhrase;

      return {'error': 'Google Drive API error ${response.statusCode}: ${errorMessage ?? 'unknown error'}'};
    } catch (e) {
      return {'error': 'Google Drive request failed: $e'};
    }
  }

  Future<String> _exportGoogleWorkspaceFile(String token, String fileId, String mimeType) async {
    String exportMime = 'text/plain';
    if (mimeType == 'application/vnd.google-apps.spreadsheet') {
      exportMime = 'text/csv';
    }

    final uri = Uri.parse('$_driveBaseUrl/files/$fileId/export').replace(queryParameters: {'mimeType': exportMime});
    try {
      var response = await http.get(uri, headers: {'Authorization': 'Bearer $token'});

      // Auto-refresh on 401
      if (response.statusCode == 401) {
        final ds = DataSourcesSettingsService.instance;
        if (ds.gmailRefreshToken.trim().isNotEmpty) {
          final refreshResult = await ds.refreshGmailAccessToken();
          if (refreshResult['success'] == true) {
            final newToken = ds.gmailAccessToken.trim();
            if (newToken.isNotEmpty) {
              response = await http.get(uri, headers: {'Authorization': 'Bearer $newToken'});
            }
          }
        }
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return '';
      }
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  Future<String> _downloadFileAsText(String token, String fileId) async {
    final uri = Uri.parse('$_driveBaseUrl/files/$fileId').replace(queryParameters: {'alt': 'media'});
    try {
      var response = await http.get(uri, headers: {'Authorization': 'Bearer $token'});

      // Auto-refresh on 401
      if (response.statusCode == 401) {
        final ds = DataSourcesSettingsService.instance;
        if (ds.gmailRefreshToken.trim().isNotEmpty) {
          final refreshResult = await ds.refreshGmailAccessToken();
          if (refreshResult['success'] == true) {
            final newToken = ds.gmailAccessToken.trim();
            if (newToken.isNotEmpty) {
              response = await http.get(uri, headers: {'Authorization': 'Bearer $newToken'});
            }
          }
        }
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return '';
      }
      final text = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (_looksBinary(text)) {
        return '';
      }
      return text;
    } catch (_) {
      return '';
    }
  }

  bool _looksBinary(String text) {
    if (text.isEmpty) return false;
    final sample = text.length > 1000 ? text.substring(0, 1000) : text;
    int controlChars = 0;
    for (final unit in sample.codeUnits) {
      if (unit == 9 || unit == 10 || unit == 13) continue;
      if (unit < 32) controlChars++;
    }
    return controlChars > sample.length * 0.05;
  }

  String _escQuery(String value) => value.replaceAll("'", r"\'");

  // ─── Delete ─────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _deleteDriveFile(Map<String, dynamic> args) async {
    final fileId = (args['fileId'] as String?)?.trim();
    if (fileId == null || fileId.isEmpty) {
      return {'error': 'Parameter "fileId" is required.'};
    }
    final permanently = args['permanently'] as bool? ?? false;

    final tokenResult = await _resolveAccessToken();
    if (tokenResult['error'] != null) return tokenResult;
    var token = tokenResult['accessToken'] as String;

    Future<http.Response> doRequest() async {
      if (permanently) {
        final uri = Uri.parse('$_driveBaseUrl/files/$fileId?supportsAllDrives=true');
        return http.delete(uri, headers: {'Authorization': 'Bearer $token'});
      } else {
        final uri = Uri.parse('$_driveBaseUrl/files/$fileId?supportsAllDrives=true');
        return http.patch(
          uri,
          headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
          body: json.encode({'trashed': true}),
        );
      }
    }

    var response = await doRequest();

    // Auto-refresh on 401 and retry once
    if (response.statusCode == 401) {
      final ds = DataSourcesSettingsService.instance;
      if (ds.gmailRefreshToken.trim().isNotEmpty) {
        final refreshResult = await ds.refreshGmailAccessToken();
        if (refreshResult['success'] == true) {
          final newToken = ds.gmailAccessToken.trim();
          if (newToken.isNotEmpty) {
            token = newToken;
            response = await doRequest();
          }
        }
      }
    }

    if (permanently) {
      // 204 No Content = success for permanent delete
      if (response.statusCode == 204) {
        log.info('[Google Drive MCP] Permanently deleted file $fileId');
        return {'success': true, 'action': 'deleted_permanently', 'fileId': fileId};
      }
    } else {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        log.info('[Google Drive MCP] Moved file $fileId to trash');
        return {'success': true, 'action': 'trashed', 'fileId': fileId};
      }
    }

    final bodyText = utf8.decode(response.bodyBytes, allowMalformed: true);
    Map<String, dynamic>? payload;
    try {
      payload = bodyText.isNotEmpty ? jsonDecode(bodyText) as Map<String, dynamic>? : null;
    } catch (_) {}
    final errorMessage = payload?['error'] is Map<String, dynamic>
        ? (payload!['error'] as Map<String, dynamic>)['message']?.toString()
        : payload?['error']?.toString();
    return {'error': 'Google Drive delete failed (${response.statusCode}): ${errorMessage ?? response.reasonPhrase ?? bodyText}'};
  }

  // ─── Upload ─────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _uploadToDrive(Map<String, dynamic> args) async {
    final fileName = (args['fileName'] as String?)?.trim();
    if (fileName == null || fileName.isEmpty) {
      return {'error': 'Parameter "fileName" is required.'};
    }
    final content = (args['content'] as String?) ?? '';
    final mimeType = ((args['mimeType'] as String?)?.trim().isNotEmpty == true ? args['mimeType'] as String : null) ?? 'text/plain';
    final folderPath = ((args['folderPath'] as String?)?.trim() ?? _folderPath).trim();

    final ds = DataSourcesSettingsService.instance;
    var token = ds.gmailAccessToken.trim();
    if (token.isEmpty) {
      return {'error': 'Google Drive not authorized. Re-connect in Data Sources settings.'};
    }

    // Refresh token if expired
    if (ds.isGmailAccessTokenExpired) {
      final r = await ds.refreshGmailAccessToken();
      if (r['success'] == true) token = ds.gmailAccessToken.trim();
    }

    // Resolve folder ID
    String? folderId;
    if (folderPath.isNotEmpty) {
      folderId = await _resolveOrCreateFolderPath(token, folderPath);
    }

    // Check if a file with the same name already exists → overwrite
    final existingId = await _findFileByName(token, fileName, parentId: folderId);

    try {
      if (existingId != null) {
        // PATCH (update content only)
        final patchUri = Uri.parse('https://www.googleapis.com/upload/drive/v3/files/$existingId?uploadType=media');
        final patchRes = await http.patch(
          patchUri,
          headers: {'Authorization': 'Bearer $token', 'Content-Type': mimeType},
          body: utf8.encode(content),
        );
        if (patchRes.statusCode < 200 || patchRes.statusCode >= 300) {
          return {'error': 'Upload failed (${patchRes.statusCode}): ${patchRes.body}'};
        }
        final meta = json.decode(patchRes.body) as Map<String, dynamic>;
        log.info('[Drive MCP] Overwrote file "$fileName" (id=${meta['id']})');
        return {
          'success': true,
          'action': 'updated',
          'fileId': meta['id'],
          'fileName': fileName,
          'webViewLink': 'https://drive.google.com/file/d/${meta['id']}/view',
        };
      } else {
        // Multipart upload (metadata + content)
        final metadata = <String, dynamic>{
          'name': fileName,
          'mimeType': mimeType,
          if (folderId != null) 'parents': [folderId],
        };
        final boundary = '-------multipart_boundary_tealkit';
        final body = StringBuffer();
        body.write('--$boundary\r\n');
        body.write('Content-Type: application/json; charset=UTF-8\r\n\r\n');
        body.write(json.encode(metadata));
        body.write('\r\n--$boundary\r\n');
        body.write('Content-Type: $mimeType\r\n\r\n');
        body.write(content);
        body.write('\r\n--$boundary--');

        final uploadUri = Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart');
        final res = await http.post(
          uploadUri,
          headers: {'Authorization': 'Bearer $token', 'Content-Type': 'multipart/related; boundary=$boundary'},
          body: utf8.encode(body.toString()),
        );
        if (res.statusCode < 200 || res.statusCode >= 300) {
          return {'error': 'Upload failed (${res.statusCode}): ${res.body}'};
        }
        final meta = json.decode(res.body) as Map<String, dynamic>;
        log.info('[Drive MCP] Created file "$fileName" (id=${meta['id']})');
        return {
          'success': true,
          'action': 'created',
          'fileId': meta['id'],
          'fileName': fileName,
          'webViewLink': 'https://drive.google.com/file/d/${meta['id']}/view',
        };
      }
    } catch (e) {
      return {'error': 'Upload error: $e'};
    }
  }

  /// Finds a file by name in the given parent folder (or root if parentId is null).
  Future<String?> _findFileByName(String token, String name, {String? parentId}) async {
    var q = "name='${_escQuery(name)}' and trashed=false";
    if (parentId != null) q += " and '$parentId' in parents";
    try {
      final uri = Uri.parse('$_driveBaseUrl/files').replace(queryParameters: {'q': q, 'fields': 'files(id)', 'pageSize': '1'});
      final res = await http.get(uri, headers: {'Authorization': 'Bearer $token'});
      if (res.statusCode != 200) return null;
      final files = (json.decode(res.body)['files'] as List<dynamic>?) ?? [];
      return files.isNotEmpty ? files.first['id'] as String? : null;
    } catch (_) {
      return null;
    }
  }

  /// Resolves (or creates) a folder hierarchy like "Reports/2026" and returns the final folder ID.
  Future<String?> _resolveOrCreateFolderPath(String token, String path) async {
    final parts = path.split('/').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    String? parentId;
    for (final part in parts) {
      parentId = await _findOrCreateFolder(token, part, parentId: parentId);
      if (parentId == null) return null;
    }
    return parentId;
  }

  /// Finds an existing folder by name, or creates it if it doesn't exist.
  Future<String?> _findOrCreateFolder(String token, String name, {String? parentId}) async {
    var q = "name='${_escQuery(name)}' and mimeType='application/vnd.google-apps.folder' and trashed=false";
    if (parentId != null) q += " and '$parentId' in parents";
    try {
      final searchUri = Uri.parse('$_driveBaseUrl/files').replace(queryParameters: {'q': q, 'fields': 'files(id)', 'pageSize': '1'});
      final searchRes = await http.get(searchUri, headers: {'Authorization': 'Bearer $token'});
      if (searchRes.statusCode == 200) {
        final files = (json.decode(searchRes.body)['files'] as List<dynamic>?) ?? [];
        if (files.isNotEmpty) return files.first['id'] as String?;
      }

      // Create folder
      final meta = <String, dynamic>{
        'name': name,
        'mimeType': 'application/vnd.google-apps.folder',
        if (parentId != null) 'parents': [parentId],
      };
      final createRes = await http.post(
        Uri.parse('$_driveBaseUrl/files'),
        headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
        body: json.encode(meta),
      );
      if (createRes.statusCode < 200 || createRes.statusCode >= 300) return null;
      return (json.decode(createRes.body) as Map<String, dynamic>)['id'] as String?;
    } catch (_) {
      return null;
    }
  }
}
