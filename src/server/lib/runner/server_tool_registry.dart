import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../database/server_duckdb_service.dart';
import '../models/agentic_task.dart';
import '../services/server_external_tools_service.dart';
import '../utils/server_live_log.dart';
import '../utils/server_logger.dart';
import '../utils/server_paths.dart';
import 'server_internal_mcp.dart';
import 'server_mcp_client.dart';

// ═══════════════════════════════════════════════════════════════
// Registered tool entry
// ═══════════════════════════════════════════════════════════════

/// A tool registered in the registry along with the client that exposes it.
class RegisteredTool {
  final MCPTool tool;
  final ServerMcpClient client;
  final String serverKey; // unique key for the MCP server

  const RegisteredTool({
    required this.tool,
    required this.client,
    required this.serverKey,
  });
}

// ═══════════════════════════════════════════════════════════════
// Server MCP child process entry
// ═══════════════════════════════════════════════════════════════

/// An MCP server running as a stdio child process (e.g. uvx/npx-based servers).
class StdioMcpProcess {
  final String key;
  Process? _process;
  final _inbox = StreamController<String>.broadcast();
  final _outbox = StreamController<String>.broadcast();
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;

  StdioMcpProcess(this.key);

  /// Start the process.
  Future<void> start(
    String executable,
    List<String> args, {
    Map<String, String>? env,
  }) async {
    log.info(
      '[ToolRegistry] Starting stdio MCP: $executable ${args.join(' ')}',
    );
    _process = await Process.start(
      executable,
      args,
      environment: {...Platform.environment, ...?env},
      runInShell: false,
    );
    _stdoutSub = _process!.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) => _inbox.add(line));
    _stderrSub = _process!.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) => log.debug('[MCP:$key:stderr] $line'));
  }

  /// Write a JSON-RPC line to the child process stdin.
  void writeLine(String line) {
    _process?.stdin.writeln(line);
  }

  /// Raw lines coming from the child process stdout.
  Stream<String> get lines => _inbox.stream;

  void dispose() {
    _stdoutSub?.cancel();
    _stderrSub?.cancel();
    _inbox.close();
    _outbox.close();
    _process?.kill();
    _process = null;
  }
}

// ═══════════════════════════════════════════════════════════════
// Server tool registry
// ═══════════════════════════════════════════════════════════════

/// Manages all MCP tool sources for a single task execution:
/// - HTTP/SSE external MCP servers (via [ServerMcpClient])
/// - Future: stdio child processes (via [StdioMcpProcess])
///
/// Call [initForTask] to connect the MCP servers specified in [AgenticTask].
/// Call [callTool] to invoke any registered tool.
/// Call [dispose] when the task finishes.
class ServerToolRegistry {
  final ServerDuckDbService _db;

  final List<ServerMcpClient> _clients = [];
  final List<RegisteredTool> _tools = [];
  final Map<String, StdioMcpProcess> _processes = {};
  final Map<String, Process> _localHttpProcesses = {};
  final Map<String, StreamSubscription<String>> _localHttpStdoutSubs = {};
  final Map<String, StreamSubscription<String>> _localHttpStderrSubs = {};
  final Map<String, ServerInternalMcp> _inProcessHandlers = {};

  ServerToolRegistry(this._db);

  List<RegisteredTool> get tools => List.unmodifiable(_tools);
  List<MCPTool> get mcpTools => _tools.map((t) => t.tool).toList();

  // ── Task initialisation ─────────────────────────────────────

