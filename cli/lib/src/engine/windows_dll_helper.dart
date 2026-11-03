import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Win32 API signature for SetDllDirectoryW
typedef SetDllDirectoryNative = Int32 Function(Pointer<Utf16> lpPathName);
typedef SetDllDirectoryDart = int Function(Pointer<Utf16> lpPathName);

/// Configures the Windows DLL search directory so that transitive native
/// dependencies (llamadart, llama, ggml, pdfium, etc.) can be located at runtime.
class WindowsDllHelper {
  static bool _configured = false;

  /// Ensures native DLL search paths are configured on Windows.
  /// Safe to call on Linux/macOS (no-op).
  static void ensureConfigured({List<String> additionalSearchPaths = const []}) {
    if (_configured || !Platform.isWindows) return;

    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final setDllDirectory = kernel32
          .lookupFunction<SetDllDirectoryNative, SetDllDirectoryDart>(
            'SetDllDirectoryW',
          );

      // Determine potential DLL candidate directories
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final scriptDir = Platform.script.toFilePath().isNotEmpty
          ? p.dirname(Platform.script.toFilePath())
          : exeDir;
      final cwd = Directory.current.path;

      final candidates = <String>[
        ...additionalSearchPaths,
        p.join(exeDir, 'lib'),
        exeDir,
        p.join(scriptDir, 'lib'),
        scriptDir,
        p.join(cwd, 'lib'),
        p.join(cwd, 'build', 'cli', 'bundle', 'lib'),
        p.join(cwd, '.dart_tool', 'hooks_runner'),
      ];

      // Prioritize directories that actually exist and contain native DLLs
      final candidateDirs = <String>[];
      for (final dirPath in candidates) {
        final dir = Directory(dirPath);
        if (dir.existsSync()) {
          candidateDirs.add(dirPath);
          try {
            // Also discover output directories inside hooks_runner or build
            for (final sub in dir.listSync(recursive: true, followLinks: false)) {
              if (sub is File && sub.path.toLowerCase().endsWith('.dll')) {
                final parent = p.dirname(sub.path);
                if (!candidateDirs.contains(parent)) {
                  candidateDirs.add(parent);
                }
              }
            }
          } catch (_) {}
        }
      }

      // Move directories with DLLs to the front
      candidateDirs.sort((a, b) {
        bool hasDll(String path) {
          try {
            return Directory(path).listSync().any((e) => e is File && e.path.toLowerCase().endsWith('.dll'));
          } catch (_) {
            return false;
          }
        }
        final aScore = hasDll(a) ? 0 : 1;
        final bScore = hasDll(b) ? 0 : 1;
        return aScore.compareTo(bScore);
      });

      for (final dirPath in candidateDirs) {
        final pathPtr = dirPath.toNativeUtf16();
        try {
          final result = setDllDirectory(pathPtr);
          if (result != 0) {
            _configured = true;
            break;
          }
        } finally {
          calloc.free(pathPtr);
        }
      }
    } catch (_) {
      // Graceful fallback if dynamic lookup fails
    }
  }
}

