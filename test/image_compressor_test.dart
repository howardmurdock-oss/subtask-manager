import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:orders_app/core/utils/image_compressor.dart';

void main() {
  group('ImageCompressor Tests', () {
    test('Compresses and downscales large image to lightweight base64 string', () {
      // Create a 2000x1500 test image in memory
      final rawImage = img.Image(width: 2000, height: 1500);
      img.fill(rawImage, color: img.ColorRgb8(200, 100, 50));
      final pngBytes = Uint8List.fromList(img.encodePng(rawImage));

      // Ensure raw image is large
      expect(pngBytes.isNotEmpty, true);

      // Run through ImageCompressor
      final resultBase64 = ImageCompressor.compressAndEncode(pngBytes, maxDimension: 800);

      expect(resultBase64, isNotNull);
      final decodedBytes = base64Decode(resultBase64!);

      // Verify decoded image dimensions are capped at 800
      final resultImage = img.decodeImage(decodedBytes);
      expect(resultImage, isNotNull);
      expect(resultImage!.width <= 800, true);
      expect(resultImage.height <= 800, true);

      // Verify size is tiny (well under 50KB)
      expect(decodedBytes.length < 50 * 1024, true);
    });
  });
}