  /// Connect all MCP servers required by [task] and register their tools.
  Future<void> initForTask(AgenticTask task, {TaskExecutor? executor}) async {
    final connectedGithubServerIds = <String>{};

    List<GithubMcpServerDefinition> githubServers = const [];
    try {
      githubServers = (await _db.getAllGithubMcpServers())
          .where((s) => s.isActive)
          .toList(growable: false);
    } catch (e) {
      log.warning('[ToolRegistry] Could not load GitHub MCP servers: $e');
    }

    final githubById = <String, GithubMcpServerDefinition>{
      for (final s in githubServers) s.id: s,
    };

    final mcpTools = executor?.mcpTools ?? task.mcpTools;
    final internalMcps = executor?.internalMcps ?? task.internalMcps;

    // External MCP tools configured on the task (HTTP endpoints)
    for (final cfg in mcpTools) {
      if (cfg.serverUrl.isEmpty) continue;
      try {
        final baseUrl = cfg.serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
        var endpoint = (cfg.mcpEndpoint ?? '/mcp').trim();
        if (endpoint.isEmpty) endpoint = '/mcp';
        if (!endpoint.startsWith('/')) endpoint = '/$endpoint';

        final apiKey = ServerExternalToolsService.instance.resolveApiKey(baseUrl, cfg.apiKey);
        final resolvedTuple = await ServerExternalToolsService.instance
            .resolveSmitheryEndpoint(baseUrl, apiKey);
        final resolvedBase = resolvedTuple.$1;
        final resolvedKey = resolvedTuple.$2;

        final parsedResolved = Uri.parse(resolvedBase);
        final resolvedUrl = parsedResolved.path.toLowerCase().endsWith('/mcp')
            ? resolvedBase
            : parsedResolved
                  .replace(path: parsedResolved.path + endpoint)
                  .toString();

        await _connectHttpMcp(
          resolvedUrl,
          bearerToken: resolvedKey,
          serverKey: cfg.serverUrl,
        );
      } catch (e) {
        log.error('[ToolRegistry] Failed to connect HTTP MCP for server ${cfg.serverUrl}: $e');
        ServerLiveLog.log(task.id, '❌ Failed to connect HTTP MCP for server ${cfg.serverUrl}: $e');
        rethrow;
      }
    }

    // Internal (in-process) MCP tools — ssh, weather, web_search, etc.
    for (final entry in internalMcps) {
      if (!entry.enabled) continue;
      await _connectInternalMcp(
        entry,
        githubById: githubById,
        connectedGithubServerIds: connectedGithubServerIds,
      );
    }

    // Backward compatibility: also connect GitHub MCP servers referenced via
    // task.mcpTools metadata (legacy tasks may not have gh_mcp_* internal entries).
    for (final server in githubServers) {
      if (connectedGithubServerIds.contains(server.id)) continue;
      if (!_isGithubServerReferencedByTask(task, server, executor: executor)) {
        continue;
      }
      await _connectGithubMcpServer(server);
      connectedGithubServerIds.add(server.id);
    }
  }

  /// Connect a single GitHub MCP server.
  Future<void> connectGithubMcpServer(GithubMcpServerDefinition server) async {
    await _connectGithubMcpServer(server);
  }

  /// Initialize and connect all active GitHub MCP servers.
  Future<void> initAllActiveGithubServers() async {
    List<GithubMcpServerDefinition> githubServers = const [];
    try {
      githubServers = (await _db.getAllGithubMcpServers())
          .where((s) => s.isActive)
          .toList(growable: false);
    } catch (e) {
      log.warning('[ToolRegistry] Could not load GitHub MCP servers: $e');
    }
    for (final server in githubServers) {
      await _connectGithubMcpServer(server);
    }
  }

  /// Connect an in-process internal MCP handler and register its tools.
  Future<void> _connectInternalMcp(
    InternalMcpEntry entry, {
    required Map<String, GithubMcpServerDefinition> githubById,
    required Set<String> connectedGithubServerIds,
  }) async {
    try {
      // GitHub-registry servers are represented in tasks as internal MCP
      // entries with mcpType: gh_mcp_<server-id>.
      if (entry.mcpType.startsWith('gh_mcp_')) {
        final serverId = entry.mcpType.substring('gh_mcp_'.length).trim();
        if (serverId.isEmpty) {
          log.warning(
            '[ToolRegistry] Empty GitHub MCP id in internalMcp type: ${entry.mcpType}',
          );
          return;
        }
        if (connectedGithubServerIds.contains(serverId)) {
          return;
        }
        final server = githubById[serverId];
        if (server == null) {
          log.warning(
            '[ToolRegistry] Unknown GitHub MCP server id in task: $serverId',
          );
          return;
        }
        await _connectGithubMcpServer(server);
        connectedGithubServerIds.add(serverId);
        return;
      }

      final handler = await createServerInternalMcp(
        entry.mcpType,
        entry.initParams,
      );
      if (handler == null) {
        log.warning(
          '[ToolRegistry] Unsupported internalMcp type: ${entry.mcpType}',
        );
        return;
      }
      _inProcessHandlers[entry.id] = handler;
      int registeredCount = 0;
      for (final tool in handler.tools) {
        if (entry.mcpType == 'website_search' &&
            (tool.name == 'index_websites' ||
                tool.name == 'reindex_websites' ||
                tool.name == 'purge_stale_index')) {
          continue;
        }
        _tools.add(
          RegisteredTool(tool: tool, client: _noopClient, serverKey: entry.id),
        );
        registeredCount++;
      }
      log.info(
        '[ToolRegistry] Registered $registeredCount in-process tools for ${entry.mcpType}',
      );
    } catch (e) {
      log.error(
        '[ToolRegistry] Failed to init internalMcp ${entry.mcpType}: $e',
      );
    }
  }

