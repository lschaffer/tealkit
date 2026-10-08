import 'dart:io';
import 'dart:typed_data';

/// Represents extracted content from the clipboard.
class CliClipboardData {
  final bool isImage;
  final String? text;
  final Uint8List? imageBytes;
  final String? imagePath;
  final String mimeType;

  CliClipboardData({
    required this.isImage,
    this.text,
    this.imageBytes,
    this.imagePath,
    this.mimeType = 'text/plain',
  });
}

/// Cross-platform clipboard helper for TealKit CLI without Flutter GUI.
class CliClipboardHelper {
  /// Extracts the clipboard content (image or text).
  /// If it's an image, saves it to ~/.tealkit/temp/clip_<timestamp>.png.
  static Future<CliClipboardData?> getClipboardContent() async {
    final tempDir = await _getTempDir();

    if (Platform.isWindows) {
      return await _getWindowsClipboard(tempDir);
    } else if (Platform.isMacOS) {
      return await _getMacClipboard(tempDir);
    } else if (Platform.isLinux) {
      return await _getLinuxClipboard(tempDir);
    }
    return null;
  }

  static Future<Directory> _getTempDir() async {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        Directory.current.path;
    final dir = Directory('$home/.tealkit/temp');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<CliClipboardData?> _getWindowsClipboard(Directory tempDir) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final imagePath = '${tempDir.path}/clip_$timestamp.png';

    // PowerShell script checking for image first, then text
    final psScript = '''
Add-Type -AssemblyName System.Windows.Forms;
\$img = [System.Windows.Forms.Clipboard]::GetImage();
if (\$img) {
  \$img.Save('$imagePath', [System.Drawing.Imaging.ImageFormat]::Png);
  Write-Output "CLIP_TYPE:IMAGE:$imagePath";
  Exit 0;
}
\$txt = [System.Windows.Forms.Clipboard]::GetText();
if (\$txt) {
  Write-Output "CLIP_TYPE:TEXT";
  Write-Output \$txt;
  Exit 0;
}
Write-Output "CLIP_TYPE:EMPTY";
''';

    try {
      final res = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        psScript,
      ]);

      final stdout = res.stdout.toString().trim();
      if (stdout.startsWith('CLIP_TYPE:IMAGE:')) {
        final imgFile = File(imagePath);
        if (imgFile.existsSync()) {
          final bytes = await imgFile.readAsBytes();
          return CliClipboardData(
            isImage: true,
            imageBytes: bytes,
            imagePath: imgFile.path,
            mimeType: 'image/png',
          );
        }
      } else if (stdout.startsWith('CLIP_TYPE:TEXT')) {
        final lines = stdout.split('\n');
        final text = lines.skip(1).join('\n').trim();
        if (text.isNotEmpty) {
          return CliClipboardData(
            isImage: false,
            text: text,
            mimeType: 'text/plain',
          );
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<CliClipboardData?> _getMacClipboard(Directory tempDir) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final imagePath = '${tempDir.path}/clip_$timestamp.png';

    // Try pngpaste first if installed
    try {
      final pngResult = await Process.run('pngpaste', [imagePath]);
      if (pngResult.exitCode == 0) {
        final imgFile = File(imagePath);
        if (imgFile.existsSync()) {
          final bytes = await imgFile.readAsBytes();
          return CliClipboardData(
            isImage: true,
            imageBytes: bytes,
            imagePath: imgFile.path,
            mimeType: 'image/png',
          );
        }
      }
    } catch (_) {}

    // Fallback to pbpaste for text
    try {
      final res = await Process.run('pbpaste', []);
      final text = res.stdout.toString();
      if (text.trim().isNotEmpty) {
        return CliClipboardData(
          isImage: false,
          text: text,
          mimeType: 'text/plain',
        );
      }
    } catch (_) {}

    return null;
  }

  static Future<CliClipboardData?> _getLinuxClipboard(Directory tempDir) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final imagePath = '${tempDir.path}/clip_$timestamp.png';

    // Try wl-paste (Wayland)
    try {
      final res = await Process.run('wl-paste', ['--type', 'image/png']);
      if (res.exitCode == 0 && res.stdout is List<int> && (res.stdout as List<int>).isNotEmpty) {
        final bytes = Uint8List.fromList(res.stdout as List<int>);
        await File(imagePath).writeAsBytes(bytes);
        return CliClipboardData(
          isImage: true,
          imageBytes: bytes,
          imagePath: imagePath,
          mimeType: 'image/png',
        );
      }
    } catch (_) {}

    // Try xclip (X11)
    try {
      final imgFile = File(imagePath);
      final res = await Process.run('xclip', [
        '-selection',
        'clipboard',
        '-t',
        'image/png',
        '-o',
      ]);
      if (res.exitCode == 0 && res.stdout is List<int> && (res.stdout as List<int>).isNotEmpty) {
        final bytes = Uint8List.fromList(res.stdout as List<int>);
        await imgFile.writeAsBytes(bytes);
        return CliClipboardData(
          isImage: true,
          imageBytes: bytes,
          imagePath: imagePath,
          mimeType: 'image/png',
        );
      }
    } catch (_) {}

    return null;
  }
}
