import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../services/app_logger.dart';
import '../../services/data_sources_settings_service.dart';
import '../internal_mcp_server.dart';

/// Pure-Dart built-in MCP server mimicking the official GitHub MCP Server
/// (`@modelcontextprotocol/server-github`) via GitHub REST API v3.
///
/// Works in Local Mode (Android, iOS, Windows, macOS, Linux) and Server Mode
/// without requiring Node.js, Docker, or external stdio subprocesses.
///
/// Token resolution:
///   1. Task/init param `githubToken`
///   2. Locally saved token in [DataSourcesSettingsService.instance.githubToken]
class GithubApiMcpServer extends InternalMcpServer {
  static const String _apiBase = 'https://api.github.com';

  String _token = '';
  String _defaultOwner = '';

  @override
  String get type => 'github';

  @override
  String get displayName => 'GitHub (Built-in API)';

  @override
  String get description =>
      'Pure-Dart GitHub integration via REST API: search & browse repositories, '
      'read/write files, manage branches, commits, issues, and pull requests.';

  @override
  String get iconName => 'code';

  @override
  Map<String, dynamic> get initParamSchema => {
    'type': 'object',
    'properties': {
      'githubToken': {
        'type': 'string',
        'description':
            'GitHub Personal Access Token (ghp_... or github_pat_...). '
            'Optional if configured in Data Sources settings.',
        'sensitive': true,
      },
      'defaultOwner': {
        'type': 'string',
        'description':
            'Optional default GitHub username or organization when owner is omitted.',
      },
    },
    'required': [],
  };

  @override
  Map<String, dynamic> get defaultInitParams => const {
    'githubToken': '',
    'defaultOwner': '',
  };

  @override
  String get defaultSystemPrompt =>
      'You have access to built-in GitHub REST API tools (github_*).\n'
      'USAGE RULES:\n'
      '1. Use github_get_me to identify the authenticated GitHub user.\n'
      '2. Use github_list_repositories or github_search_repositories to find repos.\n'
      '3. Use github_get_file_contents to inspect files or list directory contents.\n'
      '4. When updating an existing file with github_create_or_update_file, first read its '
      '   current `sha` via github_get_file_contents and pass it in `sha`.\n'
      '5. Use github_list_issues, github_get_issue, github_create_issue, github_add_issue_comment '
      '   and github_list_pull_requests / github_get_pull_request / github_create_pull_request '
      '   for issue and PR workflows.\n'
      '6. Never expose the GitHub API token in your responses.';

  @override
  Future<void> initialize(Map<String, dynamic> initParams) async {
    _token = (initParams['githubToken'] as String? ?? '').trim();
    _defaultOwner = (initParams['defaultOwner'] as String? ?? '').trim();
    await _ensureTokenLoaded();
    log.info(
      '[GitHub MCP] Initialized (hasToken=${_token.isNotEmpty}, defaultOwner=$_defaultOwner)',
    );
  }

  Future<void> _ensureTokenLoaded() async {
    final svc = DataSourcesSettingsService.instance;
    if (!svc.isLoaded) await svc.load();
    if (_token.isEmpty) _token = svc.githubToken.trim();
    if (_defaultOwner.isEmpty) _defaultOwner = svc.githubDefaultOwner.trim();
  }

  Map<String, String> _headers() => {
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'TealKit-GitHub-MCP/1.0',
    if (_token.isNotEmpty) 'Authorization': 'Bearer $_token',
    'Content-Type': 'application/json',
  };

  String _resolveOwner(Map<String, dynamic> args) {
    final owner = (args['owner'] as String? ?? '').trim();
    if (owner.isNotEmpty) return owner;
    return _defaultOwner;
  }