  bool _isGithubServerReferencedByTask(
    AgenticTask task,
    GithubMcpServerDefinition server, {
    TaskExecutor? executor,
  }) {
    final mcpTools = executor?.mcpTools ?? task.mcpTools;
    for (final cfg in mcpTools) {
      final serverUrl = cfg.serverUrl.trim();
      final toolName = (cfg.name ?? '').trim();
      if (serverUrl == server.id ||
          serverUrl == server.name ||
          serverUrl == server.displayName) {
        return true;
      }
      if (toolName.isNotEmpty &&
          (toolName.contains(server.name) ||
              toolName.contains(server.displayName) ||
              toolName.contains(server.id))) {
        return true;
      }
    }
    return false;
  }

  /// Connect a single HTTP MCP server and register its tools.
  Future<void> _connectHttpMcp(
    String url, {
    String? bearerToken,
    required String serverKey,
  }) async {
    final client = ServerMcpClient(url, bearerToken: bearerToken);
    try {
      await client.connect();
      _clients.add(client);
      for (final tool in client.availableTools) {
        _tools.add(
          RegisteredTool(tool: tool, client: client, serverKey: serverKey),
        );
      }
      log.info(
        '[ToolRegistry] Registered ${client.availableTools.length} tools from $url',
      );
    } catch (e) {
      log.error('[ToolRegistry] Failed to connect HTTP MCP @ $url: $e');
      client.dispose();
      rethrow;
    }
  }

  /// Connect a GitHub-registry MCP server (stdio or HTTP endpoint).
  Future<void> _connectGithubMcpServer(GithubMcpServerDefinition server) async {
    // If the server exposes an HTTP endpoint resolve via envVars or URL pattern.
    final httpUrl =
        server.envVars['MCP_HTTP_URL'] ??
        server.envVars['SERVER_URL'] ??
        server.envVars['ENDPOINT_URL'];

    if (httpUrl != null && httpUrl.isNotEmpty) {
      await _ensureLocalHttpServerStarted(server, httpUrl);
      await _connectHttpMcp(httpUrl, serverKey: server.id);
      return;
    }

    // Stdio-based servers: spawn the process and do JSON-RPC initialisation.
    await _connectStdioMcpServer(server);
  }

  Future<void> _connectStdioMcpServer(GithubMcpServerDefinition server) async {
    final (executable, args) = resolveStdioCommand(
      server,
      dataDir: _db.dataDir,
    );
    if (executable.isEmpty) {
      log.warning(
        '[ToolRegistry] Cannot resolve command for MCP server "${server.name}"',
      );
      return;
    }
    final proc = StdioMcpProcess(server.id);
    try {
      await _prepareCustomStdioServer(server);
      await proc.start(executable, args, env: server.envVars);
      _processes[server.id] = proc;
      // Do JSON-RPC initialize handshake to get tools/list.
      final tools = await _stdioInitialize(proc, server.name);
      // Create a thin in-process adapter client for the stdio proc.
      // Tools from stdio procs are registered with a sentinel null-URL client;
      // callTool routes to the proc instead.
      for (final tool in tools) {
        _tools.add(
          RegisteredTool(tool: tool, client: _noopClient, serverKey: server.id),
        );
      }
      log.info(
        '[ToolRegistry] Registered ${tools.length} stdio tools from ${server.name}',
      );
    } catch (e) {
      log.error(
        '[ToolRegistry] Failed to start stdio MCP "${server.name}": $e',
      );
      proc.dispose();
      _processes.remove(server.id);
    }
  }

