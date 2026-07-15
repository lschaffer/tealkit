import '../../services/app_logger.dart';
import '../../services/data_sources_settings_service.dart';
import '../internal_mcp_server.dart';

/// Internal MCP server for searching and reading files from Microsoft OneDrive.
///
/// Uses the Microsoft Graph API with OAuth2 (PKCE) credentials from the global
/// [DataSourcesSettingsService]. Provides:
///   • Search files by name or content
///   • List files in a folder
///   • Read file content (text extraction)
///
/// The Application (client) ID and Tenant ID must be configured in the global
/// Data Sources settings. The Entra ID app registration must have the
/// Files.Read.All delegated permission and support PKCE auth flow.
///
/// Init parameters:
///   • folderPath: Optional folder path to restrict search (e.g. "Documents")
///   • fileTypes:  Comma-separated extensions to filter
class OneDriveMcpServer extends InternalMcpServer {
  String _folderPath = '';
  List<String> _fileTypes = [];

  @override
  String get type => 'onedrive';

  @override
  String get displayName => 'OneDrive';

  @override
  String get description =>
      'Search and read files from Microsoft OneDrive. '
      'Uses Microsoft Graph API with OAuth2 credentials configured in Data Sources settings.';

  @override
  String get iconName => 'cloud';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'folderPath': {
        'type': 'string',
        'description':
            'Optional folder path to restrict search scope '
            '(e.g. "Documents/Reports"). Leave empty to search all files.',
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
      'OneDrive tools: use search_onedrive to find files, list_onedrive_folder to '
      'browse folders, and read_onedrive_file for file content. Return file names '
      'and relevant excerpts.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    _folderPath = (initParams['folderPath'] as String? ?? '').trim();
    final fileTypesStr = initParams['fileTypes'] as String? ?? 'txt,md,docx,xlsx,pdf,csv';
    _fileTypes = fileTypesStr.split(',').map((e) => e.trim().toLowerCase()).where((e) => e.isNotEmpty).toList();

    log.info('[OneDrive MCP] Initializing – folder="$_folderPath", fileTypes=${_fileTypes.join(",")}');

    // Validate that OneDrive credentials are configured globally
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isOneDriveConfigured) {
      log.warning('[OneDrive MCP] OneDrive not configured in Data Sources settings');
    }
  }

  @override
  String? validateInitParams(Map<String, dynamic> params) {
    final ds = DataSourcesSettingsService.instance;
    if (!ds.isOneDriveConfigured) {
      return 'OneDrive credentials not configured. Go to Data Sources on the start screen.';
    }
    return null;
  }

  @override
  List<McpToolDescriptor> get tools => [
    const McpToolDescriptor(
      name: 'search_onedrive',
      description:
          'Search for files in OneDrive by name or content. '
          'Returns a list of matching files with their IDs, names, and types.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Search query text. Searches file names and content.'},
          'maxResults': {'type': 'integer', 'description': 'Maximum number of results to return (default: 10, max: 50).', 'default': 10},
        },
        'required': ['query'],
      },
    ),
    const McpToolDescriptor(
      name: 'list_onedrive_folder',
      description: 'List files in a specific OneDrive folder. Returns file names, types, and sizes.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'folderPath': {'type': 'string', 'description': 'Folder path relative to root (e.g. "Documents/Reports"). Empty for root.'},
          'maxResults': {'type': 'integer', 'description': 'Maximum number of results (default: 20).', 'default': 20},
        },
        'required': [],
      },
    ),
    const McpToolDescriptor(
      name: 'read_onedrive_file',
      description:
          'Read the text content of a file from OneDrive. '
          'Supports Word, Excel, PDF, TXT, MD, CSV, and other text-based formats.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'fileId': {'type': 'string', 'description': 'The OneDrive item ID (obtained from search_onedrive or list_onedrive_folder).'},
        },
        'required': ['fileId'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(String toolName, Map<String, dynamic> arguments) async {
    // TODO: Implement Microsoft Graph API calls
    // Will use oauth2 + http package to call Graph API endpoints:
    //   Search: GET /me/drive/root/search(q='{query}')
    //   List:   GET /me/drive/root:/{path}:/children
    //   Read:   GET /me/drive/items/{id}/content
    log.info('[OneDrive MCP] executeTool: $toolName');

    return {
      'error':
          'OneDrive integration is not yet implemented. '
          'This is a planned feature that will use the Microsoft Graph API to search and read files.',
    };
  }

  @override
  Future<void> dispose() async {
    // Clean up any cached state
  }
}
