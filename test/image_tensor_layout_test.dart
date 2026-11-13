import 'dart:typed_data';

import 'package:calabash_maturity_detection/services/image_tensor_layout.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('packs normalized planar RGB at the 224-square input size', () {
    final transform = LetterboxTransform(
      sourceWidth: 224,
      sourceHeight: 112,
      inputSize: 224,
    );
    final image = img.Image(width: 224, height: 112)
      ..setPixelRgb(0, 0, 255, 128, 64);
    const plane = 224 * 224;
    final tensor = Float32List(3 * plane);
    transform.writeRgbImage(image: transform.resizeRgb(image), buffer: tensor);
    final firstPixel = 56 * 224;
    expect(transform.contentBounds, const Rect.fromLTWH(0, 56, 224, 112));
    expect(tensor[firstPixel], 1);
    expect(tensor[plane + firstPixel], closeTo(128 / 255, 1e-7));
    expect(tensor[2 * plane + firstPixel], closeTo(64 / 255, 1e-7));
    for (final channel in [0, 1, 2]) {
      expect(
        tensor[channel * plane + firstPixel - 1],
        closeTo(114 / 255, 1e-7),
      );
      expect(tensor[channel * plane + 168 * 224], closeTo(114 / 255, 1e-7));
    }
  });

  test('reverses asymmetric portrait padding using the rounded resize', () {
    final transform = LetterboxTransform(
      sourceWidth: 99,
      sourceHeight: 201,
      inputSize: 224,
    );
    expect(transform.resizedWidth, 110);
    expect(transform.leftPad, 57);
    expect(
      transform.toNormalizedSource(transform.contentBounds),
      const Rect.fromLTWH(0, 0, 1, 1),
    );
    final oddPadding = LetterboxTransform(
      sourceWidth: 100,
      sourceHeight: 201,
      inputSize: 224,
    );
    expect(oddPadding.resizedWidth, 111);
    expect(oddPadding.leftPad, 56);
    expect(oddPadding.contentBounds.right, 167);
  });

  test('resizes RGB with a pixel-center bilinear sample', () {
    final transform = LetterboxTransform(
      sourceWidth: 2,
      sourceHeight: 2,
      inputSize: 1,
    );
    final image = img.Image(width: 2, height: 2)
      ..setPixelRgb(0, 0, 200, 100, 0)
      ..setPixelRgb(1, 1, 80, 20, 40);
    final pixel = transform.resizeRgb(image).getPixel(0, 0);
    expect([pixel.r, pixel.g, pixel.b], [70, 30, 10]);
  });

  test('handles one-pixel axes and rejects invalid dimensions and buffers', () {
    final transform = LetterboxTransform(
      sourceWidth: 2000,
      sourceHeight: 1,
      inputSize: 224,
    );
    expect(transform.resizedHeight, 1);
    expect(
      () => LetterboxTransform(sourceWidth: 0, sourceHeight: 1, inputSize: 224),
      throwsArgumentError,
    );
    expect(
      () => transform.writeRgbImage(
        image: img.Image(width: 224, height: 1),
        buffer: Float32List(3),
      ),
      throwsArgumentError,
    );
  });
}
