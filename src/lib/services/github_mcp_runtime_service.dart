import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/github_mcp_server_definition.dart';
import 'app_logger.dart';
import 'github_mcp_library_service.dart';

// ═══════════════════════════════════════════════════════════════
// Progress events
// ═══════════════════════════════════════════════════════════════

enum GhMcpInstallStep { detecting, installing, verifying, done, failed }

class GhMcpInstallProgress {
  final GhMcpInstallStep step;
  final String message;
  const GhMcpInstallProgress(this.step, this.message);
}

// ═══════════════════════════════════════════════════════════════
// Runtime service
// ═══════════════════════════════════════════════════════════════

/// Manages installation and process launching for GitHub-sourced MCP servers.
///
/// **Install strategies (Python only, v1):**
///   • uvx  — `uvx install <packageName>` then launches `uvx <entryPoint>`
///   • pip  — creates `.venv` in app-support dir, `pip install <packageName>`,
///            then launches `<venv>/python -m <entryPoint>`
///
/// **Protocol:** Each launched process speaks MCP stdio (JSON-RPC 2.0,
/// newline-delimited).  The process is kept alive as long as the bridge
/// server is initialized (one process per server).
class GithubMcpRuntimeService {
  GithubMcpRuntimeService._();
  static final instance = GithubMcpRuntimeService._();

