import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:uuid/uuid.dart';
import '../models/mcp_models.dart';
import '../utils/logger.dart';

/// Helper service to read images and files from system clipboard on desktop platforms.
class DesktopClipboardService {
  static const _uuid = Uuid();

  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// Inspect the desktop clipboard for image data or copied files.
  /// Returns a list of [MessageAttachment] if found, or empty list if clipboard
  /// contains only plain text or is empty.
  static Future<List<MessageAttachment>> getClipboardAttachments() async {
    if (!isDesktop) return [];

    try {
      if (Platform.isWindows) {
        return await _getWindowsClipboardAttachments();
      } else if (Platform.isMacOS) {
        return await _getMacClipboardAttachments();
      } else if (Platform.isLinux) {
        return await _getLinuxClipboardAttachments();
      }
    } catch (e) {
      talker.warning('Desktop clipboard check failed: $e');
    }
    return [];
  }

  /// Create a [MessageAttachment] from an existing file path on disk.
  static Future<MessageAttachment?> createAttachmentFromFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();
      final name = file.uri.pathSegments.isNotEmpty
          ? file.uri.pathSegments.last
          : 'file';
      final mimeType = lookupMimeType(filePath) ?? 'application/octet-stream';
      final isImage = mimeType.startsWith('image/');

      return MessageAttachment(
        id: _uuid.v4(),
        type: isImage ? AttachmentType.image : AttachmentType.file,
        path: filePath,
        name: name,
        size: bytes.length,
        mimeType: mimeType,
        bytes: bytes,
      );
    } catch (e) {
      talker.warning('Failed to create attachment from file ($filePath): $e');
      return null;
    }
  }

  static Future<List<MessageAttachment>> _getWindowsClipboardAttachments() async {
    final tempDir = Directory.systemTemp.path;
    final tempImgPath =
        '$tempDir\\clip_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 8)}.png';

    // Powershell script to check image and file drop list without external dependencies
    final script = '''
Add-Type -AssemblyName System.Windows.Forms;
Add-Type -AssemblyName System.Drawing;
if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
    \$img = [System.Windows.Forms.Clipboard]::GetImage();
    \$img.Save('$tempImgPath', [System.Drawing.Imaging.ImageFormat]::Png);
    \$img.Dispose();
    Write-Output "IMAGE:$tempImgPath";
} elseif ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
    \$files = [System.Windows.Forms.Clipboard]::GetFileDropList();
    Write-Output ("FILES:" + (\$files -join "|"));
} else {
    Write-Output "NONE";
}
''';

    final result = await Process.run(
      'powershell',
      ['-NoProfile', '-NonInteractive', '-Command', script],
      runInShell: true,
    );

    if (result.exitCode != 0) {
      return [];
    }

    final output = (result.stdout as String).trim();
    final attachments = <MessageAttachment>[];

    for (final line in output.split(RegExp(r'[\r\n]+'))) {
      final trimmed = line.trim();
      if (trimmed.startsWith('IMAGE:')) {
        final path = trimmed.substring(6).trim();
        final att = await createAttachmentFromFile(path);
        if (att != null) attachments.add(att);
      } else if (trimmed.startsWith('FILES:')) {
        final rawFiles = trimmed.substring(6).trim();
        final filePaths = rawFiles.split('|').map((s) => s.trim()).where((s) => s.isNotEmpty);
        for (final p in filePaths) {
          final att = await createAttachmentFromFile(p);
          if (att != null) attachments.add(att);
        }
      }
    }

    return attachments;
  }

  static Future<List<MessageAttachment>> _getMacClipboardAttachments() async {
    final tempDir = Directory.systemTemp.path;
    final tempImgPath =
        '$tempDir/clip_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 8)}.png';

    final script = '''
try
    set theData to the clipboard as «class PNGf»
    set fp to open for access POSIX file "$tempImgPath" with write permission
    write theData to fp
    close access fp
    return "IMAGE:$tempImgPath"
on error
    return "NONE"
end try
''';

    final result = await Process.run('osascript', ['-e', script]);
    if (result.exitCode != 0) return [];

    final output = (result.stdout as String).trim();
    if (output.startsWith('IMAGE:')) {
      final path = output.substring(6).trim();
      final att = await createAttachmentFromFile(path);
      if (att != null) return [att];
    }
    return [];
  }

  static Future<List<MessageAttachment>> _getLinuxClipboardAttachments() async {
    final tempDir = Directory.systemTemp.path;
    final tempImgPath =
        '$tempDir/clip_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 8)}.png';

    // Try xclip first, then wl-paste for Wayland
    var result = await Process.run(
      'xclip',
      ['-selection', 'clipboard', '-t', 'image/png', '-o'],
    );
    if (result.exitCode != 0 || (result.stdout as List<int>).isEmpty) {
      result = await Process.run(
        'wl-paste',
        ['--type', 'image/png'],
      );
    }

    if (result.exitCode == 0 && result.stdout is List<int>) {
      final bytes = Uint8List.fromList(result.stdout as List<int>);
      if (bytes.isNotEmpty) {
        await File(tempImgPath).writeAsBytes(bytes);
        final att = await createAttachmentFromFile(tempImgPath);
        if (att != null) return [att];
      }
    }
    return [];
  }
}
