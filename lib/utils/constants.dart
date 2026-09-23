import 'package:flutter/material.dart';

class AppConstants {
  AppConstants._();

  static const String appName = 'Calabash Maturity Detection';
  static const String modelAssetPath = 'assets/model/model.tflite';

  static const int modelInputSize = 640;
  static const double confidenceThreshold = 0.25;
  static const double iouThreshold = 0.70;
  static const int maxDetections = 300;
  static const double maskLogitThreshold = 0.0;
  static const double liveHighConfidenceThreshold = 0.70;
  static const double liveWeakConfidenceThreshold = 0.50;
  static const int liveStableClassFrames = 2;
  static const double liveTrackIouThreshold = 0.20;
  static const double liveTrackCenterDistanceThreshold = 0.18;

  static const Color primaryGreen = Color(0xFF2E7D32);
  static const Color secondaryLightGreen = Color(0xFFA5D6A7);
  static const Color accentBrown = Color(0xFF6D4C41);
  static const Color background = Color(0xFFF5F7F2);
}
