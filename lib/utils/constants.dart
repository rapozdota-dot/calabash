import 'package:flutter/material.dart';

class AppConstants {
  AppConstants._();

  static const String appName = 'Calabash Maturity Detection';
  static const String modelAssetPath = 'assets/model/model.tflite';

  static const int modelInputSize = 640;
  static const double confidenceThreshold = 0.45;
  static const double iouThreshold = 0.60;
  static const int maxDetections = 300;
  static const double maskLogitThreshold = 0.0;
  static const int minimumMaskPixels = 4;
  // Sparse foreground speckles are not enough support for a segmented fruit.
  static const double minimumMaskFraction = 0.10;
  static const double liveHighConfidenceThreshold = 0.70;
  // Share photo sensitivity; tentative live labels still need two observations.
  static const double liveWeakConfidenceThreshold = confidenceThreshold;
  static const int liveStableClassFrames = 3;
  static const int liveConfirmationFrames = 2;
  static const int liveMaxDetections = 20;
  static const int liveCameraFps = 30;
  static const double liveTrackIouThreshold = 0.20;
  static const double liveTrackCenterDistanceThreshold = 0.18;
  static const double liveOverlayAnimationMaxCenterDistance = 0.08;
  static const double liveOverlayAnimationMaxSizeDelta = 0.20;
  static const int liveReadyStableFrameThreshold = 3;
  static const int liveReadyGraceFrames = 1;
  static const double liveReadyCenterDistanceThreshold = 0.05;
  static const double liveReadySizeDeltaThreshold = 0.12;
  static const Duration liveInferenceMinInterval = Duration(milliseconds: 100);
  static const Duration liveOverlayAnimationDuration = Duration(
    milliseconds: 120,
  );
  static const Duration liveOverlayEmergencyStaleTimeout = Duration(seconds: 2);
  static const Duration liveResultMaxAge = Duration(milliseconds: 1200);
  static const Curve liveOverlayAnimationCurve = Curves.easeOut;

  static const Color primaryGreen = Color(0xFF2E7D32);
  static const Color secondaryLightGreen = Color(0xFFA5D6A7);
  static const Color accentBrown = Color(0xFF6D4C41);
  static const Color background = Color(0xFFF5F7F2);
  static const Color immatureColor = Color(0xFFFFA000);
  static const Color matureColor = Color(0xFF388E3C);
  static const Color overmatureColor = Color(0xFFD32F2F);
  static const Color unknownMaturityColor = Color(0xFF607D8B);
  static const Color mutedText = Color(0xFF687366);
  static const Color softText = Color(0xFF4E5B4D);
  static const Color errorColor = Color(0xFFC62828);
  static const Color errorSurface = Color(0xFFFFEBEE);
  static const Color errorBorder = Color(0xFFFFCDD2);
  static const Color overlayScrim = Color(0x94000000);

  static const double pagePadding = 20;
  static const double resultPagePadding = 16;
  static const double cardPadding = 16;
  static const double compactCardPadding = 14;
  static const double sectionSpacing = 14;
  static const double smallSpacing = 8;
  static const double cardRadius = 8;
  static const double overlayRadius = 8;
  static const double buttonHeight = 54;
}