  String _normalizeGithubBlobToRaw(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null) return value.trim();
    if ((uri.host == 'github.com' || uri.host == 'www.github.com') && uri.pathSegments.length >= 5) {
      final s = uri.pathSegments;
      if (s[2] == 'blob') {
        final owner = s[0];
        final repo = s[1];
        final ref = s[3];
        final rest = s.sublist(4).join('/');
        final rawPath = '/$owner/$repo/$ref/$rest';
        return Uri(scheme: 'https', host: 'raw.githubusercontent.com', path: rawPath).toString();
      }
    }
    return value.trim();
  }

  bool _looksLikeRequirementsSpec(String value) {
    final v = value.trim().toLowerCase();
    if (v.isEmpty) return false;
    return v.endsWith('requirements.txt') || v.endsWith('.txt') || v.contains('/requirements');
  }

  Uri? _requirementsToRepoRoot(Uri requirementsUri) {
    if (requirementsUri.scheme != 'https') return null;
    final host = requirementsUri.host.toLowerCase();
    final segments = requirementsUri.pathSegments;
    if (host == 'raw.githubusercontent.com' && segments.length >= 3) {
      return Uri(scheme: 'https', host: 'raw.githubusercontent.com', pathSegments: segments.take(3).toList());
    }
    if ((host == 'github.com' || host == 'www.github.com') && segments.length >= 5 && segments[2] == 'blob') {
      return Uri(scheme: 'https', host: 'raw.githubusercontent.com', pathSegments: [segments[0], segments[1], segments[3]]);
    }
    return null;
  }

  String? _inferPipScriptName(Uri requirementsUri) {
    final segments = requirementsUri.pathSegments;
    if (segments.isEmpty) return null;
    final repoName = segments.length >= 2 ? segments[1] : '';
    final normalized = repoName
        .replaceAll(RegExp(r'^mcp-server-'), '')
        .replaceAll(RegExp(r'-py$'), '')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (normalized.isEmpty) return null;
    return '$normalized.py';
  }

  Future<String?> _ensureRequirementsSourceScript(String serverDir, String requirementsUrl) async {
    final requirementsUri = Uri.tryParse(requirementsUrl.trim());
    if (requirementsUri == null) return null;
    final repoRoot = _requirementsToRepoRoot(requirementsUri);
    final scriptName = _inferPipScriptName(requirementsUri);
    if (repoRoot == null || scriptName == null) return null;

    final scriptFile = File(p.join(serverDir, scriptName));
    if (await scriptFile.exists()) return scriptFile.path;

    final scriptUrl = repoRoot.replace(path: '${repoRoot.path}/$scriptName');
    try {
      final client = HttpClient();
      try {
        final req = await client.getUrl(scriptUrl);
        req.headers.set(HttpHeaders.acceptHeader, 'text/plain,*/*');
        final resp = await req.close();
        if (resp.statusCode != 200) return null;
        final content = await resp.transform(utf8.decoder).join();
        if (content.trim().isEmpty) return null;
        await scriptFile.writeAsString(content, flush: true);
        return scriptFile.path;
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return null;
    }
  }

  Future<String?> _installPlaywrightBrowsers(String dir) async {
    final pythonExe = _pythonVenvExe(dir);
    if (!await File(pythonExe).exists()) {
      return 'Python virtual environment is missing at $pythonExe';
    }

    try {
      final result = await Process.run(
        pythonExe,
        ['-m', 'playwright', 'install', 'chromium'],
        workingDirectory: dir,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode != 0) {
        final stderr = _sanitizeOutput(result.stderr as String);
        final stdout = _sanitizeOutput(result.stdout as String);
        return 'playwright browser install failed:\n${stderr.isNotEmpty ? stderr : stdout}';
      }
      return null;
    } catch (e) {
      return 'playwright browser install threw: $e';
    }
  }

  // ─── Directory helpers ─────────────────────────────────────────────────────

  Future<String> get _rootDir async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'mcp-ghservers'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  Future<String> serverDir(String serverId) async {
    final root = await _rootDir;
    final dir = Directory(p.join(root, serverId));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  // ─── Tool detection ────────────────────────────────────────────────────────

  List<String> _unixCandidates(String name) {
    final home = Platform.environment['HOME'] ?? '';
    final pathEnv = Platform.environment['PATH'] ?? '';
    final fromPath = pathEnv.split(':').where((s) => s.isNotEmpty).map((dir) => p.join(dir, name));

    return {
      name,
      ...fromPath,
      '/usr/local/bin/$name',
      '/opt/homebrew/bin/$name',
      '/usr/bin/$name',
      '/bin/$name',
      if (home.isNotEmpty) p.join(home, '.local', 'bin', name),
      if (home.isNotEmpty) p.join(home, '.cargo', 'bin', name),
    }.toList();
  }

  Future<String?> _resolveViaShell(String toolName) async {
    if (Platform.isWindows) return null;
    try {
      final result = await Process.run('/bin/zsh', ['-lc', 'command -v $toolName']);
      final resolved = (result.stdout as String?)?.trim() ?? '';
      if (result.exitCode == 0 && resolved.isNotEmpty) {
        return resolved;
      }
    } catch (_) {
      // Ignore shell lookup failures and continue with static candidates.
    }
    return null;
  }

  String _siblingTool(String exePath, String tool) {
    if (!p.isAbsolute(exePath)) {
      return Platform.isWindows ? '$tool.cmd' : tool;
    }
    return Platform.isWindows ? p.join(p.dirname(exePath), '$tool.cmd') : p.join(p.dirname(exePath), tool);
  }

  Map<String, String> _augmentedEnv({Map<String, String>? baseEnv, String? extraPath}) {
    final env = Map<String, String>.from(Platform.environment);
    if (baseEnv != null) {
      env.addAll(baseEnv);
    }
    if (Platform.isWindows) return env;

    final currentPath = env['PATH'] ?? '';
    final List<String> paths = currentPath.split(':').where((p) => p.isNotEmpty).toList();

    // Add common tool locations if not already present
    const standardPaths = [
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
      '/bin',
      '/usr/sbin',
      '/sbin',
    ];
    for (final p in standardPaths) {
      if (!paths.contains(p)) {
        paths.add(p);
      }
    }

    if (extraPath != null && extraPath.isNotEmpty && !paths.contains(extraPath)) {
      paths.insert(0, extraPath);
    }

    env['PATH'] = paths.join(':');
    return env;
  }

  /// Returns the `uvx` executable path, or null if not found.
  Future<String?> detectUv() async {
    final shellResolved = await _resolveViaShell('uvx');
    final candidates = Platform.isWindows ? ['uvx.exe', 'uvx'] : [?shellResolved, ..._unixCandidates('uvx')];
    log.info('[GhMcpRuntime] detectUv: trying candidates = $candidates');
    for (final exe in candidates) {
      try {
        final result = await Process.run(exe, ['--version']);
        if (result.exitCode == 0) {
          log.info('[GhMcpRuntime] Detected uvx: $exe → ${result.stdout.toString().trim()}');
          return exe;
        } else {
          log.warning('[GhMcpRuntime] detectUv: $exe exited with ${result.exitCode}: ${result.stderr}');
        }
      } catch (e) {
        log.warning('[GhMcpRuntime] detectUv: $exe failed with error: $e');
      }
    }
    log.warning('[GhMcpRuntime] detectUv: no candidate worked, returning null');
    return null;
  }

  /// Returns the `uv` executable path or null.
  Future<String?> detectUvTool() async {
    final shellResolved = await _resolveViaShell('uv');
    final candidates = Platform.isWindows ? ['uv.exe', 'uv'] : [?shellResolved, ..._unixCandidates('uv')];
    log.info('[GhMcpRuntime] detectUvTool: trying candidates = $candidates');
    for (final exe in candidates) {
      try {
        final result = await Process.run(exe, ['--version']);
        if (result.exitCode == 0) {
          log.info('[GhMcpRuntime] Detected uv: $exe → ${result.stdout.toString().trim()}');
          return exe;
        } else {
          log.warning('[GhMcpRuntime] detectUvTool: $exe exited with ${result.exitCode}: ${result.stderr}');
        }
      } catch (e) {
        log.warning('[GhMcpRuntime] detectUvTool: $exe failed with error: $e');
      }
    }
    log.warning('[GhMcpRuntime] detectUvTool: no candidate worked, returning null');
    return null;
  }

  /// Returns the `node` executable path if version ≥ 18, or null.
  Future<String?> detectNode() async {
    final shellResolved = await _resolveViaShell('node');
    final candidates = Platform.isWindows ? ['node.exe', 'node'] : [?shellResolved, ..._unixCandidates('node')];
    log.info('[GhMcpRuntime] detectNode: trying candidates = $candidates');
    for (final exe in candidates) {
      try {
        final result = await Process.run(exe, ['--version']);
        if (result.exitCode == 0) {
          final version = (result.stdout as String).trim(); // e.g. "v20.10.0"
          final major = int.tryParse(version.replaceFirst(RegExp(r'^v'), '').split('.').first) ?? 0;
          if (major >= 18) {
            log.info('[GhMcpRuntime] Detected Node.js: $exe → $version');
            return exe;
          } else {
            log.warning('[GhMcpRuntime] detectNode: $exe is version $version (< 18)');
          }
        } else {
          log.warning('[GhMcpRuntime] detectNode: $exe exited with ${result.exitCode}: ${result.stderr}');
        }
      } catch (e) {
        log.warning('[GhMcpRuntime] detectNode: $exe failed with error: $e');
      }
    }
    log.warning('[GhMcpRuntime] detectNode: no candidate worked, returning null');
    return null;
  }

  /// Returns the system Python 3 executable, or null.
  Future<String?> detectPython() async {
    final shellResolvedPy3 = await _resolveViaShell('python3');
    final shellResolvedPy = await _resolveViaShell('python');
    final candidates = Platform.isWindows
        ? ['python', 'python3']
        : [
            ?shellResolvedPy3,
            ?shellResolvedPy,
            'python3',
            'python',
            '/usr/local/bin/python3',
            '/usr/local/bin/python',
            '/opt/homebrew/bin/python3',
            '/opt/homebrew/bin/python',
            '/usr/bin/python3',
            '/usr/local/opt/python@3.14/libexec/bin/python',
            '/Library/Frameworks/Python.framework/Versions/Current/bin/python3',
          ];
    log.info('[GhMcpRuntime] detectPython: trying candidates = $candidates');
    for (final exe in candidates) {
      try {
        final result = await Process.run(exe, ['--version']);
        final out = (result.stdout as String?) ?? '';
        final err = (result.stderr as String?) ?? '';
        final version = (out.isNotEmpty ? out : err).trim();
        if (result.exitCode == 0 && version.toLowerCase().contains('python 3')) {
          log.info('[GhMcpRuntime] Detected Python: $exe → $version');
          return exe;
        } else {
          log.warning('[GhMcpRuntime] detectPython: $exe failed check (exit=${result.exitCode}, version=$version)');
        }
      } catch (e) {
        log.warning('[GhMcpRuntime] detectPython: $exe failed with error: $e');
      }
    }
    log.warning('[GhMcpRuntime] detectPython: no candidate worked, returning null');
    return null;
  }

  String _pipExe(String dir) {
    return Platform.isWindows ? p.join(dir, '.venv', 'Scripts', 'pip.exe') : p.join(dir, '.venv', 'bin', 'pip');
  }

  String _pythonVenvExe(String dir) {
    return Platform.isWindows ? p.join(dir, '.venv', 'Scripts', 'python.exe') : p.join(dir, '.venv', 'bin', 'python');
  }

  // ─── Install ───────────────────────────────────────────────────────────────

  /// Install the given server.
  /// Streams [GhMcpInstallProgress] events via [onProgress].
  /// Returns null on success, error string on failure.
  Future<String?> install(GithubMcpServerDefinition def, {void Function(GhMcpInstallProgress)? onProgress}) async {
    log.info('[GhMcpRuntime] Installing ${def.packageName} via ${def.installType}');

    switch (def.installType) {
      case 'uvx':
        return _installUvx(def, onProgress: onProgress);
      case 'pip':
        return _installPip(def, onProgress: onProgress);
      case 'npm':
        return _installNpm(def, onProgress: onProgress);
      case 'npx':
      case 'nodejs':
        return _installNpx(def, onProgress: onProgress);
      default:
        final msg = 'Unknown installType: ${def.installType}';
        onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
        return msg;
    }
  }

  Future<String?> _installUvx(GithubMcpServerDefinition def, {void Function(GhMcpInstallProgress)? onProgress}) async {
    onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.detecting, 'Checking for uv/uvx...'));

    final uv = await detectUvTool();
    if (uv == null) {
      const msg =
          'uv not found on PATH.\n'
          'Install uv from https://docs.astral.sh/uv/getting-started/installation/ '
          'and restart the app.';
      onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
      return msg;
    }

    onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.installing, 'Installing ${def.packageName} via uv tool...'));

    try {
      final result = await Process.run(
        uv,
        ['tool', 'install', def.packageName],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        environment: _augmentedEnv(extraPath: p.isAbsolute(uv) ? p.dirname(uv) : null),
      );
      if (result.exitCode != 0) {
        final stderr = _sanitizeOutput(result.stderr as String);
        final String msg;
        if (stderr.contains('does not provide any executables') || stderr.contains('Failed to install entrypoints')) {
          msg =
              'Cannot install "${def.packageName}" via uvx: this package does not '
              'provide a Python executable. It is likely a native binary (e.g. Rust) '
              'that must be installed manually from its GitHub releases page.';
        } else {
          msg = 'uvx install failed:\n$stderr';
        }
        onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
        return msg;
      }
    } catch (e) {
      final msg = 'uv tool install threw: $e';
      onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
      return msg;
    }

    onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.done, '${def.displayName} installed successfully.'));
    log.info('[GhMcpRuntime] uvx install done: ${def.packageName}');
    return null;
  }

  Future<String?> _installPip(GithubMcpServerDefinition def, {void Function(GhMcpInstallProgress)? onProgress}) async {
    onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.detecting, 'Checking for Python 3...'));

    final python = await detectPython();
    if (python == null) {
      const msg =
          'Python 3 not found on PATH.\n'
          'Install Python from https://python.org and make sure it is in PATH.';
      onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
      return msg;
    }

    final dir = await serverDir(def.id);

    onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.installing, 'Creating virtual environment...'));

    try {
      final venvResult = await Process.run(
        python,
        ['-m', 'venv', '.venv'],
        workingDirectory: dir,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        environment: _augmentedEnv(extraPath: p.isAbsolute(python) ? p.dirname(python) : null),
      );
      if (venvResult.exitCode != 0) {
        final msg = 'venv creation failed:\n${_sanitizeOutput(venvResult.stderr as String)}';
        onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
        return msg;
      }
    } catch (e) {
      final msg = 'venv creation threw: $e';
      onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
      return msg;
    }

    final normalizedSpec = _normalizeGithubBlobToRaw(def.packageName);
    final isRequirements = _looksLikeRequirementsSpec(normalizedSpec);
    onProgress?.call(
      GhMcpInstallProgress(
        GhMcpInstallStep.installing,
        isRequirements ? 'Installing dependencies from requirements file via pip...' : 'Installing $normalizedSpec via pip...',
      ),
    );

    try {
      final pipResult = await Process.run(
        _pipExe(dir),
        isRequirements ? ['install', '-r', normalizedSpec] : ['install', normalizedSpec],
        workingDirectory: dir,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        environment: _augmentedEnv(extraPath: p.isAbsolute(_pipExe(dir)) ? p.dirname(_pipExe(dir)) : null),
      );
      if (pipResult.exitCode != 0) {
        final msg = 'pip install failed:\n${_sanitizeOutput(pipResult.stderr as String)}';
        onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
        return msg;
      }
    } catch (e) {
      final msg = 'pip install threw: $e';
      onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
      return msg;
    }

    if (isRequirements) {
      final scriptPath = await _ensureRequirementsSourceScript(dir, normalizedSpec);
      if (scriptPath == null) {
        final msg = 'Installed requirements, but could not fetch a runnable Python script from the repository.';
        onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
        return msg;
      }

      onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.installing, 'Installing Playwright Chromium browsers...'));
      final browserInstallError = await _installPlaywrightBrowsers(dir);
      if (browserInstallError != null) {
        final msg = 'Installed requirements, but browser setup failed:\n$browserInstallError';
        onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
        return msg;
      }
    }

    onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.done, '${def.displayName} installed successfully.'));
    log.info('[GhMcpRuntime] pip install done: ${def.packageName}');
    return null;
  }

  Future<String?> _installNpm(GithubMcpServerDefinition def, {void Function(GhMcpInstallProgress)? onProgress}) async {
    onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.detecting, 'Checking for Node.js 18+...'));

    final node = await detectNode();
    if (node == null) {
      const msg =
          'Node.js 18 or newer not found on PATH.\n'
          'Install Node.js from https://nodejs.org and restart the app.';
      onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
      return msg;
    }

    final npm = _siblingTool(node, 'npm');
    onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.installing, 'Installing ${def.packageName} globally via npm...'));

    try {
      final result = await Process.run(
        npm,
        ['install', '-g', def.packageName],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        environment: _augmentedEnv(extraPath: p.isAbsolute(npm) ? p.dirname(npm) : null),
      );
      if (result.exitCode != 0) {
        final msg = 'npm install failed:\n${_sanitizeOutput(result.stderr as String)}';
        onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
        return msg;
      }
    } catch (e) {
      final msg = 'npm install threw: $e';
      onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
      return msg;
    }

    onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.done, '${def.displayName} installed successfully.'));
    log.info('[GhMcpRuntime] npm install done: ${def.packageName}');
    return null;
  }

  Future<String?> _installNpx(GithubMcpServerDefinition def, {void Function(GhMcpInstallProgress)? onProgress}) async {
    onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.detecting, 'Checking for Node.js 18+...'));

    final node = await detectNode();
    if (node == null) {
      const msg =
          'Node.js 18 or newer not found on PATH.\n'
          'Install Node.js from https://nodejs.org and restart the app.';
      onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
      return msg;
    }

    // npx downloads packages on-demand; no explicit install step is needed.
    onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.done, '${def.displayName} ready — package is fetched on first launch via npx.'));
    log.info('[GhMcpRuntime] npx/nodejs server marked ready: ${def.packageName}');
    return null;
  }

  // ─── Helpers ───────────────────────────────────────────────────────────────

  /// Strips non-printable and non-ASCII characters from process output so that
  /// Windows code-page issues (e.g. uv's box-drawing chars decoded as CP1252)
  /// do not produce garbled text in the UI.
  String _sanitizeOutput(String raw) {
    // Replace common Unicode arrows / bullets with ASCII equivalents
    var s = raw
        .replaceAll('\u00d7', 'x') // multiplication sign used by uv for errors
        .replaceAll('\u2192', '->')
        .replaceAll('\u2190', '<-')
        .replaceAll('\u2014', '--')
        .replaceAll('\u2013', '-')
        .replaceAll('\u2022', '*')
        .replaceAll('\u2026', '...');
    // Strip remaining non-ASCII (> U+007E) except newlines and tabs
    s = s.replaceAll(RegExp(r'[^\x09\x0A\x0D\x20-\x7E]'), '');
    // Collapse runs of blank lines
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }

  // ─── Smithery install ──────────────────────────────────────────────────────

  /// Install a Smithery-registered MCP server via the Smithery CLI.
  /// Runs: `npx -y @smithery/cli@latest mcp add <qualifiedName>`
  /// The [apiKey] is passed as the SMITHERY_API_KEY environment variable.
  Future<String?> installSmithery(String qualifiedName, {String? apiKey, void Function(GhMcpInstallProgress)? onProgress}) async {
    onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.detecting, 'Checking for Node.js 18+...'));

    final node = await detectNode();
    if (node == null) {
      const msg =
          'Node.js 18 or newer not found on PATH.\n'
          'Install Node.js from https://nodejs.org and restart the app.';
      onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
      return msg;
    }

    final npx = _siblingTool(node, 'npx');
    onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.installing, 'Running npx @smithery/cli mcp add $qualifiedName...'));

    try {
      final env = (apiKey != null && apiKey.isNotEmpty) ? {...Platform.environment, 'SMITHERY_API_KEY': apiKey} : null;
      final result = await Process.run(
        npx,
        ['-y', '@smithery/cli@latest', 'mcp', 'add', qualifiedName],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        environment: env,
      );
      if (result.exitCode != 0) {
        final msg = 'Smithery install failed:\n${_sanitizeOutput(result.stderr as String)}';
        onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
        return msg;
      }
    } catch (e) {
      final msg = 'Smithery install threw: $e';
      onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.failed, msg));
      return msg;
    }

    onProgress?.call(GhMcpInstallProgress(GhMcpInstallStep.done, '"$qualifiedName" installed successfully via Smithery CLI.'));
    log.info('[GhMcpRuntime] Smithery install done: $qualifiedName');
    return null;
  }

  // ─── Uninstall ─────────────────────────────────────────────────────────────

  /// Remove an installed server (deletes its pip venv directory if applicable).
  Future<void> uninstall(GithubMcpServerDefinition def) async {
    if (def.installType == 'pip') {
      final dir = await serverDir(def.id);
      final d = Directory(dir);
      if (await d.exists()) {
        await d.delete(recursive: true);
        log.info('[GhMcpRuntime] Deleted pip venv directory: $dir');
      }
    } else if (def.installType == 'npm') {
      // Remove the globally installed npm package.
      try {
        final node = await detectNode();
        final npm = node == null ? (Platform.isWindows ? 'npm.cmd' : 'npm') : _siblingTool(node, 'npm');
        final result = await Process.run(
          npm,
          ['uninstall', '-g', def.packageName],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
          environment: _augmentedEnv(extraPath: p.isAbsolute(npm) ? p.dirname(npm) : null),
        );
        if (result.exitCode != 0) {
          log.warning('[GhMcpRuntime] npm uninstall failed: ${_sanitizeOutput(result.stderr as String)}');
        } else {
          log.info('[GhMcpRuntime] npm uninstall done: ${def.packageName}');
        }
      } catch (e) {
        log.warning('[GhMcpRuntime] npm uninstall threw: $e');
      }
    }
    // For uvx and npx/nodejs we don't remove the cache — user can clear manually.
    await GithubMcpLibraryService.instance.delete(def.id);
    log.info('[GhMcpRuntime] Uninstalled: ${def.packageName}');
  }

  // ─── Launch ────────────────────────────────────────────────────────────────

  /// Launch the MCP server as a live process and return it.
  /// The process speaks MCP stdio (JSON-RPC 2.0 newline-delimited).
  Future<Process> launch(GithubMcpServerDefinition def) async {
    final args = _buildLaunchArgs(def);
    final env = _augmentedEnv(baseEnv: def.envVars);

    late String exe;
    late List<String> cmdArgs;

    if (def.installType == 'uvx') {
      final uvx = await detectUv();
      if (uvx == null) {
        throw const GhMcpRuntimeError('uvx not found. Install uv and restart the app.');
      }
      exe = uvx;
      cmdArgs = [def.effectiveEntryPoint, ...args];
    } else if (def.installType == 'npm') {
      // After global npm install the entry point binary is on PATH; npx finds it
      // without re-downloading and works cross-platform (no .cmd suffix needed).
      final node = await detectNode();
      if (node == null) {
        throw const GhMcpRuntimeError('Node.js 18+ not found. Install Node.js and restart the app.');
      }
      exe = _siblingTool(node, 'npx');
      cmdArgs = ['-y', def.effectiveEntryPoint, ...args];
    } else if (def.installType == 'npx' || def.installType == 'nodejs') {
      // No pre-install; npx downloads the package on-demand.
      final node = await detectNode();
      if (node == null) {
        throw const GhMcpRuntimeError('Node.js 18+ not found. Install Node.js and restart the app.');
      }
      exe = _siblingTool(node, 'npx');
      cmdArgs = ['-y', def.packageName, ...args];
    } else if (def.installType == 'smithery') {
      // Server was installed via the Smithery CLI; launch it through the CLI.
      final node = await detectNode();
      if (node == null) {
        throw const GhMcpRuntimeError('Node.js 18+ not found. Install Node.js and restart the app.');
      }
      exe = _siblingTool(node, 'npx');
      cmdArgs = ['-y', '@smithery/cli', 'run', def.packageName, ...args];
    } else {
      final dir = await serverDir(def.id);
      final pythonExe = _pythonVenvExe(dir);
      if (!await File(pythonExe).exists()) {
        final installError = await _installPip(def);
        if (installError != null) {
          throw GhMcpRuntimeError('Pip environment is missing and reinstall failed: $installError');
        }
      }

      final entryPoint = (def.entryPoint ?? '').trim();
      final requirementsStyle = _looksLikeRequirementsSpec(def.packageName) || _looksLikeRequirementsSpec(entryPoint);

      if (requirementsStyle) {
        final scriptPath = await _ensureRequirementsSourceScript(dir, def.packageName);
        if (scriptPath != null) {
          exe = pythonExe;
          cmdArgs = [scriptPath, ...args];
        } else {
          throw const GhMcpRuntimeError(
            'This pip server is a requirements-only repo and its runnable source script could not be fetched. '
            'The server must provide a Python file in the repository root (for example puppeteer.py).',
          );
        }
      } else {
        final module = entryPoint.isNotEmpty ? entryPoint : def.packageName;
        exe = pythonExe;
        cmdArgs = ['-m', module, ...args];
      }
    }

    log.info('[GhMcpRuntime] Launching: $exe ${cmdArgs.join(' ')}');

    try {
      return await Process.start(exe, cmdArgs, environment: env, mode: ProcessStartMode.normal);
    } catch (e) {
      throw GhMcpRuntimeError('Failed to launch ${def.displayName}: $e');
    }
  }

  /// Resolve {{placeholder}} tokens in launchArgs using envVars.
  List<String> _buildLaunchArgs(GithubMcpServerDefinition def) {
    return def.launchArgs
        .map((arg) {
          String resolved = arg;
          for (final kv in def.envVars.entries) {
            resolved = resolved.replaceAll('{{${kv.key}}}', kv.value);
          }
          // Drop unresolved placeholders to avoid passing literal "{{...}}" to process
          if (RegExp(r'\{\{.+?\}\}').hasMatch(resolved)) return null;
          // On Windows, normalize backslashes to forward slashes to avoid Win32
          // argument-quoting issues with trailing backslashes (e.g. c:\ → c:/)
          if (Platform.isWindows) {
            resolved = resolved.replaceAll('\\', '/');
          }
          return resolved;
        })
        .whereType<String>()
        .toList();
  }

  /// Launch the local MCP server temporarily to query its tools list.
  Future<List<String>> discoverLocalMcpTools(GithubMcpServerDefinition def) async {
    Process? process;
    StdioMcpClient? client;
    try {
      log.info('[GhMcpRuntime] Launching process for temporary discovery: ${def.name}');
      process = await launch(def);
      client = StdioMcpClient(process);

      // Handshake: initialize
      final initResp = await client.request('initialize', {
        'protocolVersion': '2024-11-05',
        'capabilities': {},
        'clientInfo': {'name': 'TealKit', 'version': '1.0'},
      }, timeout: const Duration(seconds: 15));

      if (initResp.containsKey('error')) {
        log.warning('[GhMcpRuntime] initialize error: ${initResp['error']}');
      }

      // ACK
      await client.notify('notifications/initialized', null);

      // list tools
      final resp = await client.request('tools/list', null, timeout: const Duration(seconds: 15));
      final list = (resp['result']?['tools'] as List<dynamic>?) ?? [];
      final toolNames = list
          .whereType<Map<String, dynamic>>()
          .map((t) => t['name'] as String)
          .toList();
      log.info('[GhMcpRuntime] Discovered ${toolNames.length} tools for local server ${def.name}');
      return toolNames;
    } catch (e) {
      log.warning('[GhMcpRuntime] Failed to discover local tools for ${def.name}: $e');
      return const [];
    } finally {
      if (client != null) {
        await client.dispose();
      } else {
        process?.kill();
      }
    }
  }
}

