import 'dart:typed_data';

import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/material.dart';

enum MaturityClass { immature, mature, overmature, unknown }

extension MaturityClassX on MaturityClass {
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

  bool get isEmpty => !pixels.contains(1);

  bool isActive(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
      return false;
    }
    return pixels[(y * width) + x] == 1;
  }
}