  /// Resolves the executable and arguments needed to launch [server] as a
  /// stdio child process.  Returns `('', [])` if the server type is unknown.
  static (String, List<String>) resolveStdioCommand(
    GithubMcpServerDefinition server, {
    String? dataDir,
  }) {
    final expandedLaunchArgs = _expandLaunchArgs(
      server.launchArgs,
      server.envVars,
    );
    switch (server.installType.toLowerCase()) {
      case 'uvx':
        return ('uvx', [server.packageName, ...expandedLaunchArgs]);
      case 'npm':
        return ('npx', ['-y', server.packageName, ...expandedLaunchArgs]);
      case 'npx':
        return ('npx', ['-y', server.packageName, ...expandedLaunchArgs]);
      case 'node':
        final ep = _resolveEntryPointPath(
          server,
          dataDir: dataDir,
          defaultEntryPoint: 'index.js',
        );
        return ('node', [ep, ...expandedLaunchArgs]);
      case 'python':
        final ep = _resolveEntryPointPath(
          server,
          dataDir: dataDir,
          defaultEntryPoint: server.packageName,
        );
        return (
          _pythonVenvExecutable(p.dirname(ep)),
          [ep, ...expandedLaunchArgs],
        );
      case 'pip':
        final module = (server.entryPoint ?? '').trim();
        if (module.isEmpty ||
            _looksLikeRequirementsSpec(module) ||
            _looksLikeRequirementsSpec(server.packageName)) {
          return ('', []);
        }
        return ('python3', ['-m', module, ...expandedLaunchArgs]);
      default:
        final ep = server.entryPoint ?? '';
        if (ep.isEmpty) return ('', []);
        return (ep, expandedLaunchArgs);
    }
  }

  static bool _looksLikeRequirementsSpec(String value) {
    final v = value.trim().toLowerCase();
    if (v.isEmpty) return false;
    return v.endsWith('requirements.txt') ||
        v.endsWith('.txt') ||
        v.contains('/requirements');
  }

  static final RegExp _launchArgTemplate = RegExp(
    r'\{\{\s*([a-zA-Z0-9_\-.]+)\s*\}\}',
  );

