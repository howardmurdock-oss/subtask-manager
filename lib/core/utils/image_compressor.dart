import 'dart:convert';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

class ImageCompressor {
  /// Compresses and downscales raw image bytes to an optimized lightweight JPEG base64 string
  /// Ideal for instant, private end-to-end encrypted relay transmission.
  static String? compressAndEncode(Uint8List rawBytes, {int maxDimension = 800, int quality = 70}) {
    try {
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) return null;

      img.Image processed = decoded;

      // Downscale if larger than maxDimension
      if (decoded.width > maxDimension || decoded.height > maxDimension) {
        if (decoded.width >= decoded.height) {
          processed = img.copyResize(decoded, width: maxDimension);
        } else {
          processed = img.copyResize(decoded, height: maxDimension);
        }
      }

      // Encode to optimized JPEG
      var jpgBytes = img.encodeJpg(processed, quality: quality);

      // If still over 50KB, optimize quality further
      if (jpgBytes.length > 50 * 1024) {
        jpgBytes = img.encodeJpg(processed, quality: 55);
      }

      return base64Encode(jpgBytes);
    } catch (e) {
      // Fallback: If decode fails, return raw base64 if under 60KB
      if (rawBytes.length <= 60 * 1024) {
        return base64Encode(rawBytes);
      }
      return null;
    }
  }
}
