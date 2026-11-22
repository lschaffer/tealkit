import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Sandboxed coding-workspace tools executed on the TealKit Server on behalf of
/// mobile/remote clients in Coding Mode.
///
/// Every path and command working directory is strictly jailed inside [rootDir]
/// (`resolveServerFilesDir()` / `TEALKIT_FILES_DIR`).
class ServerCodingTools {
  ServerCodingTools._();

  /// Resolves [requested] relative to [baseDir] and verifies the canonical path
  /// is equal to or inside [rootDir]. Throws [ArgumentError] on path traversal.
  static String resolveJailedPath(
    String rootDir,
    String baseDir,
    String? requested,
  ) {
    final normRoot = p.normalize(p.absolute(rootDir));
    final normBase = p.normalize(p.absolute(baseDir));
    if (!_isWithinOrEqual(normRoot, normBase)) {
      throw ArgumentError('Workspace "$baseDir" is outside server root directory.');
    }

    final raw = (requested ?? '').trim();
    if (raw.isEmpty || raw == '.') return normBase;

    final candidate = p.isAbsolute(raw)
        ? p.normalize(raw)
        : p.normalize(p.join(normBase, raw));

    if (!_isWithinOrEqual(normRoot, candidate)) {
      throw ArgumentError(
        'Access denied: path "$raw" resolves outside the server root directory.',
      );
    }
    return candidate;
  }

  static bool _isWithinOrEqual(String root, String target) {
    final r = Platform.isWindows ? root.toLowerCase() : root;
    final t = Platform.isWindows ? target.toLowerCase() : target;
    return p.equals(r, t) || p.isWithin(r, t);
  }

