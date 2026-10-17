import 'dart:typed_data';
import 'dart:ui' as ui;
import '../services/app_preferences_service.dart';

/// Utility class for automatically reducing image dimensions and file sizes
/// before uploading to multimodal LLM APIs (OpenAI, Gemini, Mistral, Ollama, etc.).
class ImageDownscaler {
  /// Downscales image [bytes] if [autoReduceImageSize] is enabled in settings
  /// (or [force] is true) and either dimension exceeds [maxDimension].
  ///
  /// Returns a record with the downscaled [bytes] and the updated [mimeType] (image/png),
  /// or original bytes and mimeType if downscaling was not needed or on failure.
  static Future<({Uint8List bytes, String mimeType, bool wasReduced})> downscaleIfNeeded({
    required Uint8List bytes,
    required String originalMimeType,
    int? maxDimension,
    bool force = false,
  }) async {
    final prefs = AppPreferencesService.instance;
    if (!force && !prefs.autoReduceImageSize) {
      return (bytes: bytes, mimeType: originalMimeType, wasReduced: false);
    }

    final targetMax = maxDimension ?? prefs.maxImageDimension;
    if (bytes.isEmpty || targetMax <= 0) {
      return (bytes: bytes, mimeType: originalMimeType, wasReduced: false);
    }

    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final width = image.width;
      final height = image.height;

      if (width <= targetMax && height <= targetMax) {
        // Image is already within the recommended max dimension
        return (bytes: bytes, mimeType: originalMimeType, wasReduced: false);
      }

      int targetWidth;
      int targetHeight;
      if (width >= height) {
        targetWidth = targetMax;
        targetHeight = (height * targetMax / width).round().clamp(1, targetMax);
      } else {
        targetHeight = targetMax;
        targetWidth = (width * targetMax / height).round().clamp(1, targetMax);
      }

      final scaledCodec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final scaledFrame = await scaledCodec.getNextFrame();
      final scaledImage = scaledFrame.image;

      final byteData = await scaledImage.toByteData(
        format: ui.ImageByteFormat.png,
      );

      if (byteData != null) {
        final scaledBytes = byteData.buffer.asUint8List();
        if (scaledBytes.isNotEmpty) {
          return (bytes: scaledBytes, mimeType: 'image/png', wasReduced: true);
        }
      }
    } catch (_) {
      // Fall back to original bytes on decoding or platform codec errors
    }

    return (bytes: bytes, mimeType: originalMimeType, wasReduced: false);
  }
}