class GhMcpRuntimeError implements Exception {
  final String message;
  const GhMcpRuntimeError(this.message);
  @override
  String toString() => 'GhMcpRuntimeError: $message';
}

// ─── Stdio JSON-RPC 2.0 MCP client ────────────────────────────────────────────

/// A minimal stdio MCP client that sends/receives JSON-RPC 2.0 messages
/// via a child process stdin/stdout.
///
/// Used by [GithubMcpBridgeServer].
class StdioMcpClient {
  final Process _process;
  final StreamController<Map<String, dynamic>> _response = StreamController<Map<String, dynamic>>.broadcast();
  int _nextId = 1;
  late final StreamSubscription _stdoutSub;
  bool _disposed = false;

  StdioMcpClient(this._process) {
    _stdoutSub = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: (e) => log.warning('[StdioMCP] stdout error: $e'));

    _process.stderr.transform(utf8.decoder).listen((chunk) => log.verbose('[StdioMCP] stderr: ${chunk.trim()}'));
  }

  void _onLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    try {
      final msg = jsonDecode(trimmed) as Map<String, dynamic>;
      _response.add(msg);
    } catch (e) {
      log.warning('[StdioMCP] Unparseable line: $trimmed');
    }
  }

  /// Send a JSON-RPC 2.0 request and wait for the matching response.
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, dynamic>? params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final id = _nextId++;
    final envelope = {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': ?params}; // ignore: use_null_aware_elements
    _process.stdin.writeln(jsonEncode(envelope));
    await _process.stdin.flush();

    final completer = Completer<Map<String, dynamic>>();
    late StreamSubscription sub;
    sub = _response.stream.listen((msg) {
      if (msg['id'] == id) {
        sub.cancel();
        if (!completer.isCompleted) completer.complete(msg);
      }
    });

    return completer.future.timeout(
      timeout,
      onTimeout: () {
        sub.cancel();
        throw TimeoutException('MCP request "$method" timed out after ${timeout.inSeconds}s');
      },
    );
  }

  /// Send a JSON-RPC notification (no id, no response expected).
  Future<void> notify(String method, Map<String, dynamic>? params) async {
    final envelope = {'jsonrpc': '2.0', 'method': method, 'params': ?params}; // ignore: use_null_aware_elements
    _process.stdin.writeln(jsonEncode(envelope));
    await _process.stdin.flush();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _stdoutSub.cancel();
    await _response.close();
    _process.kill();
  }
}