  /// Lists subdirectories under [currentPath] (defaulting to [rootDir]) for the
  /// mobile workspace folder picker.
  static Future<Map<String, dynamic>> listWorkspaceFolders(
    String rootDir, {
    String? currentPath,
  }) async {
    final root = p.normalize(p.absolute(rootDir));
    await Directory(root).create(recursive: true);

    final target = resolveJailedPath(root, root, currentPath);
    final dir = Directory(target);
    if (!await dir.exists()) {
      throw ArgumentError('Directory does not exist: $target');
    }

    final subdirs = <Map<String, String>>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is Directory) {
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        subdirs.add({
          'name': name,
          'path': p.normalize(entity.path),
        });
      }
    }
    subdirs.sort((a, b) => a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()));

    final parent = p.equals(root, target) ? null : p.normalize(p.dirname(target));
    return {
      'root_dir': root,
      'current_dir': target,
      'parent_dir': parent,
      'subdirectories': subdirs,
    };
  }

  /// Executes a coding tool (`fs_*`, `terminal_exec`, `fetch_web`) inside
  /// [workspace] (jailed to [rootDir]).
  static Future<Map<String, dynamic>> executeTool(
    String toolName, {
    required String rootDir,
    required String workspace,
    required Map<String, dynamic> arguments,
  }) async {
    try {
      final root = p.normalize(p.absolute(rootDir));
      await Directory(root).create(recursive: true);
      final ws = resolveJailedPath(root, root, workspace.isEmpty ? root : workspace);
      await Directory(ws).create(recursive: true);

      switch (toolName) {
        case 'fs_read_file':
          return await _readFile(root, ws, arguments);
        case 'fs_write_file':
          return await _writeFile(root, ws, arguments);
        case 'fs_replace_text':
          return await _replaceText(root, ws, arguments);
        case 'fs_list_dir':
          return await _listDir(root, ws, arguments);
        case 'fs_find':
          return await _findFiles(root, ws, arguments);
        case 'fs_create_dir':
          return await _createDir(root, ws, arguments);
        case 'fs_move':
          return await _movePath(root, ws, arguments);
        case 'fs_delete':
          return await _deletePath(root, ws, arguments);
        case 'terminal_exec':
          return await _terminalExec(root, ws, arguments);
        case 'fetch_web':
          return await _fetchWeb(arguments);
        default:
          return {'isError': true, 'content': 'Unknown coding tool: $toolName'};
      }
    } catch (e) {
      return {'isError': true, 'content': e.toString()};
    }
  }

  static Future<Map<String, dynamic>> _readFile(
    String root,
    String ws,
    Map<String, dynamic> args,
  ) async {
    final pathArg = (args['path'] as String? ?? '').trim();
    if (pathArg.isEmpty) return {'isError': true, 'content': 'Parameter "path" is required.'};
    final target = resolveJailedPath(root, ws, pathArg);
    final file = File(target);
    if (!await file.exists()) {
      return {'isError': true, 'content': 'File not found: $pathArg'};
    }
    final lines = await file.readAsLines();
    final startLine = ((args['start_line'] as num?)?.toInt() ?? 1).clamp(1, lines.isEmpty ? 1 : lines.length);
    final endLine = ((args['end_line'] as num?)?.toInt() ?? (startLine + 399)).clamp(startLine, lines.isEmpty ? 1 : lines.length);
    if (lines.isEmpty) {
      return {'isError': false, 'content': '(empty file)'};
    }
    final buf = StringBuffer();
    for (var i = startLine - 1; i < endLine && i < lines.length; i++) {
      buf.writeln('${i + 1}: ${lines[i]}');
    }
    return {'isError': false, 'content': buf.toString()};
  }

  static Future<Map<String, dynamic>> _writeFile(
    String root,
    String ws,
    Map<String, dynamic> args,
  ) async {
    final pathArg = (args['path'] as String? ?? '').trim();
    if (pathArg.isEmpty) return {'isError': true, 'content': 'Parameter "path" is required.'};
    final content = args['content'] as String? ?? '';
    final target = resolveJailedPath(root, ws, pathArg);
    final file = File(target);
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return {'isError': false, 'content': 'Wrote ${content.length} characters to $pathArg'};
  }

  static Future<Map<String, dynamic>> _replaceText(
    String root,
    String ws,
    Map<String, dynamic> args,
  ) async {
    final pathArg = (args['path'] as String? ?? '').trim();
    final targetText = (args['target'] ?? args['old_text'] ?? args['search']) as String? ?? '';
    final replacement = (args['replacement'] ?? args['new_text'] ?? args['replace']) as String? ?? '';
    if (pathArg.isEmpty || targetText.isEmpty) {
      return {'isError': true, 'content': 'Parameters "path" and "target" are required.'};
    }
    final target = resolveJailedPath(root, ws, pathArg);
    final file = File(target);
    if (!await file.exists()) {
      return {'isError': true, 'content': 'File not found: $pathArg'};
    }
    final existing = await file.readAsString();
    if (!existing.contains(targetText)) {
      return {'isError': true, 'content': 'Target text not found in $pathArg'};
    }
    final updated = existing.replaceFirst(targetText, replacement);
    await file.writeAsString(updated);
    return {'isError': false, 'content': 'Updated $pathArg successfully.'};
  }

  static Future<Map<String, dynamic>> _listDir(
    String root,
    String ws,
    Map<String, dynamic> args,
  ) async {
    final pathArg = (args['path'] as String? ?? '.').trim();
    final target = resolveJailedPath(root, ws, pathArg);
    final dir = Directory(target);
    if (!await dir.exists()) {
      return {'isError': true, 'content': 'Directory not found: $pathArg'};
    }
    final entries = <String>[];
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final isDir = entity is Directory;
      entries.add(isDir ? '[DIR]  $name/' : '[FILE] $name');
    }
    entries.sort();
    return {
      'isError': false,
      'content': entries.isEmpty ? '(empty directory)' : entries.join('\n'),
    };
  }

  static Future<Map<String, dynamic>> _findFiles(
    String root,
    String ws,
    Map<String, dynamic> args,
  ) async {
    final pathArg = (args['path'] as String? ?? '.').trim();
    final pattern = (args['pattern'] ?? args['query'] ?? args['glob']) as String? ?? '';
    final target = resolveJailedPath(root, ws, pathArg);
    final dir = Directory(target);
    if (!await dir.exists()) {
      return {'isError': true, 'content': 'Directory not found: $pathArg'};
    }
    final lowerPat = pattern.toLowerCase().replaceAll('*', '');
    final matches = <String>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (matches.length >= 200) break;
      final rel = p.relative(entity.path, from: ws);
      if (rel.split(p.separator).any((seg) => seg == '.git' || seg == 'node_modules' || seg == '.dart_tool')) {
        continue;
      }
      if (lowerPat.isEmpty || rel.toLowerCase().contains(lowerPat)) {
        matches.add(rel);
      }
    }
    return {
      'isError': false,
      'content': matches.isEmpty ? 'No matching files found.' : matches.join('\n'),
    };
  }

  static Future<Map<String, dynamic>> _createDir(
    String root,
    String ws,
    Map<String, dynamic> args,
  ) async {
    final pathArg = (args['path'] as String? ?? '').trim();
    if (pathArg.isEmpty) return {'isError': true, 'content': 'Parameter "path" is required.'};
    final target = resolveJailedPath(root, ws, pathArg);
    await Directory(target).create(recursive: true);
    return {'isError': false, 'content': 'Created directory: $pathArg'};
  }

  static Future<Map<String, dynamic>> _movePath(
    String root,
    String ws,
    Map<String, dynamic> args,
  ) async {
    final srcArg = (args['source'] ?? args['from']) as String? ?? '';
    final dstArg = (args['destination'] ?? args['to']) as String? ?? '';
    if (srcArg.isEmpty || dstArg.isEmpty) {
      return {'isError': true, 'content': 'Parameters "source" and "destination" are required.'};
    }
    final src = resolveJailedPath(root, ws, srcArg);
    final dst = resolveJailedPath(root, ws, dstArg);
    final type = FileSystemEntity.typeSync(src);
    if (type == FileSystemEntityType.file) {
      await File(dst).parent.create(recursive: true);
      await File(src).rename(dst);
    } else if (type == FileSystemEntityType.directory) {
      await Directory(src).rename(dst);
    } else {
      return {'isError': true, 'content': 'Source not found: $srcArg'};
    }
    return {'isError': false, 'content': 'Moved $srcArg -> $dstArg'};
  }

  static Future<Map<String, dynamic>> _deletePath(
    String root,
    String ws,
    Map<String, dynamic> args,
  ) async {
    final pathArg = (args['path'] as String? ?? '').trim();
    if (pathArg.isEmpty) return {'isError': true, 'content': 'Parameter "path" is required.'};
    final target = resolveJailedPath(root, ws, pathArg);
    if (p.equals(root, target)) {
      return {'isError': true, 'content': 'Cannot delete the server root directory.'};
    }
    final type = FileSystemEntity.typeSync(target);
    if (type == FileSystemEntityType.file) {
      await File(target).delete();
    } else if (type == FileSystemEntityType.directory) {
      await Directory(target).delete(recursive: true);
    } else {
      return {'isError': true, 'content': 'Path not found: $pathArg'};
    }
    return {'isError': false, 'content': 'Deleted $pathArg'};
  }

  static Future<Map<String, dynamic>> _terminalExec(
    String root,
    String ws,
    Map<String, dynamic> args,
  ) async {
    final command = (args['command'] as String? ?? '').trim();
    if (command.isEmpty) return {'isError': true, 'content': 'Parameter "command" is required.'};
    final cwdArg = (args['working_directory'] ?? args['cwd']) as String?;
    final cwd = resolveJailedPath(root, ws, cwdArg);

    final shell = Platform.isWindows ? 'powershell.exe' : '/bin/sh';
    final shellArgs = Platform.isWindows
        ? ['-NoProfile', '-Command', command]
        : ['-c', command];

    final res = await Process.run(
      shell,
      shellArgs,
      workingDirectory: cwd,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 120));

    final out = StringBuffer();
    if ((res.stdout as String).isNotEmpty) out.writeln(res.stdout);
    if ((res.stderr as String).isNotEmpty) out.writeln('[stderr]\n${res.stderr}');
    out.writeln('Exit code: ${res.exitCode}');
    return {
      'isError': res.exitCode != 0,
      'content': out.toString().trim(),
    };
  }

  static Future<Map<String, dynamic>> _fetchWeb(Map<String, dynamic> args) async {
    final urlStr = (args['url'] as String? ?? '').trim();
    final uri = Uri.tryParse(urlStr);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return {'isError': true, 'content': 'Valid http/https "url" is required.'};
    }
    final resp = await http.get(uri).timeout(const Duration(seconds: 30));
    final body = resp.body.length > 20000 ? resp.body.substring(0, 20000) : resp.body;
    return {
      'isError': resp.statusCode < 200 || resp.statusCode >= 300,
      'content': 'HTTP ${resp.statusCode}\n$body',
    };
  }
}