  static List<String> _expandLaunchArgs(
    List<String> args,
    Map<String, String> envVars,
  ) {
    if (args.isEmpty) return const [];

    final expanded = <String>[];
    final lowerEnv = <String, String>{
      for (final e in envVars.entries) e.key.toLowerCase(): e.value,
    };

    String resolveKey(String key) {
      return envVars[key] ??
          envVars[key.toUpperCase()] ??
          lowerEnv[key.toLowerCase()] ??
          '';
    }

    Iterable<String> splitIfList(String value) {
      final normalized = value.trim();
      if (normalized.isEmpty) return const [];
      if (normalized.contains(';')) {
        return normalized
            .split(';')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty);
      }
      if (normalized.contains('\n')) {
        return normalized
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty);
      }
      return [normalized];
    }

    for (final rawArg in args) {
      final matches = _launchArgTemplate.allMatches(rawArg).toList();
      if (matches.isEmpty) {
        expanded.add(rawArg);
        continue;
      }

      // If the argument is exactly a single template token, allow list
      // expansion (e.g. "{{allowed_dirs}}" => multiple positional dirs).
      final singleToken =
          matches.length == 1 &&
          matches.first.start == 0 &&
          matches.first.end == rawArg.length;
      if (singleToken) {
        final key = matches.first.group(1)!;
        final value = resolveKey(key);
        final values = splitIfList(value).toList();
        if (values.isEmpty) {
          log.warning(
            '[ToolRegistry] Missing launch arg template value for {{$key}}',
          );
        } else {
          expanded.addAll(values);
        }
        continue;
      }

      var replaced = rawArg;
      for (final m in matches) {
        final key = m.group(1)!;
        final value = resolveKey(key);
        if (value.isEmpty) {
          log.warning(
            '[ToolRegistry] Missing launch arg template value for {{$key}} in "$rawArg"',
          );
        }
        replaced = replaced.replaceAll(m.group(0)!, value);
      }
      expanded.add(replaced);
    }

    return expanded;
  }

  static String _resolveEntryPointPath(
    GithubMcpServerDefinition server, {
    String? dataDir,
    required String defaultEntryPoint,
  }) {
    final entryPoint = (server.entryPoint ?? defaultEntryPoint).trim();
    if (entryPoint.isEmpty) return defaultEntryPoint;
    if (p.isAbsolute(entryPoint)) return entryPoint;

    final type = server.installType.toLowerCase() == 'node' ? 'node' : 'python';
    final safeServerName = server.name.trim().replaceAll(
      RegExp(r'[^a-zA-Z0-9._-]+'),
      '_',
    );
    final filesRoot = Platform.environment['TEALKIT_FILES_DIR']?.trim();
    final legacyRoot = dataDir != null ? p.join(dataDir, 'mcp_servers') : null;
    final mcpServersRoot = (filesRoot != null && filesRoot.isNotEmpty)
        ? resolveServerMcpServersDir()
        : (legacyRoot ?? resolveServerMcpServersDir());
    return p.join(mcpServersRoot, type, safeServerName, entryPoint);
  }

  static String _pythonVenvExecutable(String serverDirPath) {
    return Platform.isWindows
        ? p.join(serverDirPath, '.venv', 'Scripts', 'python.exe')
        : p.join(serverDirPath, '.venv', 'bin', 'python');
  }

  Future<void> _prepareCustomStdioServer(
    GithubMcpServerDefinition server,
  ) async {
    final installType = server.installType.toLowerCase();
    if (installType != 'python' && installType != 'node') return;

    final entryPointRaw = (server.entryPoint ?? '').trim();
    if (entryPointRaw.isEmpty || p.isAbsolute(entryPointRaw)) return;

    final entryPoint = _resolveEntryPointPath(
      server,
      dataDir: _db.dataDir,
      defaultEntryPoint: installType == 'node'
          ? 'index.js'
          : server.packageName,
    );
    final serverDir = Directory(p.dirname(entryPoint));
    if (!await serverDir.exists()) {
      log.warning(
        '[ToolRegistry] Custom MCP server directory missing: ${serverDir.path}',
      );
      return;
    }

    if (installType == 'python') {
      await _preparePythonCustomServer(serverDir);
      return;
    }

    await _prepareNodeCustomServer(serverDir);
  }

  Future<void> _preparePythonCustomServer(Directory serverDir) async {
    final reqFile = File(p.join(serverDir.path, 'requirements.txt'));
    final installedMarker = File(p.join(serverDir.path, '.installed'));
    final pythonExe = File(_pythonVenvExecutable(serverDir.path));
    if (!await pythonExe.exists()) {
      log.info(
        '[ToolRegistry] Creating Python virtualenv in ${serverDir.path}',
      );
      final venvProc = await Process.start(
        'python3',
        <String>['-m', 'venv', p.join(serverDir.path, '.venv')],
        runInShell: false,
        workingDirectory: serverDir.path,
        environment: Platform.environment,
      );
      final venvStdout = await venvProc.stdout
          .transform(const SystemEncoding().decoder)
          .join();
      final venvStderr = await venvProc.stderr
          .transform(const SystemEncoding().decoder)
          .join();
      final venvExit = await venvProc.exitCode.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          venvProc.kill(ProcessSignal.sigkill);
          throw TimeoutException('Python MCP virtualenv creation timed out');
        },
      );
      if (venvExit != 0 || !await pythonExe.exists()) {
        throw Exception(
          'Python MCP venv creation failed (exit $venvExit): ${venvStderr.isNotEmpty ? venvStderr : venvStdout}',
        );
      }
    }
    if (!await reqFile.exists() || await installedMarker.exists()) return;

    log.info(
      '[ToolRegistry] Installing Python MCP dependencies in ${serverDir.path}',
    );
    final proc = await Process.start(
      'uv',
      <String>[
        'pip',
        'install',
        '--python',
        pythonExe.path,
        '-r',
        reqFile.path,
      ],
      runInShell: false,
      workingDirectory: serverDir.path,
      environment: Platform.environment,
    );
    final stdoutText = await proc.stdout
        .transform(const SystemEncoding().decoder)
        .join();
    final stderrText = await proc.stderr
        .transform(const SystemEncoding().decoder)
        .join();
    final exit = await proc.exitCode.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        throw TimeoutException('Python MCP dependency installation timed out');
      },
    );
    if (exit != 0) {
      throw Exception(
        'Python MCP install failed (exit $exit): ${stderrText.isNotEmpty ? stderrText : stdoutText}',
      );
    }
    await installedMarker.writeAsString('1', flush: true);
  }

  Future<void> _prepareNodeCustomServer(Directory serverDir) async {
    final packageJson = File(p.join(serverDir.path, 'package.json'));
    final nodeModules = Directory(p.join(serverDir.path, 'node_modules'));
    if (!await packageJson.exists() || await nodeModules.exists()) return;

    log.info(
      '[ToolRegistry] Installing Node MCP dependencies in ${serverDir.path}',
    );
    final proc = await Process.start(
      'npm',
      <String>['install', '--prefix', serverDir.path],
      runInShell: false,
      environment: Platform.environment,
    );
    final stdoutText = await proc.stdout
        .transform(const SystemEncoding().decoder)
        .join();
    final stderrText = await proc.stderr
        .transform(const SystemEncoding().decoder)
        .join();
    final exit = await proc.exitCode.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        throw TimeoutException('Node MCP dependency installation timed out');
      },
    );
    if (exit != 0) {
      throw Exception(
        'Node MCP install failed (exit $exit): ${stderrText.isNotEmpty ? stderrText : stdoutText}',
      );
    }
  }

  bool _shouldAutoLaunchLocalHttpServer(
    GithubMcpServerDefinition server,
    Uri endpointUri,
  ) {
    final explicit = (server.envVars['MCP_LOCAL_LAUNCH'] ?? '')
        .trim()
        .toLowerCase();
    if (explicit == 'true' ||
        explicit == '1' ||
        explicit == 'yes' ||
        explicit == 'auto') {
      return true;
    }

    // Auto-launch bundled local servers by default when they point to loopback.
    final loopbackHost =
        endpointUri.host == '127.0.0.1' ||
        endpointUri.host == 'localhost' ||
        endpointUri.host == '::1';
    final installType = server.installType.toLowerCase();
    final hasLocalEntryPoint = (server.entryPoint ?? '').trim().isNotEmpty;
    return loopbackHost &&
        hasLocalEntryPoint &&
        (installType == 'python' || installType == 'node');
  }

  Future<void> _ensureLocalHttpServerStarted(
    GithubMcpServerDefinition server,
    String httpUrl,
  ) async {
    final uri = Uri.tryParse(httpUrl);
    if (uri == null) return;

    if (!_shouldAutoLaunchLocalHttpServer(server, uri)) return;

    final existing = _localHttpProcesses[server.id];
    if (existing != null && existing.pid > 0) {
      return;
    }

    final installType = server.installType.toLowerCase();
    if (installType != 'python' && installType != 'node') return;

    final entryPoint = (server.entryPoint ?? '').trim();
    if (entryPoint.isEmpty) return;

    final defaultEntryPoint = installType == 'python'
        ? server.packageName
        : 'index.js';
    final resolvedEntryPoint = _resolveEntryPointPath(
      server,
      dataDir: _db.dataDir,
      defaultEntryPoint: defaultEntryPoint,
    );
    final launchArgs = _expandLaunchArgs(server.launchArgs, server.envVars);

    await _prepareCustomStdioServer(server);

    final executable = installType == 'python'
        ? _pythonVenvExecutable(p.dirname(resolvedEntryPoint))
        : 'node';
    log.info(
      '[ToolRegistry] Starting local HTTP MCP ${server.name}: $executable $resolvedEntryPoint ${launchArgs.join(' ')}',
    );
    final process = await Process.start(
      executable,
      <String>[resolvedEntryPoint, ...launchArgs],
      runInShell: false,
      environment: {...Platform.environment, ...server.envVars},
    );

    _localHttpProcesses[server.id] = process;
    _localHttpStdoutSubs[server.id] = process.stdout
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) => log.debug('[MCP:${server.name}:stdout] $line'));
    _localHttpStderrSubs[server.id] = process.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) => log.debug('[MCP:${server.name}:stderr] $line'));

    process.exitCode.then((code) {
      log.warning(
        '[ToolRegistry] Local HTTP MCP ${server.name} exited with code $code',
      );
      _localHttpProcesses.remove(server.id);
      _localHttpStdoutSubs.remove(server.id)?.cancel();
      _localHttpStderrSubs.remove(server.id)?.cancel();
    });

    final ready = await _waitForHttpMcpReady(
      uri,
      timeout: const Duration(seconds: 30),
    );
    if (!ready) {
      process.kill();
      _localHttpProcesses.remove(server.id);
      await _localHttpStdoutSubs.remove(server.id)?.cancel();
      await _localHttpStderrSubs.remove(server.id)?.cancel();
      throw Exception(
        'Local HTTP MCP ${server.name} did not become ready at $httpUrl',
      );
    }
  }

  Future<bool> _waitForHttpMcpReady(
    Uri endpointUri, {
    required Duration timeout,
  }) async {
    final client = HttpClient();
    final deadline = DateTime.now().add(timeout);
    final probeUri = endpointUri.path.toLowerCase().endsWith('/mcp')
        ? endpointUri
        : endpointUri.replace(path: '${endpointUri.path}/mcp');

    try {
      while (DateTime.now().isBefore(deadline)) {
        try {
          final req = await client.postUrl(probeUri);
          req.headers.contentType = ContentType.json;
          req.write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 'probe',
              'method': 'initialize',
              'params': {
                'protocolVersion': '2024-11-05',
                'capabilities': {},
                'clientInfo': {'name': 'TealKit Server', 'version': '1.0.0'},
              },
            }),
          );
          final resp = await req.close();
          if (resp.statusCode == 200) {
            return true;
          }
        } catch (_) {
          // Retry until timeout.
        }
        await Future<void>.delayed(const Duration(milliseconds: 350));
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Minimal JSON-RPC initialize handshake on stdio to retrieve tools.
  Future<List<MCPTool>> _stdioInitialize(
    StdioMcpProcess proc,
    String serverName,
  ) async {
    final id = 'init-${DateTime.now().millisecondsSinceEpoch}';
    final initMsg = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2024-11-05',
        'capabilities': {
          'tools': {'listChanged': true},
        },
        'clientInfo': {'name': 'TealKit Server', 'version': '1.0.0'},
      },
    });
    proc.writeLine(initMsg);

    // Wait for initialize response
    String? initResp;
    await for (final line in proc.lines.timeout(const Duration(seconds: 30))) {
      if (line.trim().isEmpty) continue;
      try {
        final j = jsonDecode(line) as Map<String, dynamic>;
        if (j['id'] == id) {
          initResp = line;
          break;
        }
      } catch (_) {}
    }
    if (initResp == null) {
      throw Exception('Stdio MCP "$serverName" did not respond to initialize');
    }

    // Send initialized notification
    proc.writeLine(
      jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
    );

    // tools/list
    final listId = 'tools-${DateTime.now().millisecondsSinceEpoch}';
    proc.writeLine(
      jsonEncode({'jsonrpc': '2.0', 'id': listId, 'method': 'tools/list'}),
    );

    await for (final line in proc.lines.timeout(const Duration(seconds: 15))) {
      if (line.trim().isEmpty) continue;
      try {
        final j = jsonDecode(line) as Map<String, dynamic>;
        if (j['id'] == listId) {
          final toolsRaw = j['result']?['tools'] as List?;
          if (toolsRaw == null) return [];
          return toolsRaw
              .map((t) => MCPTool.fromJson(t as Map<String, dynamic>))
              .toList();
        }
      } catch (_) {}
    }
    return [];
  }

  // ── Tool invocation ─────────────────────────────────────────

  /// Call a tool by name with [arguments].
  ///
  /// Routes to the correct HTTP client or stdio process.
  /// If the exact name is not found, falls back to fuzzy matching (prefix/suffix/substring)
  /// to handle models that hallucinate slightly different tool names (e.g. "create_chart"
  /// instead of "create_chart_png").

  /// Resolves a (possibly hallucinated) tool name to an actual registered name.
  /// Returns the original name unchanged if an exact match exists or no fuzzy match is found.
  String _resolveToolName(String name) {
    // Exact match — no work needed.
    if (_tools.any((t) => t.tool.name == name)) return name;

    final names = _tools.map((t) => t.tool.name).toList();

    // 1. Prefix match: model called "create_chart", registry has "create_chart_png"
    final prefixMatches = names
        .where((n) => n.startsWith(name) || name.startsWith(n))
        .toList();
    if (prefixMatches.length == 1) return prefixMatches.first;

    // 2. Substring match: registered name contains the called name or vice versa
    final substringMatches = names
        .where((n) => n.contains(name) || name.contains(n))
        .toList();
    if (substringMatches.length == 1) return substringMatches.first;

    // 3. Snake-case token overlap: find the registered name sharing the most underscore tokens
    final calledTokens = name.split('_').toSet();
    String? bestName;
    int bestOverlap = 0;
    for (final n in names) {
      final overlap = n.split('_').where(calledTokens.contains).length;
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        bestName = n;
      }
    }
    if (bestName != null && bestOverlap >= 2) return bestName;

    return name; // no match found, return original (will result in "not found" error)
  }

  Future<MCPToolResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final resolvedName = _resolveToolName(name);
    if (resolvedName != name) {
      log.info('[ToolRegistry] Fuzzy-resolved tool "$name" → "$resolvedName"');
    }
    final entry = _tools.where((t) => t.tool.name == resolvedName).firstOrNull;
    if (entry == null) {
      return MCPToolResult(
        content: [
          MCPContent(
            type: 'text',
            text: '{"error":"Tool $name not found in registry"}',
          ),
        ],
        isError: true,
      );
    }

    // In-process handler path
    final handler = _inProcessHandlers[entry.serverKey];
    if (handler != null) {
      return _callInProcessTool(handler, name, arguments);
    }

    // Stdio process path
    final proc = _processes[entry.serverKey];
    if (proc != null) {
      return _callStdioTool(proc, name, arguments);
    }

    // HTTP client path
    return entry.client.callTool(name, arguments);
  }

  Future<MCPToolResult> _callInProcessTool(
    ServerInternalMcp handler,
    String name,
    Map<String, dynamic> arguments,
  ) async {
    try {
      final result = await handler.callTool(name, arguments);
      return MCPToolResult(
        content: [MCPContent(type: 'text', text: jsonEncode(result))],
      );
    } catch (e) {
      return MCPToolResult(
        content: [
          MCPContent(type: 'text', text: jsonEncode({'error': e.toString()})),
        ],
        isError: true,
      );
    }
  }

  Future<MCPToolResult> _callStdioTool(
    StdioMcpProcess proc,
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final id = 'call-${DateTime.now().millisecondsSinceEpoch}';
    proc.writeLine(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': 'tools/call',
        'params': {'name': name, 'arguments': arguments},
      }),
    );

    await for (final line in proc.lines.timeout(const Duration(seconds: 60))) {
      if (line.trim().isEmpty) continue;
      try {
        final j = jsonDecode(line) as Map<String, dynamic>;
        if (j['id'] == id) {
          if (j.containsKey('error')) {
            final err = j['error'];
            return MCPToolResult(
              content: [MCPContent(type: 'text', text: jsonEncode(err))],
              isError: true,
            );
          }
          return MCPToolResult.fromJson(j['result'] as Map<String, dynamic>);
        }
      } catch (_) {}
    }
    return MCPToolResult(
      content: [
        MCPContent(type: 'text', text: '{"error":"Timeout calling $name"}'),
      ],
      isError: true,
    );
  }

  // ── Lifecycle ────────────────────────────────────────────────

  Future<void> dispose() async {
    for (final c in _clients) {
      c.dispose();
    }
    for (final p in _processes.values) {
      p.dispose();
    }
    for (final process in _localHttpProcesses.values) {
      process.kill();
    }
    for (final sub in _localHttpStdoutSubs.values) {
      await sub.cancel();
    }
    for (final sub in _localHttpStderrSubs.values) {
      await sub.cancel();
    }
    for (final h in _inProcessHandlers.values) {
      await h.dispose();
    }
    _clients.clear();
    _tools.clear();
    _processes.clear();
    _localHttpProcesses.clear();
    _localHttpStdoutSubs.clear();
    _localHttpStderrSubs.clear();
    _inProcessHandlers.clear();
  }
}

// ─── Noop sentinel client (for stdio tool entries) ───────────────────────────

final _noopClient = _NoopMcpClient();

class _NoopMcpClient extends ServerMcpClient {
  _NoopMcpClient() : super('stdio://noop');

  @override
  bool get isConnected => false;

  @override
  Future<MCPToolResult> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    return MCPToolResult(
      content: [
        MCPContent(
          type: 'text',
          text:
              '{"error":"callTool on noop client — use StdioMcpProcess instead"}',
        ),
      ],
      isError: true,
    );
  }
}
