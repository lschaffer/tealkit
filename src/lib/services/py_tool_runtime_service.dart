import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/py_tool_definition.dart';
import 'app_logger.dart';
import 'py_tool_library_service.dart';

// ═══════════════════════════════════════════════════════════════
// Init progress events
// ═══════════════════════════════════════════════════════════════

enum PyInitStep { creatingVenv, installingDeps, done, failed }

class PyInitProgress {
  final PyInitStep step;
  final String message;
  const PyInitProgress(this.step, this.message);
}

// ═══════════════════════════════════════════════════════════════
// Runtime service
// ═══════════════════════════════════════════════════════════════

/// Manages Python tool runtime: venv init and per-call process execution.
///
/// **Communication protocol**
/// Each tool invocation launches a fresh Python process:
///   stdin  → one JSON line:  {"tool": "<name>", "args": {...}}\n
///   stdout → one JSON line:  {"success": true/false, "result": ..., "error": "..."}\n
///   stderr → forwarded to app log
///
/// Keeping processes alive is intentionally avoided for simplicity and
/// because user-generated scripts may hold resources; stateless per-call
/// is safer and easier to reason about.
class PyToolRuntimeService {
  PyToolRuntimeService._();
  static final instance = PyToolRuntimeService._();

  // ─── Python executable detection ──────────────────────────────────────────

  /// Returns the python executable path for a given tool directory.
  /// Prefers the venv interpreter if it exists.
  String _pythonExe(String toolDir) {
    if (Platform.isWindows) {
      final venvExe = p.join(toolDir, '.venv', 'Scripts', 'python.exe');
      if (File(venvExe).existsSync()) return venvExe;
      return 'python'; // fall back to system python
    } else {
      final venvExe = p.join(toolDir, '.venv', 'bin', 'python');
      if (File(venvExe).existsSync()) return venvExe;
      return 'python3';
    }
  }

  /// Returns the pip executable inside the venv.
  String _pipExe(String toolDir) {
    if (Platform.isWindows) {
      return p.join(toolDir, '.venv', 'Scripts', 'pip.exe');
    } else {
      return p.join(toolDir, '.venv', 'bin', 'pip');
    }
  }

  // ─── Init (create venv + install deps) ─────────────────────────────────

  /// Detects whether a working Python 3 is available on PATH.
  Future<String?> detectSystemPython() async {
    final candidates = Platform.isWindows
        ? ['python', 'python3']
        : [
            // PATH-based lookups first.
            'python3',
            'python',
            // Absolute paths cover GUI app launches where PATH can be minimal.
            '/usr/local/bin/python3',
            '/opt/homebrew/bin/python3',
            '/usr/bin/python3',
            '/usr/local/opt/python@3.14/libexec/bin/python',
            '/Library/Frameworks/Python.framework/Versions/Current/bin/python3',
          ];
    for (final exe in candidates) {
      try {
        final result = await Process.run(exe, ['--version']);
        final out = (result.stdout as String?) ?? '';
        final err = (result.stderr as String?) ?? '';
        final version = (out.isNotEmpty ? out : err).trim();
        if (result.exitCode == 0 &&
            version.toLowerCase().contains('python 3')) {
          log.info('[PyRuntime] Detected system Python: $exe → $version');
          return exe;
        }
      } catch (_) {
        // not found
      }
    }
    return null;
  }

