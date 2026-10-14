import 'dart:typed_data';

import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/material.dart';

enum MaturityClass { immature, mature, overmature, unknown }

extension MaturityClassX on MaturityClass {
  /// Converts a maturity enum into its farmer-facing name, including unknown results.
  String get label {
    switch (this) {
      case MaturityClass.immature:
        return 'Immature';
      case MaturityClass.mature:
        return 'Mature';
      case MaturityClass.overmature:
        return 'Overmature';
      case MaturityClass.unknown:
        return 'Unknown';
    }
  }

  /// Maps maturity stages to consistent yellow, green, red, or unknown-state colors.
  Color get color {
    switch (this) {
      case MaturityClass.immature:
        return AppConstants.immatureColor;
      case MaturityClass.mature:
        return AppConstants.matureColor;
      case MaturityClass.overmature:
        return AppConstants.overmatureColor;
      case MaturityClass.unknown:
        return AppConstants.unknownMaturityColor;
    }
  }
}

/// One fruit prediction; box coordinates are normalized to the original image.
/// Confidence is the selected model class score, not a guarantee of correctness.
class Detection {
  const Detection({
    required this.boundingBox,
    required this.maturityClass,
    required this.confidence,
    this.mask,
  });

  final Rect boundingBox;
  final MaturityClass maturityClass;
  final double confidence;
  final SegmentationMask? mask;
}

/// Compact row-major binary silhouette (0 background, 1 fruit).
/// Bounds are normalized image coordinates; width/height describe the mask grid.
/// Transparency is applied by the painter, not stored in these binary pixels.
class SegmentationMask {
  const SegmentationMask({
    required this.bounds,
    required this.width,
    required this.height,
    required this.pixels,
  });

  final Rect bounds;
  final int width;
  final int height;
  final Uint8List pixels;

  /// Reports whether the binary mask has no active foreground pixels.
  bool get isEmpty => !pixels.contains(1);

  /// Reads a binary mask pixel safely; coordinates outside the mask are background.
  bool isActive(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
      return false;
    }
    return pixels[(y * width) + x] == 1;
  }
}