  @override
  List<McpToolDescriptor> get tools => const [
    McpToolDescriptor(
      name: 'github_get_me',
      description: 'Get details of the currently authenticated GitHub user.',
      inputSchema: {'type': 'object', 'properties': {}, 'required': []},
    ),
    McpToolDescriptor(
      name: 'github_list_repositories',
      description:
          'List repositories for the authenticated user or a specific username/organization.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'owner': {
            'type': 'string',
            'description':
                'Optional GitHub username or org. If omitted, lists repositories for the authenticated user.',
          },
          'sort': {
            'type': 'string',
            'enum': ['created', 'updated', 'pushed', 'full_name'],
            'default': 'updated',
          },
          'per_page': {'type': 'integer', 'default': 20},
        },
        'required': [],
      },
    ),
    McpToolDescriptor(
      name: 'github_search_repositories',
      description: 'Search GitHub repositories by query string.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'GitHub repository search query (e.g. "flutter mcp language:dart").',
          },
          'per_page': {'type': 'integer', 'default': 15},
        },
        'required': ['query'],
      },
    ),
    McpToolDescriptor(
      name: 'github_get_file_contents',
      description:
          'Get the contents of a file (decoded UTF-8 text + sha) or list entries of a directory in a GitHub repository.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'owner': {'type': 'string', 'description': 'Repository owner (user or org).'},
          'repo': {'type': 'string', 'description': 'Repository name.'},
          'path': {
            'type': 'string',
            'default': '',
            'description': 'Path to file or directory (empty for repository root).',
          },
          'ref': {
            'type': 'string',
            'description': 'Optional branch, tag, or commit SHA.',
          },
        },
        'required': ['repo'],
      },
    ),
    McpToolDescriptor(
      name: 'github_create_or_update_file',
      description:
          'Create a new file or update an existing file in a GitHub repository (requires write token).',
      inputSchema: {
        'type': 'object',
        'properties': {
          'owner': {'type': 'string', 'description': 'Repository owner.'},
          'repo': {'type': 'string', 'description': 'Repository name.'},
          'path': {'type': 'string', 'description': 'File path within the repository.'},
          'content': {'type': 'string', 'description': 'Full UTF-8 text content of the file.'},
          'message': {'type': 'string', 'description': 'Git commit message.'},
          'branch': {'type': 'string', 'description': 'Target branch (defaults to repo default branch).'},
          'sha': {
            'type': 'string',
            'description': 'Blob SHA of the file being replaced (required when updating an existing file).',
          },
        },
        'required': ['repo', 'path', 'content', 'message'],
      },
    ),
    McpToolDescriptor(
      name: 'github_list_branches',
      description: 'List branches in a GitHub repository.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'owner': {'type': 'string', 'description': 'Repository owner.'},
          'repo': {'type': 'string', 'description': 'Repository name.'},
          'per_page': {'type': 'integer', 'default': 30},
        },
        'required': ['repo'],
      },
    ),
    McpToolDescriptor(
      name: 'github_create_branch',
      description: 'Create a new branch in a GitHub repository from a base branch or commit SHA.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'owner': {'type': 'string', 'description': 'Repository owner.'},
          'repo': {'type': 'string', 'description': 'Repository name.'},
          'branch': {'type': 'string', 'description': 'New branch name.'},
          'from_branch': {
            'type': 'string',
            'description': 'Source branch name (defaults to repository default branch).',
          },
        },
        'required': ['repo', 'branch'],
      },
    ),
    McpToolDescriptor(
      name: 'github_list_commits',
      description: 'List recent commits in a GitHub repository.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'owner': {'type': 'string', 'description': 'Repository owner.'},
          'repo': {'type': 'string', 'description': 'Repository name.'},
          'sha': {'type': 'string', 'description': 'Optional branch name or commit SHA.'},
          'path': {'type': 'string', 'description': 'Optional file path filter.'},
          'per_page': {'type': 'integer', 'default': 15},
        },
        'required': ['repo'],
      },
    ),
    McpToolDescriptor(
      name: 'github_list_issues',
      description: 'List issues in a GitHub repository.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'owner': {'type': 'string', 'description': 'Repository owner.'},
          'repo': {'type': 'string', 'description': 'Repository name.'},
          'state': {
            'type': 'string',
            'enum': ['open', 'closed', 'all'],
            'default': 'open',
          },
          'labels': {'type': 'string', 'description': 'Comma-separated label names.'},
          'per_page': {'type': 'integer', 'default': 20},
        },
        'required': ['repo'],
      },
    ),
    McpToolDescriptor(
      name: 'github_get_issue',
      description: 'Get full details and recent comments for a GitHub issue.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'owner': {'type': 'string', 'description': 'Repository owner.'},
          'repo': {'type': 'string', 'description': 'Repository name.'},
          'issue_number': {'type': 'integer', 'description': 'Issue number.'},
        },
        'required': ['repo', 'issue_number'],
      },
    ),
    McpToolDescriptor(
      name: 'github_create_issue',
      description: 'Create a new issue in a GitHub repository.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'owner': {'type': 'string', 'description': 'Repository owner.'},
          'repo': {'type': 'string', 'description': 'Repository name.'},
          'title': {'type': 'string', 'description': 'Issue title.'},
          'body': {'type': 'string', 'description': 'Issue description (Markdown).'},
          'labels': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Optional list of label names.',
          },
        },
        'required': ['repo', 'title'],
      },
    ),
    McpToolDescriptor(
      name: 'github_add_issue_comment',
      description: 'Add a comment to a GitHub issue or pull request.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'owner': {'type': 'string', 'description': 'Repository owner.'},
          'repo': {'type': 'string', 'description': 'Repository name.'},
          'issue_number': {'type': 'integer', 'description': 'Issue or PR number.'},
          'body': {'type': 'string', 'description': 'Comment body (Markdown).'},
        },
        'required': ['repo', 'issue_number', 'body'],
      },
    ),
    McpToolDescriptor(
      name: 'github_list_pull_requests',
      description: 'List pull requests in a GitHub repository.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'owner': {'type': 'string', 'description': 'Repository owner.'},
          'repo': {'type': 'string', 'description': 'Repository name.'},
          'state': {
            'type': 'string',
            'enum': ['open', 'closed', 'all'],
            'default': 'open',
          },
          'per_page': {'type': 'integer', 'default': 20},
        },
        'required': ['repo'],
      },
    ),
    McpToolDescriptor(
      name: 'github_get_pull_request',
      description: 'Get details and changed files summary for a pull request.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'owner': {'type': 'string', 'description': 'Repository owner.'},
          'repo': {'type': 'string', 'description': 'Repository name.'},
          'pull_number': {'type': 'integer', 'description': 'Pull request number.'},
        },
        'required': ['repo', 'pull_number'],
      },
    ),
    McpToolDescriptor(
      name: 'github_create_pull_request',
      description: 'Create a new pull request in a GitHub repository.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'owner': {'type': 'string', 'description': 'Repository owner.'},
          'repo': {'type': 'string', 'description': 'Repository name.'},
          'title': {'type': 'string', 'description': 'Pull request title.'},
          'head': {'type': 'string', 'description': 'Name of the branch containing your changes.'},
          'base': {'type': 'string', 'description': 'Name of the target branch (e.g. "main").'},
          'body': {'type': 'string', 'description': 'Pull request description (Markdown).'},
          'draft': {'type': 'boolean', 'default': false},
        },
        'required': ['repo', 'title', 'head', 'base'],
      },
    ),
    McpToolDescriptor(
      name: 'github_search_code',
      description: 'Search code across GitHub repositories (e.g. "MyClass repo:owner/repo").',
      inputSchema: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'GitHub code search query.'},
          'per_page': {'type': 'integer', 'default': 15},
        },
        'required': ['query'],
      },
    ),
  ];

  @override
  Future<Map<String, dynamic>> executeTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    await _ensureTokenLoaded();

    try {
      switch (toolName) {
        case 'github_get_me':
          return await _getMe();
        case 'github_list_repositories':
          return await _listRepos(arguments);
        case 'github_search_repositories':
          return await _searchRepos(arguments);
        case 'github_get_file_contents':
          return await _getFileContents(arguments);
        case 'github_create_or_update_file':
          return await _createOrUpdateFile(arguments);
        case 'github_list_branches':
          return await _listBranches(arguments);
        case 'github_create_branch':
          return await _createBranch(arguments);
        case 'github_list_commits':
          return await _listCommits(arguments);
        case 'github_list_issues':
          return await _listIssues(arguments);
        case 'github_get_issue':
          return await _getIssue(arguments);
        case 'github_create_issue':
          return await _createIssue(arguments);
        case 'github_add_issue_comment':
          return await _addIssueComment(arguments);
        case 'github_list_pull_requests':
          return await _listPullRequests(arguments);
        case 'github_get_pull_request':
          return await _getPullRequest(arguments);
        case 'github_create_pull_request':
          return await _createPullRequest(arguments);
        case 'github_search_code':
          return await _searchCode(arguments);
        default:
          return {'error': 'Unknown GitHub tool: $toolName'};
      }
    } catch (e) {
      return {'error': 'GitHub API request failed: $e'};
    }
  }

  Future<dynamic> _request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
    bool requireToken = false,
  }) async {
    if (requireToken && _token.isEmpty) {
      throw Exception(
        'GitHub API token is not configured. Please add your Personal Access Token in Data Sources → GitHub.',
      );
    }
    final uri = Uri.parse('$_apiBase$path').replace(
      queryParameters: query != null && query.isNotEmpty ? query : null,
    );
    late http.Response resp;
    switch (method) {
      case 'GET':
        resp = await http.get(uri, headers: _headers()).timeout(const Duration(seconds: 30));
        break;
      case 'POST':
        resp = await http
            .post(uri, headers: _headers(), body: jsonEncode(body ?? {}))
            .timeout(const Duration(seconds: 30));
        break;
      case 'PUT':
        resp = await http
            .put(uri, headers: _headers(), body: jsonEncode(body ?? {}))
            .timeout(const Duration(seconds: 30));
        break;
      default:
        throw Exception('Unsupported HTTP method: $method');
    }

    final decoded = resp.body.isNotEmpty ? jsonDecode(resp.body) : null;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final msg = decoded is Map ? (decoded['message'] ?? resp.body) : resp.body;
      throw Exception('HTTP ${resp.statusCode}: $msg');
    }
    return decoded;
  }

  (String, String) _requireOwnerRepo(Map<String, dynamic> args) {
    final owner = _resolveOwner(args);
    final repo = (args['repo'] as String? ?? '').trim();
    if (owner.isEmpty) {
      throw Exception('Parameter "owner" is required (or set a Default Owner in Data Sources → GitHub).');
    }
    if (repo.isEmpty) {
      throw Exception('Parameter "repo" is required.');
    }
    return (owner, repo);
  }

  Future<Map<String, dynamic>> _getMe() async {
    final data = await _request('GET', '/user', requireToken: true) as Map<String, dynamic>;
    return {
      'login': data['login'],
      'name': data['name'],
      'email': data['email'],
      'html_url': data['html_url'],
      'public_repos': data['public_repos'],
      'private_repos': data['total_private_repos'],
    };
  }

  Future<Map<String, dynamic>> _listRepos(Map<String, dynamic> args) async {
    final owner = (args['owner'] as String? ?? '').trim();
    final sort = (args['sort'] as String? ?? 'updated').trim();
    final perPage = ((args['per_page'] as num?)?.toInt() ?? 20).clamp(1, 100);
    final path = owner.isNotEmpty ? '/users/$owner/repos' : '/user/repos';
    final data = await _request(
      'GET',
      path,
      query: {'sort': sort, 'per_page': '$perPage'},
      requireToken: owner.isEmpty,
    ) as List;
    return {
      'count': data.length,
      'repositories': data.map((r) {
        final m = r as Map<String, dynamic>;
        return {
          'full_name': m['full_name'],
          'description': m['description'],
          'private': m['private'],
          'default_branch': m['default_branch'],
          'language': m['language'],
          'stargazers_count': m['stargazers_count'],
          'updated_at': m['updated_at'],
          'html_url': m['html_url'],
        };
      }).toList(),
    };
  }

  Future<Map<String, dynamic>> _searchRepos(Map<String, dynamic> args) async {
    final q = (args['query'] as String? ?? '').trim();
    if (q.isEmpty) return {'error': 'Parameter "query" is required.'};
    final perPage = ((args['per_page'] as num?)?.toInt() ?? 15).clamp(1, 50);
    final data = await _request(
      'GET',
      '/search/repositories',
      query: {'q': q, 'per_page': '$perPage'},
    ) as Map<String, dynamic>;
    final items = (data['items'] as List? ?? []);
    return {
      'total_count': data['total_count'],
      'repositories': items.map((r) {
        final m = r as Map<String, dynamic>;
        return {
          'full_name': m['full_name'],
          'description': m['description'],
          'language': m['language'],
          'stargazers_count': m['stargazers_count'],
          'default_branch': m['default_branch'],
          'html_url': m['html_url'],
        };
      }).toList(),
    };
  }

  Future<Map<String, dynamic>> _getFileContents(Map<String, dynamic> args) async {
    final (owner, repo) = _requireOwnerRepo(args);
    final path = (args['path'] as String? ?? '').trim().replaceFirst(RegExp(r'^/+'), '');
    final ref = (args['ref'] as String? ?? '').trim();
    final endpoint = path.isEmpty
        ? '/repos/$owner/$repo/contents'
        : '/repos/$owner/$repo/contents/$path';
    final data = await _request(
      'GET',
      endpoint,
      query: ref.isNotEmpty ? {'ref': ref} : null,
    );
    if (data is List) {
      return {
        'type': 'dir',
        'path': path,
        'entries': data.map((e) {
          final m = e as Map<String, dynamic>;
          return {
            'name': m['name'],
            'path': m['path'],
            'type': m['type'],
            'size': m['size'],
            'sha': m['sha'],
          };
        }).toList(),
      };
    }
    final m = data as Map<String, dynamic>;
    String decodedContent = '';
    if (m['encoding'] == 'base64' && m['content'] is String) {
      final cleaned = (m['content'] as String).replaceAll('\n', '');
      try {
        decodedContent = utf8.decode(base64Decode(cleaned));
      } catch (_) {
        decodedContent = '[Binary file: ${m['size']} bytes]';
      }
    }
    return {
      'type': m['type'] ?? 'file',
      'name': m['name'],
      'path': m['path'],
      'sha': m['sha'],
      'size': m['size'],
      'html_url': m['html_url'],
      'content': decodedContent,
    };
  }

  Future<Map<String, dynamic>> _createOrUpdateFile(Map<String, dynamic> args) async {
    final (owner, repo) = _requireOwnerRepo(args);
    final path = (args['path'] as String? ?? '').trim().replaceFirst(RegExp(r'^/+'), '');
    final content = args['content'] as String? ?? '';
    final message = (args['message'] as String? ?? '').trim();
    final branch = (args['branch'] as String? ?? '').trim();
    final sha = (args['sha'] as String? ?? '').trim();
    if (path.isEmpty || message.isEmpty) {
      return {'error': 'Parameters "path" and "message" are required.'};
    }
    final body = <String, dynamic>{
      'message': message,
      'content': base64Encode(utf8.encode(content)),
      if (branch.isNotEmpty) 'branch': branch,
      if (sha.isNotEmpty) 'sha': sha,
    };
    final data = await _request(
      'PUT',
      '/repos/$owner/$repo/contents/$path',
      body: body,
      requireToken: true,
    ) as Map<String, dynamic>;
    final commit = data['commit'] as Map<String, dynamic>?;
    final fileInfo = data['content'] as Map<String, dynamic>?;
    return {
      'success': true,
      'path': fileInfo?['path'] ?? path,
      'sha': fileInfo?['sha'],
      'commit_sha': commit?['sha'],
      'html_url': fileInfo?['html_url'],
    };
  }

  Future<Map<String, dynamic>> _listBranches(Map<String, dynamic> args) async {
    final (owner, repo) = _requireOwnerRepo(args);
    final perPage = ((args['per_page'] as num?)?.toInt() ?? 30).clamp(1, 100);
    final data = await _request(
      'GET',
      '/repos/$owner/$repo/branches',
      query: {'per_page': '$perPage'},
    ) as List;
    return {
      'branches': data.map((b) {
        final m = b as Map<String, dynamic>;
        return {
          'name': m['name'],
          'sha': (m['commit'] as Map?)?['sha'],
          'protected': m['protected'],
        };
      }).toList(),
    };
  }

  Future<Map<String, dynamic>> _createBranch(Map<String, dynamic> args) async {
    final (owner, repo) = _requireOwnerRepo(args);
    final newBranch = (args['branch'] as String? ?? '').trim();
    if (newBranch.isEmpty) return {'error': 'Parameter "branch" is required.'};

    var fromBranch = (args['from_branch'] as String? ?? '').trim();
    if (fromBranch.isEmpty) {
      final repoInfo = await _request('GET', '/repos/$owner/$repo') as Map<String, dynamic>;
      fromBranch = (repoInfo['default_branch'] as String?) ?? 'main';
    }
    final refData = await _request(
      'GET',
      '/repos/$owner/$repo/git/ref/heads/$fromBranch',
      requireToken: true,
    ) as Map<String, dynamic>;
    final sha = (refData['object'] as Map<String, dynamic>)['sha'] as String;

    final created = await _request(
      'POST',
      '/repos/$owner/$repo/git/refs',
      body: {'ref': 'refs/heads/$newBranch', 'sha': sha},
      requireToken: true,
    ) as Map<String, dynamic>;
    return {
      'success': true,
      'branch': newBranch,
      'from_branch': fromBranch,
      'sha': sha,
      'ref': created['ref'],
    };
  }

  Future<Map<String, dynamic>> _listCommits(Map<String, dynamic> args) async {
    final (owner, repo) = _requireOwnerRepo(args);
    final sha = (args['sha'] as String? ?? '').trim();
    final path = (args['path'] as String? ?? '').trim();
    final perPage = ((args['per_page'] as num?)?.toInt() ?? 15).clamp(1, 50);
    final data = await _request(
      'GET',
      '/repos/$owner/$repo/commits',
      query: {
        'per_page': '$perPage',
        if (sha.isNotEmpty) 'sha': sha,
        if (path.isNotEmpty) 'path': path,
      },
    ) as List;
    return {
      'commits': data.map((c) {
        final m = c as Map<String, dynamic>;
        final commit = m['commit'] as Map<String, dynamic>? ?? {};
        final author = commit['author'] as Map<String, dynamic>? ?? {};
        return {
          'sha': m['sha'],
          'message': commit['message'],
          'author': author['name'],
          'date': author['date'],
          'html_url': m['html_url'],
        };
      }).toList(),
    };
  }

  Future<Map<String, dynamic>> _listIssues(Map<String, dynamic> args) async {
    final (owner, repo) = _requireOwnerRepo(args);
    final state = (args['state'] as String? ?? 'open').trim();
    final labels = (args['labels'] as String? ?? '').trim();
    final perPage = ((args['per_page'] as num?)?.toInt() ?? 20).clamp(1, 50);
    final data = await _request(
      'GET',
      '/repos/$owner/$repo/issues',
      query: {
        'state': state,
        'per_page': '$perPage',
        if (labels.isNotEmpty) 'labels': labels,
      },
    ) as List;
    return {
      'issues': data
          .where((item) => (item as Map)['pull_request'] == null)
          .map((item) {
            final m = item as Map<String, dynamic>;
            return {
              'number': m['number'],
              'title': m['title'],
              'state': m['state'],
              'user': (m['user'] as Map?)?['login'],
              'labels': (m['labels'] as List? ?? [])
                  .map((l) => (l as Map)['name'])
                  .toList(),
              'created_at': m['created_at'],
              'html_url': m['html_url'],
            };
          })
          .toList(),
    };
  }

  Future<Map<String, dynamic>> _getIssue(Map<String, dynamic> args) async {
    final (owner, repo) = _requireOwnerRepo(args);
    final numVal = (args['issue_number'] as num?)?.toInt();
    if (numVal == null) return {'error': 'Parameter "issue_number" is required.'};
    final issue = await _request('GET', '/repos/$owner/$repo/issues/$numVal') as Map<String, dynamic>;
    final comments = await _request(
      'GET',
      '/repos/$owner/$repo/issues/$numVal/comments',
      query: {'per_page': '20'},
    ) as List;
    return {
      'number': issue['number'],
      'title': issue['title'],
      'state': issue['state'],
      'user': (issue['user'] as Map?)?['login'],
      'body': issue['body'],
      'html_url': issue['html_url'],
      'comments': comments.map((c) {
        final m = c as Map<String, dynamic>;
        return {
          'user': (m['user'] as Map?)?['login'],
          'created_at': m['created_at'],
          'body': m['body'],
        };
      }).toList(),
    };
  }

  Future<Map<String, dynamic>> _createIssue(Map<String, dynamic> args) async {
    final (owner, repo) = _requireOwnerRepo(args);
    final title = (args['title'] as String? ?? '').trim();
    if (title.isEmpty) return {'error': 'Parameter "title" is required.'};
    final body = args['body'] as String? ?? '';
    final labels = (args['labels'] as List?)?.map((e) => e.toString()).toList();
    final created = await _request(
      'POST',
      '/repos/$owner/$repo/issues',
      body: {
        'title': title,
        if (body.isNotEmpty) 'body': body,
        if (labels != null && labels.isNotEmpty) 'labels': labels,
      },
      requireToken: true,
    ) as Map<String, dynamic>;
    return {
      'success': true,
      'number': created['number'],
      'title': created['title'],
      'html_url': created['html_url'],
    };
  }

  Future<Map<String, dynamic>> _addIssueComment(Map<String, dynamic> args) async {
    final (owner, repo) = _requireOwnerRepo(args);
    final numVal = (args['issue_number'] as num?)?.toInt();
    final body = (args['body'] as String? ?? '').trim();
    if (numVal == null || body.isEmpty) {
      return {'error': 'Parameters "issue_number" and "body" are required.'};
    }
    final created = await _request(
      'POST',
      '/repos/$owner/$repo/issues/$numVal/comments',
      body: {'body': body},
      requireToken: true,
    ) as Map<String, dynamic>;
    return {
      'success': true,
      'id': created['id'],
      'html_url': created['html_url'],
    };
  }

  Future<Map<String, dynamic>> _listPullRequests(Map<String, dynamic> args) async {
    final (owner, repo) = _requireOwnerRepo(args);
    final state = (args['state'] as String? ?? 'open').trim();
    final perPage = ((args['per_page'] as num?)?.toInt() ?? 20).clamp(1, 50);
    final data = await _request(
      'GET',
      '/repos/$owner/$repo/pulls',
      query: {'state': state, 'per_page': '$perPage'},
    ) as List;
    return {
      'pull_requests': data.map((pr) {
        final m = pr as Map<String, dynamic>;
        return {
          'number': m['number'],
          'title': m['title'],
          'state': m['state'],
          'draft': m['draft'],
          'user': (m['user'] as Map?)?['login'],
          'head': (m['head'] as Map?)?['ref'],
          'base': (m['base'] as Map?)?['ref'],
          'html_url': m['html_url'],
        };
      }).toList(),
    };
  }

  Future<Map<String, dynamic>> _getPullRequest(Map<String, dynamic> args) async {
    final (owner, repo) = _requireOwnerRepo(args);
    final numVal = (args['pull_number'] as num?)?.toInt();
    if (numVal == null) return {'error': 'Parameter "pull_number" is required.'};
    final pr = await _request('GET', '/repos/$owner/$repo/pulls/$numVal') as Map<String, dynamic>;
    final files = await _request(
      'GET',
      '/repos/$owner/$repo/pulls/$numVal/files',
      query: {'per_page': '30'},
    ) as List;
    return {
      'number': pr['number'],
      'title': pr['title'],
      'state': pr['state'],
      'merged': pr['merged'],
      'user': (pr['user'] as Map?)?['login'],
      'head': (pr['head'] as Map?)?['ref'],
      'base': (pr['base'] as Map?)?['ref'],
      'body': pr['body'],
      'html_url': pr['html_url'],
      'files': files.map((f) {
        final m = f as Map<String, dynamic>;
        return {
          'filename': m['filename'],
          'status': m['status'],
          'additions': m['additions'],
          'deletions': m['deletions'],
        };
      }).toList(),
    };
  }

  Future<Map<String, dynamic>> _createPullRequest(Map<String, dynamic> args) async {
    final (owner, repo) = _requireOwnerRepo(args);
    final title = (args['title'] as String? ?? '').trim();
    final head = (args['head'] as String? ?? '').trim();
    final base = (args['base'] as String? ?? '').trim();
    if (title.isEmpty || head.isEmpty || base.isEmpty) {
      return {'error': 'Parameters "title", "head", and "base" are required.'};
    }
    final created = await _request(
      'POST',
      '/repos/$owner/$repo/pulls',
      body: {
        'title': title,
        'head': head,
        'base': base,
        if ((args['body'] as String? ?? '').isNotEmpty) 'body': args['body'],
        if (args['draft'] == true) 'draft': true,
      },
      requireToken: true,
    ) as Map<String, dynamic>;
    return {
      'success': true,
      'number': created['number'],
      'title': created['title'],
      'html_url': created['html_url'],
    };
  }

  Future<Map<String, dynamic>> _searchCode(Map<String, dynamic> args) async {
    final q = (args['query'] as String? ?? '').trim();
    if (q.isEmpty) return {'error': 'Parameter "query" is required.'};
    final perPage = ((args['per_page'] as num?)?.toInt() ?? 15).clamp(1, 50);
    final data = await _request(
      'GET',
      '/search/code',
      query: {'q': q, 'per_page': '$perPage'},
      requireToken: true,
    ) as Map<String, dynamic>;
    final items = (data['items'] as List? ?? []);
    return {
      'total_count': data['total_count'],
      'items': items.map((item) {
        final m = item as Map<String, dynamic>;
        return {
          'name': m['name'],
          'path': m['path'],
          'repository': (m['repository'] as Map?)?['full_name'],
          'html_url': m['html_url'],
        };
      }).toList(),
    };
  }
}