  /// Initialises the venv and installs dependencies.
  /// Yields [PyInitProgress] events via [onProgress].
  /// Returns null on success, or an error string on failure.
  Future<String?> initTool(
    PyToolDefinition def, {
    void Function(PyInitProgress)? onProgress,
  }) async {
    final lib = PyToolLibraryService.instance;
    final dir = await lib.toolDir(def.id);

    // Step 1 – detect python
    final sysPython = await detectSystemPython();
    if (sysPython == null) {
      const msg =
          'Python 3 was not found on the system PATH.\n'
          'Please install Python 3 from https://python.org and make sure it is in PATH.';
      onProgress?.call(const PyInitProgress(PyInitStep.failed, msg));
      return msg;
    }

    // Step 2 – create venv
    onProgress?.call(
      const PyInitProgress(
        PyInitStep.creatingVenv,
        'Creating virtual environment…',
      ),
    );
    try {
      final venvResult = await Process.run(sysPython, [
        '-m',
        'venv',
        '.venv',
      ], workingDirectory: dir);
      if (venvResult.exitCode != 0) {
        final msg = 'venv creation failed:\n${venvResult.stderr}';
        onProgress?.call(PyInitProgress(PyInitStep.failed, msg));
        return msg;
      }
    } catch (e) {
      final msg = 'venv creation threw: $e';
      onProgress?.call(PyInitProgress(PyInitStep.failed, msg));
      return msg;
    }

    // Step 3 – install requirements (if any non-empty lines)
    final reqs = def.requirements.trim();
    final hasReqs =
        reqs.isNotEmpty &&
        reqs
            .split('\n')
            .any((l) => l.trim().isNotEmpty && !l.trim().startsWith('#'));
    if (hasReqs) {
      onProgress?.call(
        const PyInitProgress(
          PyInitStep.installingDeps,
          'Installing dependencies from requirements.txt…',
        ),
      );
      try {
        final reqsFile = p.join(dir, 'requirements.txt');
        final pipResult = await Process.run(_pipExe(dir), [
          'install',
          '-r',
          reqsFile,
        ], workingDirectory: dir);
        if (pipResult.exitCode != 0) {
          final msg = 'pip install failed:\n${pipResult.stderr}';
          onProgress?.call(PyInitProgress(PyInitStep.failed, msg));
          return msg;
        }
      } catch (e) {
        final msg = 'pip install threw: $e';
        onProgress?.call(PyInitProgress(PyInitStep.failed, msg));
        return msg;
      }
    }

    // Mark ready
    await lib.setVenvReady(def.id, ready: true);
    onProgress?.call(
      const PyInitProgress(PyInitStep.done, 'Python tool ready.'),
    );
    log.info('[PyRuntime] initTool done: ${def.id}');
    return null;
  }

  // ─── Execute ──────────────────────────────────────────────────────────────

  /// Runs the Python tool with [args].
  /// Launches a fresh process, sends one JSON request to stdin, waits for
  /// one JSON response on stdout.
  ///
  /// Returns the parsed result map, or throws a [PyToolError].
  Future<Map<String, dynamic>> execute(
    PyToolDefinition def,
    Map<String, dynamic> args, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final dir = await PyToolLibraryService.instance.toolDir(def.id);
    final mainPy = p.join(dir, 'main.py');

    if (!File(mainPy).existsSync()) {
      throw PyToolError('main.py not found for tool "${def.name}"');
    }

    final exe = _pythonExe(dir);
    log.info('[PyRuntime] Launching: $exe $mainPy  args=${jsonEncode(args)}');

    Process process;
    try {
      process = await Process.start(
        exe,
        [mainPy],
        workingDirectory: dir,
        mode: ProcessStartMode.normal,
      );
    } catch (e) {
      throw PyToolError('Failed to start Python process: $e');
    }

    // Collect stderr for diagnostics
    final stderrBuf = StringBuffer();
    final stderrDone = process.stderr.transform(utf8.decoder).forEach((chunk) {
      stderrBuf.write(chunk);
      log.warning('[PyRuntime][${def.name}] stderr: $chunk');
    });

    // Send request
    final request = jsonEncode({'tool': def.name, 'args': args});
    process.stdin.writeln(request);
    await process.stdin.flush();
    await process.stdin.close();

    // Read first response line (with timeout)
    String? responseLine;
    try {
      responseLine = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .firstWhere((l) => l.trim().isNotEmpty)
          .timeout(timeout);
    } on TimeoutException {
      process.kill();
      await stderrDone.catchError((_) {});
      final stderrOut = stderrBuf.toString().trim();
      if (stderrOut.isNotEmpty) {
        log.error('[PyRuntime][${def.name}] stderr on timeout:\n$stderrOut');
      }
      throw PyToolError(
        'Tool "${def.name}" timed out after ${timeout.inSeconds}s',
      );
    } catch (e) {
      process.kill();
      await stderrDone.catchError((_) {});
      final stderrOut = stderrBuf.toString().trim();
      if (stderrOut.isNotEmpty) {
        log.error('[PyRuntime][${def.name}] stderr on error:\n$stderrOut');
      }
      log.error('[PyRuntime][${def.name}] stdout read error: $e');
      throw PyToolError(
        'Error reading output from "${def.name}": $e\n${stderrOut.isNotEmpty ? "stderr: $stderrOut" : ""}',
      );
    } finally {
      // Ensure process is cleaned up
      process.kill(ProcessSignal.sigterm);
    }

    // Parse response – accept both the protocol format {"success":true,"result":...}
    // and bare JSON values (list, string, number) emitted by tools that don't use _main().
    Map<String, dynamic> response;
    try {
      final decoded = jsonDecode(responseLine);
      if (decoded is Map<String, dynamic>) {
        response = decoded;
      } else {
        // Bare value → treat as a successful result
        response = {'success': true, 'result': decoded};
      }
    } catch (e) {
      throw PyToolError(
        'Invalid JSON response from "${def.name}": $responseLine',
      );
    }

    final success = response['success'] as bool? ?? false;
    if (!success) {
      final err = response['error']?.toString() ?? 'Unknown error';
      throw PyToolError('Tool "${def.name}" returned error: $err');
    }

    final result = response['result'];
    if (result is Map<String, dynamic>) return result;
    // Wrap primitive results
    return {'output': result};
  }
}

