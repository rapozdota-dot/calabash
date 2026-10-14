import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart';

/// YOLO segmentation post-processing shared by live and photo inference.
class SegmentationPostprocessor {
  SegmentationPostprocessor._();

  /// Runs class-aware non-maximum suppression: consider highest confidence first.
  /// Suppress a box only when a kept box of the same class overlaps above the IoU limit;
  /// stop at maxDetections. Different maturity classes are not merged by this step.
  static List<T> suppressDuplicates<T>(
    List<T> candidates, {
    required Rect Function(T) boxOf,
    required double Function(T) confidenceOf,
    required int Function(T) classOf,
    required double iouThreshold,
    required int maxDetections,
  }) {
    final sorted = [...candidates]
      ..sort((a, b) => confidenceOf(b).compareTo(confidenceOf(a)));
    final kept = <T>[];
    for (final candidate in sorted) {
      // Overlapping boxes of different stages can belong to distinct fruits.
      if (kept.any(
        (picked) =>
            classOf(candidate) == classOf(picked) &&
            intersectionOverUnion(boxOf(candidate), boxOf(picked)) >
                iouThreshold,
      )) {
        continue;
      }
      kept.add(candidate);
      if (kept.length >= maxDetections) break;
    }
    return kept;
  }

  /// Calculates intersection area divided by union area; disjoint/degenerate boxes return zero.
  static double intersectionOverUnion(Rect a, Rect b) {
    final width = math.max(
      0.0,
      math.min(a.right, b.right) - math.max(a.left, b.left),
    );
    final height = math.max(
      0.0,
      math.min(a.bottom, b.bottom) - math.max(a.top, b.top),
    );
    final intersection = width * height;
    final union = a.width * a.height + b.width * b.height - intersection;
    return union > 0 ? intersection / union : 0;
  }

  /// Maps 640-space box corners onto the lower-resolution prototype grid and clips the crop.
  static ({int left, int top, int right, int bottom}) prototypeRegion(
    Rect modelBox,
    int modelSize,
    int width,
    int height,
  ) => (
    left: (modelBox.left * width / modelSize).floor().clamp(0, width),
    top: (modelBox.top * height / modelSize).floor().clamp(0, height),
    right: (modelBox.right * width / modelSize).ceil().clamp(0, width),
    bottom: (modelBox.bottom * height / modelSize).ceil().clamp(0, height),
  );

  /// Reconstructs each pixel's logit as sum(coefficient[c] * prototype[c, pixel]).
  ///
  /// Prototypes contain 32 shared learned planes; each fruit's coefficients
  /// select their weighted combination. These coefficients are not class scores.
  /// A logit greater than zero is equivalent to sigmoid(logit) greater than 0.5,
  /// so binary thresholding can avoid computing sigmoid for every pixel.
  /// Only the crop is displayed, so avoid the 32-channel dot product elsewhere.
  static void reconstructMask({
    required Float32List coefficients,
    required Float32List prototypes,
    required Float32List logits,
    required Rect modelBox,
    required int modelSize,
    required int width,
    required int height,
  }) {
    final planeSize = width * height;
    if (logits.length != planeSize ||
        prototypes.length != coefficients.length * planeSize) {
      throw ArgumentError('Mask buffers do not match the prototype tensor.');
    }
    logits.fillRange(0, logits.length, 0);
    final region = prototypeRegion(modelBox, modelSize, width, height);
    for (var channel = 0; channel < coefficients.length; channel++) {
      final coefficient = coefficients[channel];
      if (!coefficient.isFinite) {
        throw StateError('Non-finite mask coefficient.');
      }
      if (coefficient == 0) continue;
      final offset = channel * planeSize;
      for (var y = region.top; y < region.bottom; y++) {
        final start = y * width + region.left;
        final end = y * width + region.right;
        for (var i = start; i < end; i++) {
          logits[i] += coefficient * prototypes[offset + i];
        }
      }
    }
  }

  /// Requires enough finite foreground logits inside the fruit's prototype crop.
  /// Both an absolute pixel minimum and a crop-area fraction guard against tiny unsupported masks.
  static bool hasMaskSupport({
    required Float32List logits,
    required Rect modelBox,
    required int modelSize,
    required int width,
    required int height,
    required double threshold,
    required int minimumPixels,
    required double minimumFraction,
  }) {
    final region = prototypeRegion(modelBox, modelSize, width, height);
    final area = (region.right - region.left) * (region.bottom - region.top);
    final needed = math.max(minimumPixels, (area * minimumFraction).ceil());
    var count = 0;
    for (var y = region.top; y < region.bottom; y++) {
      for (var x = region.left; x < region.right; x++) {
        final value = logits[y * width + x];
        if (value.isFinite && value > threshold && ++count >= needed) {
          return true;
        }
      }
    }
    return false;
  }

  /// Uses a 3x3 neighbor vote to reduce isolated pixels and small holes in the binary display mask.
  /// This cosmetic cleanup does not change class predictions or confidence.
  static Uint8List smoothMask(Uint8List source, int width, int height) {
    final result = Uint8List(source.length);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var neighbors = 0;
        for (var dy = -1; dy <= 1; dy++) {
          for (var dx = -1; dx <= 1; dx++) {
            final nx = x + dx;
            final ny = y + dy;
            if (nx >= 0 && nx < width && ny >= 0 && ny < height) {
              neighbors += source[ny * width + nx];
            }
          }
        }
        if (neighbors >= 4) result[y * width + x] = 1;
      }
    }
    return result;
  }
}
