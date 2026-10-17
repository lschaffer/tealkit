import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:uuid/uuid.dart';
import '../models/mcp_models.dart';
import '../utils/logger.dart';
import '../utils/image_downscaler.dart';

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
  static Future<MessageAttachment?> createAttachmentFromFile(
    String filePath,
  ) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final bytes = await file.readAsBytes();
      final name = file.uri.pathSegments.isNotEmpty
          ? file.uri.pathSegments.last
          : 'file';
      final mimeType = lookupMimeType(filePath) ?? 'application/octet-stream';
      final isImage = mimeType.startsWith('image/');

      var finalBytes = bytes;
      var finalMime = mimeType;
      if (isImage) {
        final downscaled = await ImageDownscaler.downscaleIfNeeded(
          bytes: bytes,
          originalMimeType: mimeType,
        );
        finalBytes = downscaled.bytes;
        finalMime = downscaled.mimeType;
      }

      return MessageAttachment(
        id: _uuid.v4(),
        type: isImage ? AttachmentType.image : AttachmentType.file,
        path: filePath,
        name: name,
        size: finalBytes.length,
        mimeType: finalMime,
        bytes: finalBytes,
      );
    } catch (e) {
      talker.warning('Failed to create attachment from file ($filePath): $e');
      return null;
    }
  }

  static Future<List<MessageAttachment>>
  _getWindowsClipboardAttachments() async {
    try {
      final attachments = <MessageAttachment>[];
      final imgBytes = _getWindowsClipboardDIB();
      if (imgBytes != null && imgBytes.isNotEmpty) {
        final tempDir = Directory.systemTemp.path;
        final tempImgPath =
            '$tempDir\\clip_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 8)}.bmp';
        final f = File(tempImgPath);
        await f.writeAsBytes(imgBytes);

        var finalBytes = imgBytes;
        var finalMime = 'image/bmp';
        final downscaled = await ImageDownscaler.downscaleIfNeeded(
          bytes: imgBytes,
          originalMimeType: 'image/bmp',
        );
        finalBytes = downscaled.bytes;
        finalMime = downscaled.mimeType;

        attachments.add(
          MessageAttachment(
            id: _uuid.v4(),
            type: AttachmentType.image,
            path: tempImgPath,
            name: 'clipboard_image.png',
            size: finalBytes.length,
            mimeType: finalMime,
            bytes: finalBytes,
          ),
        );
        return attachments;
      }

      final files = _getWindowsClipboardFileList();
      if (files.isNotEmpty) {
        for (final p in files) {
          final att = await createAttachmentFromFile(p);
          if (att != null) attachments.add(att);
        }
        if (attachments.isNotEmpty) return attachments;
      }
    } catch (e) {
      talker.warning('Windows FFI clipboard read failed: $e');
    }
    return [];
  }

  static Uint8List? _getWindowsClipboardDIB() {
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final kernel32 = DynamicLibrary.open('kernel32.dll');

      final isFormatAvailable = user32
          .lookupFunction<Int32 Function(Uint32), int Function(int)>(
            'IsClipboardFormatAvailable',
          );
      const cfDib = 8;
      if (isFormatAvailable(cfDib) == 0) return null;

      final openClip = user32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'OpenClipboard',
          );
      final closeClip = user32.lookupFunction<Int32 Function(), int Function()>(
        'CloseClipboard',
      );
      final getClipData = user32
          .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
            'GetClipboardData',
          );
      final gLock = kernel32
          .lookupFunction<
            Pointer<Uint8> Function(IntPtr),
            Pointer<Uint8> Function(int)
          >('GlobalLock');
      final gUnlock = kernel32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'GlobalUnlock',
          );
      final gSize = kernel32
          .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
            'GlobalSize',
          );

      if (openClip(0) == 0) return null;
      try {
        final hMem = getClipData(cfDib);
        if (hMem == 0) return null;
        final ptr = gLock(hMem);
        if (ptr.address == 0) return null;
        try {
          final size = gSize(hMem);
          if (size < 40) return null;

          final dibData = ptr.asTypedList(size);
          final bd = ByteData.sublistView(dibData);
          final biSize = bd.getUint32(0, Endian.little);
          final biBitCount = bd.getUint16(14, Endian.little);
          final biClrUsed = bd.getUint32(32, Endian.little);
          final biCompression = bd.getUint32(16, Endian.little);

          int paletteSize = 0;
          if (biClrUsed != 0) {
            paletteSize = biClrUsed * 4;
          } else if (biBitCount <= 8) {
            paletteSize = (1 << biBitCount) * 4;
          } else if (biCompression == 3) {
            paletteSize = 12;
          }

          final totalHeader = biSize + paletteSize;
          final totalFileSize = 14 + size;

          final bmp = Uint8List(totalFileSize);
          final bdata = ByteData.sublistView(bmp);
          bdata.setUint8(0, 0x42); // 'B'
          bdata.setUint8(1, 0x4D); // 'M'
          bdata.setUint32(2, totalFileSize, Endian.little);
          bdata.setUint16(6, 0, Endian.little);
          bdata.setUint16(8, 0, Endian.little);
          bdata.setUint32(10, 14 + totalHeader, Endian.little);
          bmp.setRange(14, 14 + size, dibData);
          return bmp;
        } finally {
          gUnlock(hMem);
        }
      } finally {
        closeClip();
      }
    } catch (e) {
      talker.warning('Windows DIB extraction error: $e');
      return null;
    }
  }

  static List<String> _getWindowsClipboardFileList() {
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final shell32 = DynamicLibrary.open('shell32.dll');

      final isFormatAvailable = user32
          .lookupFunction<Int32 Function(Uint32), int Function(int)>(
            'IsClipboardFormatAvailable',
          );
      const cfHdrop = 15;
      if (isFormatAvailable(cfHdrop) == 0) return [];

      final openClip = user32
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'OpenClipboard',
          );
      final closeClip = user32.lookupFunction<Int32 Function(), int Function()>(
        'CloseClipboard',
      );
      final getClipData = user32
          .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
            'GetClipboardData',
          );
      final dragQueryFileW = shell32
          .lookupFunction<
            Uint32 Function(IntPtr, Uint32, Pointer<Uint16>, Uint32),
            int Function(int, int, Pointer<Uint16>, int)
          >('DragQueryFileW');
      final getHeap = kernel32
          .lookupFunction<IntPtr Function(), int Function()>('GetProcessHeap');
      final hAlloc = kernel32
          .lookupFunction<
            Pointer<Uint16> Function(IntPtr, Uint32, IntPtr),
            Pointer<Uint16> Function(int, int, int)
          >('HeapAlloc');
      final hFree = kernel32
          .lookupFunction<
            Int32 Function(IntPtr, Uint32, Pointer<Uint16>),
            int Function(int, int, Pointer<Uint16>)
          >('HeapFree');

      if (openClip(0) == 0) return [];
      try {
        final hMem = getClipData(cfHdrop);
        if (hMem == 0) return [];
        final count = dragQueryFileW(hMem, 0xFFFFFFFF, nullptr, 0);
        if (count == 0) return [];

        final heap = getHeap();
        const maxChars = 1024;
        final buffer = hAlloc(heap, 0x00000008, maxChars * 2);
        final files = <String>[];
        try {
          for (int i = 0; i < count; i++) {
            final len = dragQueryFileW(hMem, i, buffer, maxChars);
            if (len > 0) {
              final chars = <int>[];
              for (int c = 0; c < len; c++) {
                chars.add(buffer[c]);
              }
              files.add(String.fromCharCodes(chars));
            }
          }
        } finally {
          hFree(heap, 0, buffer);
        }
        return files;
      } finally {
        closeClip();
      }
    } catch (e) {
      talker.warning('Windows HDROP extraction error: $e');
      return [];
    }
  }

  static Future<List<MessageAttachment>> _getMacClipboardAttachments() async {
    final tempDir = Directory.systemTemp.path;
    final tempImgPath =
        '$tempDir/clip_${DateTime.now().millisecondsSinceEpoch}_${_uuid.v4().substring(0, 8)}.png';

    final script =
        '''
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
    var result = await Process.run('xclip', [
      '-selection',
      'clipboard',
      '-t',
      'image/png',
      '-o',
    ]);
    if (result.exitCode != 0 || (result.stdout as List<int>).isEmpty) {
      result = await Process.run('wl-paste', ['--type', 'image/png']);
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