// ─── Error type ──────────────────────────────────────────────────────────────

class PyToolError implements Exception {
  final String message;
  const PyToolError(this.message);
  @override
  String toString() => 'PyToolError: $message';
}

// ═══════════════════════════════════════════════════════════════
// Python code template
// ═══════════════════════════════════════════════════════════════

/// The boilerplate injected around every LLM-generated tool.
///
/// The LLM fills in:
///   • The docstring / module comment
///   • Any imports it needs
///   • The body of [execute()]
const String pyToolTemplate = r'''#!/usr/bin/env python3
"""
TealKit Python Tool
===================
<LLM fills in description here>
"""
# ── stdlib imports (always available) ─────────────────────────
import sys
import json
import os
import shutil
from pathlib import Path

# ── third-party imports (listed in requirements.txt) ──────────
# <LLM adds imports here>


# ══════════════════════════════════════════════════════════════
# MAIN LOGIC  –  edit inside this function
# ══════════════════════════════════════════════════════════════

def execute(args: dict) -> object:
    """
    Called with the JSON args sent by TealKit.
    Return any JSON-serialisable value (dict, list, str, …).
    Raise an exception to signal an error.
    """
    # <LLM implements the tool logic here>
    return {"message": "not implemented"}


# ══════════════════════════════════════════════════════════════
# JSON-LINE STDIO PROTOCOL  –  do not modify below this line
# ══════════════════════════════════════════════════════════════

def _main():
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            result  = execute(request.get("args", {}))
            print(json.dumps({"success": True,  "result": result}), flush=True)
        except Exception as exc:
            print(json.dumps({"success": False, "error":  str(exc)}), flush=True)


if __name__ == "__main__":
    _main()
''';

/// System prompt injected into the LLM context when generating a Python tool.
const String pyToolGenerationSystemPrompt = '''
You are generating a TealKit Python Tool.
Produce a JSON object with EXACTLY these keys:
  "name"         – short snake_case tool name
  "description"  – one sentence description
  "inputSchema"  – JSON Schema (type:object, properties, required[])
  "code"         – complete main.py source (use the template structure below)
  "requirements" – requirements.txt content (empty string if only stdlib needed)

The code MUST follow this structure:
  1. Module docstring + any third-party imports
  2. def execute(args: dict) -> object: — implement the logic here
  3. The JSON-line stdio section below MUST be copied VERBATIM at the end — do NOT modify it.

Copy this section EXACTLY at the end of every generated script (do not alter a single character):

# ===== TEALKIT STDIO PROTOCOL (DO NOT EDIT BELOW) =====
import sys
import json

def _main():
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            result  = execute(request.get("args", {}))
            print(json.dumps({"success": True,  "result": result}), flush=True)
        except Exception as exc:
            print(json.dumps({"success": False, "error":  str(exc)}), flush=True)

if __name__ == "__main__":
    _main()

Respond with ONLY the JSON object, no markdown fences.
''';
