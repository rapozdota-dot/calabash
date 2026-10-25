import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/providers/live_camera_provider.dart';
import 'package:calabash_maturity_detection/providers/live_detection_tracker.dart';
import 'package:calabash_maturity_detection/screens/result_screen.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:calabash_maturity_detection/utils/app_theme.dart';
import 'package:calabash_maturity_detection/utils/navigation.dart';
import 'package:calabash_maturity_detection/utils/prediction_explanations.dart';
import 'package:calabash_maturity_detection/widgets/detection_box.dart';
import 'package:calabash_maturity_detection/widgets/information_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class LiveCameraScreen extends StatelessWidget {
  const LiveCameraScreen({super.key, this.providerFactory});

  final LiveCameraProvider Function()? providerFactory;

  /// Owns a camera-session provider scoped to this screen and starts initialization.
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) =>
          (providerFactory?.call() ?? LiveCameraProvider())..initialize(),
      child: const _LiveCameraView(),
    );
  }
}

class _LiveCameraView extends StatelessWidget {
  const _LiveCameraView();

  /// Displays the live camera scaffold and observes only session status/errors.
  @override
  Widget build(BuildContext context) {
    final status = context.select<LiveCameraProvider, LiveCameraStatus>(
      (provider) => provider.status,
    );
    final errorMessage = context.select<LiveCameraProvider, String?>(
      (provider) => provider.errorMessage,
    );

    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Live Detection'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: landscape ? 48 : 56,
        titleTextStyle: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(color: Colors.white),
        systemOverlayStyle: SystemUiOverlayStyle.light,
        actions: const [_TorchAction(), _LiveInformationAction()],
      ),
      body: SafeArea(child: _bodyFor(context, status, errorMessage)),
    );
  }

  /// Chooses loading, permission recovery, camera error, or preview content.
  Widget _bodyFor(
    BuildContext context,
    LiveCameraStatus status,
    String? errorMessage,
  ) {
    switch (status) {
      case LiveCameraStatus.initial:
      case LiveCameraStatus.requestingPermission:
      case LiveCameraStatus.initializingCamera:
        return const _LiveLoadingState();
      case LiveCameraStatus.permissionDenied:
        return _PermissionMessage(
          icon: Icons.videocam_off_rounded,
          title: 'Camera permission is required to use Live Detection.',
          buttonLabel: 'Try Again',
          onPressed: context.read<LiveCameraProvider>().retryPermission,
        );
      case LiveCameraStatus.permissionPermanentlyDenied:
        return _PermissionMessage(
          icon: Icons.settings_rounded,
          title:
              'Camera access is disabled. Enable it in Settings to use Live Detection.',
          buttonLabel: 'Open Settings',
          onPressed: context.read<LiveCameraProvider>().openSettings,
        );
      case LiveCameraStatus.cameraError:
        return _PermissionMessage(
          icon: Icons.error_outline_rounded,
          title: errorMessage ?? 'Camera could not be started.',
          buttonLabel: 'Try Again',
          onPressed: context.read<LiveCameraProvider>().retryPermission,
        );
      case LiveCameraStatus.cameraReady:
        return const _LivePreview();
    }
  }
}

/// Keeps optional prediction explanations outside the frame-driven overlays.
class _LiveInformationAction extends StatelessWidget {
  const _LiveInformationAction();

  @override
  Widget build(BuildContext context) {
    final isCaptureWorkflowActive = context.select<LiveCameraProvider, bool>(
      (provider) => provider.isCaptureWorkflowActive,
    );

    return InformationButton(
      tooltip: 'About live predictions',
      title: 'Live prediction information',
      message:
          '${PredictionExplanations.confidence}\n\n${PredictionExplanations.liveExternalAssessment}',
      color: Colors.white,
      disabledColor: Colors.white38,
      enabled: !isCaptureWorkflowActive,
    );
  }
}

class _TorchAction extends StatelessWidget {
  const _TorchAction();

  /// Builds a flashlight control that updates only when its selected state changes.
  @override
  Widget build(BuildContext context) {
    final state = context.select<LiveCameraProvider, _TorchButtonState>(
      (provider) => _TorchButtonState(
        isCameraReady: provider.isCameraReady,
        isTorchOn: provider.isTorchOn,
        isSettingTorch: provider.isSettingTorch,
      ),
    );

    return IconButton(
      disabledColor: Colors.white38,
      tooltip: state.isTorchOn ? 'Turn flashlight off' : 'Turn flashlight on',
      onPressed: state.isCameraReady && !state.isSettingTorch
          ? () => _toggleTorch(context)
          : null,
      icon: Icon(
        state.isTorchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
        color: state.isTorchOn ? AppConstants.secondaryLightGreen : null,
      ),
    );
  }

  /// Requests a torch change and shows a snackbar if the hardware cannot apply it.
  Future<void> _toggleTorch(BuildContext context) async {
    final provider = context.read<LiveCameraProvider>();
    final success = await provider.toggleTorch();
    if (!context.mounted || success) {
      return;
    }

    final message =
        provider.lastTorchError ?? 'Flashlight is unavailable on this device.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

class _LivePreview extends StatelessWidget {
  const _LivePreview();

  /// Fits camera pixels and overlays into the same cover rectangle to preserve alignment.
  @override
  Widget build(BuildContext context) {
    final controller = context.select<LiveCameraProvider, CameraController?>(
      (provider) => provider.cameraController,
    );
    if (controller == null || !controller.value.isInitialized) {
      return const _LiveLoadingState();
    }

    // CameraPreview listens to CameraValue itself. Its enclosing geometry must
    // follow the same notifications, even when no inference result has arrived.
    return ValueListenableBuilder<CameraValue>(
      valueListenable: controller,
      builder: (context, value, _) => Container(
        color: Colors.black,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final containerSize = Size(
              constraints.maxWidth,
              constraints.maxHeight,
            );
            final sourceSize = _previewSourceSize(value) ?? containerSize;
            final previewRect = _coverRect(sourceSize, containerSize);
            final landscape =
                MediaQuery.orientationOf(context) == Orientation.landscape;

            return ClipRect(
              child: Stack(
                children: [
                  Positioned.fromRect(
                    rect: previewRect,
                    child: _FocusPreview(
                      key: const ValueKey('live-camera-preview'),
                      controller: controller,
                    ),
                  ),
                  _LiveDetectionOverlay(previewRect: previewRect),
                  _ReadinessIndicatorHost(landscape: landscape),
                  _LiveCaptureControls(landscape: landscape),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// Determines preview dimensions from camera orientation before inference supplies a frame size.
  Size? _previewSourceSize(CameraValue value) {
    final previewSize = value.previewSize;
    if (previewSize == null) {
      return null;
    }

    // Match the camera plugin's applicable preview orientation exactly.
    final orientation = value.isRecordingVideo
        ? value.recordingOrientation!
        : value.previewPauseOrientation ??
              value.lockedCaptureOrientation ??
              value.deviceOrientation;
    final isPortrait =
        orientation == DeviceOrientation.portraitUp ||
        orientation == DeviceOrientation.portraitDown;
    return isPortrait
        ? Size(previewSize.height, previewSize.width)
        : Size(previewSize.width, previewSize.height);
  }

  /// Scales the source proportionally to fill the viewport and centers any cropped excess.
  Rect _coverRect(Size sourceSize, Size containerSize) {
    if (sourceSize.width <= 0 ||
        sourceSize.height <= 0 ||
        containerSize.width <= 0 ||
        containerSize.height <= 0) {
      return Offset.zero & containerSize;
    }

    final scale = math.max(
      containerSize.width / sourceSize.width,
      containerSize.height / sourceSize.height,
    );
    final width = sourceSize.width * scale;
    final height = sourceSize.height * scale;
    return Rect.fromLTWH(
      (containerSize.width - width) / 2,
      (containerSize.height - height) / 2,
      width,
      height,
    );
  }
}

class _FocusPreview extends StatefulWidget {
  const _FocusPreview({super.key, required this.controller});
  final CameraController controller;

  /// Creates state for the temporary tap-to-focus indicator.
  @override
  State<_FocusPreview> createState() => _FocusPreviewState();
}

class _FocusPreviewState extends State<_FocusPreview> {
  Offset? _point;
  int _request = 0;

  /// Converts taps to normalized focus/exposure points and clears the indicator afterward.
  /// A request ID prevents older tap responses from overriding newer taps.
  Future<void> _focus(Offset point, Size size) async {
    final request = ++_request;
    setState(() => _point = point);
    final normalized = Offset(
      (point.dx / size.width).clamp(0.0, 1.0),
      (point.dy / size.height).clamp(0.0, 1.0),
    );
    try {
      await widget.controller.setFocusPoint(normalized);
      if (mounted && request == _request) {
        await widget.controller.setExposurePoint(normalized);
      }
    } on CameraException {
      // Fixed-focus cameras may not support focus or exposure points.
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (mounted && request == _request) setState(() => _point = null);
    }
  }

  /// Shows the native preview with tap handling and an optional focus marker.
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) =>
          _focus(details.localPosition, constraints.biggest),
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(child: CameraPreview(widget.controller)),
          if (_point != null)
            Positioned(
              left: _point!.dx - 24,
              top: _point!.dy - 24,
              child: IgnorePointer(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white, width: 1.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _LiveDetectionOverlay extends StatelessWidget {
  const _LiveDetectionOverlay({required this.previewRect});

  final Rect previewRect;

  /// Draws confirmed tracks in preview coordinates, keyed by stable track ID.
  @override
  Widget build(BuildContext context) {
    final state = context.select<LiveCameraProvider, _LiveOverlayState>(
      (provider) => _LiveOverlayState(
        detections: provider.liveDetections,
        shouldShowNoCalabash: provider.shouldShowNoCalabash,
      ),
    );

    return Positioned.fill(
      child: RepaintBoundary(
        child: Stack(
          children: [
            ...state.detections.asMap().entries.map(
              (entry) => AnimatedDetectionBox(
                key: ValueKey<int>(entry.value.trackId),
                detection: entry.value.detection,
                fruitNumber: entry.key + 1,
                imageWidth: previewRect.width,
                imageHeight: previewRect.height,
                offsetX: previewRect.left,
                offsetY: previewRect.top,
                label: _labelFor(entry.key + 1, entry.value),
                subtitle: _subtitleFor(entry.value),
                colorOverride: _colorFor(entry.value),
                duration: entry.value.animateBounds
                    ? AppConstants.liveOverlayAnimationDuration
                    : Duration.zero,
                curve: AppConstants.liveOverlayAnimationCurve,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Uses cautious wording for weak predictions instead of presenting them as certain.
  String _labelFor(int number, LiveDetection detection) {
    if (detection.maturityUncertain) return '#$number Calabash';
    return switch (detection.confidenceTier) {
      LiveConfidenceTier.normal =>
        '#$number ${detection.detection.maturityClass.label}',
      LiveConfidenceTier.weak =>
        'Possible ${detection.detection.maturityClass.label}',
      LiveConfidenceTier.low => 'Low confidence',
    };
  }

  /// Shows confidence or a camera-positioning hint according to prediction strength.
  String _subtitleFor(LiveDetection detection) {
    if (detection.maturityUncertain) return 'Maturity uncertain';
    return switch (detection.confidenceTier) {
      LiveConfidenceTier.normal =>
        '${(detection.detection.confidence * 100).toStringAsFixed(0)}%',
      LiveConfidenceTier.weak => 'Hold steady to confirm',
      LiveConfidenceTier.low => 'Reposition camera',
    };
  }

  /// Uses maturity colors for normal-confidence results and caution colors otherwise.
  Color _colorFor(LiveDetection detection) {
    if (detection.maturityUncertain) return AppConstants.unknownMaturityColor;
    return switch (detection.confidenceTier) {
      LiveConfidenceTier.normal => detection.detection.maturityClass.color,
      LiveConfidenceTier.weak => AppConstants.unknownMaturityColor,
      LiveConfidenceTier.low => AppConstants.immatureColor,
    };
  }
}

class _ReadinessIndicatorHost extends StatelessWidget {
  const _ReadinessIndicatorHost({this.landscape = false});
  final bool landscape;

  /// Observes just readiness and first-frame state to limit UI rebuilds.
  @override
  Widget build(BuildContext context) {
    final status = context.select<LiveCameraProvider, LiveStabilityStatus>(
      (provider) => provider.stabilityStatus,
    );
    final hasProcessed = context.select<LiveCameraProvider, bool>(
      (provider) => provider.hasProcessedFrame,
    );
    final modelReady = context.select<LiveCameraProvider, bool>(
      (provider) => provider.isInferenceReady,
    );

    return Positioned(
      left: AppConstants.compactCardPadding,
      right: landscape ? 144 : AppConstants.compactCardPadding,
      top: AppConstants.compactCardPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ReadinessIndicator(
            status: status,
            hasProcessed: hasProcessed,
            modelReady: modelReady,
          ),
          const SizedBox(height: 8),
          const _LiveStatusBarHost(),
        ],
      ),
    );
  }
}

class _ReadinessIndicator extends StatelessWidget {
  const _ReadinessIndicator({
    required this.status,
    required this.hasProcessed,
    required this.modelReady,
  });

  final LiveStabilityStatus status;
  final bool hasProcessed;
  final bool modelReady;

  /// Displays looking, no-calabash, hold-steady, or capture-ready guidance.
  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      LiveStabilityStatus.noCalabashDetected =>
        AppConstants.unknownMaturityColor,
      LiveStabilityStatus.holdSteady => AppConstants.immatureColor,
      LiveStabilityStatus.ready => AppConstants.matureColor,
    };
    final icon = switch (status) {
      LiveStabilityStatus.noCalabashDetected => Icons.search_off_rounded,
      LiveStabilityStatus.holdSteady => Icons.pan_tool_alt_rounded,
      LiveStabilityStatus.ready => Icons.check_circle_rounded,
    };
    final foreground = AppTheme.onStatusColor(color);
    final label = !modelReady
        ? 'Starting fruit detection...'
        : !hasProcessed
        ? 'Looking for calabash...'
        : switch (status) {
            LiveStabilityStatus.noCalabashDetected =>
              'No calabash fruits detected',
            LiveStabilityStatus.holdSteady => 'Hold steady',
            LiveStabilityStatus.ready => 'Ready to capture',
          };

    return AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 220),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppConstants.overlayRadius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveCaptureControls extends StatelessWidget {
  const _LiveCaptureControls({this.landscape = false});
  final bool landscape;

  /// Enables the shutter only when both live capture and photo analysis are idle.
  @override
  Widget build(BuildContext context) {
    final state = context.select<LiveCameraProvider, _CaptureButtonState>(
      (provider) => _CaptureButtonState(
        isCameraReady: provider.isCameraReady,
        isCaptureWorkflowActive: provider.isCaptureWorkflowActive,
      ),
    );
    final isStillDetectorBusy = context.select<DetectionProvider, bool>(
      (provider) => provider.isBusy,
    );
    final isBusy = state.isCaptureWorkflowActive || isStillDetectorBusy;

    return Positioned(
      left: landscape ? null : AppConstants.compactCardPadding,
      right: AppConstants.compactCardPadding,
      width: landscape ? 120 : null,
      top: landscape ? AppConstants.compactCardPadding : null,
      bottom: AppConstants.compactCardPadding,
      child: Center(
        heightFactor: landscape ? null : 1,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: isBusy
                    ? const _CaptureProgressPill()
                    : const SizedBox(height: 0),
              ),
              const SizedBox(height: 8),
              _ShutterButton(
                isEnabled: state.isCameraReady && !isBusy,
                isBusy: isBusy,
                onPressed: () => _captureAndOpenResult(context),
              ),
              const SizedBox(height: 8),
              Text(
                'Capture for full analysis',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Captures a full photo, analyzes it, opens results, and resumes live detection afterward.
  /// Failures restore streaming and show a message without opening a misleading result.
  Future<void> _captureAndOpenResult(BuildContext context) async {
    HapticFeedback.lightImpact();
    final liveProvider = context.read<LiveCameraProvider>();
    final detectionProvider = context.read<DetectionProvider>();
    try {
      final capturedImage = await liveProvider.captureStillImage();

      if (!context.mounted) {
        return;
      }

      if (capturedImage == null) {
        if (!context.mounted) {
          return;
        }
        _showMessage(
          context,
          liveProvider.captureErrorMessage ?? 'Unable to capture image.',
        );
        return;
      }

      final success = await detectionProvider.scanFile(capturedImage);
      if (!context.mounted || ModalRoute.of(context)?.isCurrent != true) {
        return;
      }

      if (!success) {
        if (!context.mounted) {
          return;
        }
        _showMessage(
          context,
          detectionProvider.errorMessage ??
              'Captured image could not be analyzed.',
        );
        return;
      }

      await Navigator.of(
        context,
      ).push(fadeRoute(const ResultScreen(returnToLiveCamera: true)));
    } finally {
      // The preview's context may be replaced during a lifecycle interruption.
      // Release the capture pause even then; the provider guards its own disposal.
      await liveProvider.resumeLiveDetection();
    }
  }

  /// Shows a short floating snackbar for capture or analysis problems.
  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

class _CaptureProgressPill extends StatelessWidget {
  const _CaptureProgressPill();

  /// Displays compact progress feedback while a captured photo is processed.
  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppConstants.overlayScrim,
        borderRadius: BorderRadius.circular(AppConstants.overlayRadius),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Processing capture...',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({
    required this.isEnabled,
    required this.isBusy,
    required this.onPressed,
  });

  final bool isEnabled;
  final bool isBusy;
  final VoidCallback onPressed;

  /// Builds an accessible shutter button with explicit disabled and busy states.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Capture still image',
      child: SizedBox(
        width: 76,
        height: 76,
        child: FilledButton(
          onPressed: isEnabled ? onPressed : null,
          style: FilledButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
            backgroundColor: Colors.white,
            disabledBackgroundColor: Colors.white.withValues(alpha: 0.48),
            foregroundColor: AppConstants.primaryGreen,
            disabledForegroundColor: Colors.white70,
            side: BorderSide(
              color: Colors.white.withValues(alpha: 0.72),
              width: 4,
            ),
          ),
          child: isBusy
              ? const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(strokeWidth: 3),
                )
              : const Icon(Icons.camera_alt_rounded, size: 34),
        ),
      ),
    );
  }
}

class _LiveStatusBarHost extends StatelessWidget {
  const _LiveStatusBarHost();

  /// Observes only status-bar fields rather than rebuilding the full camera screen.
  @override
  Widget build(BuildContext context) {
    final state = context.select<LiveCameraProvider, _LiveStatusState>(
      (provider) => _LiveStatusState(
        isProcessing: provider.isProcessingFrame,
        hasDetections: provider.liveDetections.isNotEmpty,
        isSlow: provider.isLiveSlow,
        errorMessage: provider.captureErrorMessage ?? provider.errorMessage,
      ),
    );

    return _LiveStatusBar(
      isProcessing: state.isProcessing,
      hasDetections: state.hasDetections,
      errorMessage: state.errorMessage,
      isSlow: state.isSlow,
    );
  }
}

class _LiveOverlayState {
  const _LiveOverlayState({
    required this.detections,
    required this.shouldShowNoCalabash,
  });

  final List<LiveDetection> detections;
  final bool shouldShowNoCalabash;

  /// Compares selected overlay state so unrelated provider updates do not rebuild masks.
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _LiveOverlayState &&
            identical(other.detections, detections) &&
            other.shouldShowNoCalabash == shouldShowNoCalabash;
  }

  /// Hashes the same fields used for overlay-state equality.
  @override
  int get hashCode =>
      Object.hash(identityHashCode(detections), shouldShowNoCalabash);
}

class _LiveStatusState {
  const _LiveStatusState({
    required this.isProcessing,
    required this.hasDetections,
    required this.errorMessage,
    required this.isSlow,
  });

  final bool isProcessing;
  final bool hasDetections;
  final String? errorMessage;
  final bool isSlow;

  /// Compares status-bar fields to avoid rebuilding it for unrelated changes.
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _LiveStatusState &&
            other.isProcessing == isProcessing &&
            other.hasDetections == hasDetections &&
            other.isSlow == isSlow &&
            other.errorMessage == errorMessage;
  }

  /// Hashes the same fields used for status-bar equality.
  @override
  int get hashCode =>
      Object.hash(isProcessing, hasDetections, errorMessage, isSlow);
}

class _CaptureButtonState {
  const _CaptureButtonState({
    required this.isCameraReady,
    required this.isCaptureWorkflowActive,
  });

  final bool isCameraReady;
  final bool isCaptureWorkflowActive;

  /// Compares camera-readiness and capture-busy state for selective control rebuilds.
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _CaptureButtonState &&
            other.isCameraReady == isCameraReady &&
            other.isCaptureWorkflowActive == isCaptureWorkflowActive;
  }

  /// Hashes the fields used for capture-button state equality.
  @override
  int get hashCode => Object.hash(isCameraReady, isCaptureWorkflowActive);
}

class _TorchButtonState {
  const _TorchButtonState({
    required this.isCameraReady,
    required this.isTorchOn,
    required this.isSettingTorch,
  });

  final bool isCameraReady;
  final bool isTorchOn;
  final bool isSettingTorch;

  /// Compares readiness, torch state, and toggle progress for selective rebuilds.
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _TorchButtonState &&
            other.isCameraReady == isCameraReady &&
            other.isTorchOn == isTorchOn &&
            other.isSettingTorch == isSettingTorch;
  }

  /// Hashes the fields used for torch-button state equality.
  @override
  int get hashCode => Object.hash(isCameraReady, isTorchOn, isSettingTorch);
}

class _LiveLoadingState extends StatelessWidget {
  const _LiveLoadingState();

  /// Shows camera-startup progress before the native preview is available.
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: AppConstants.sectionSpacing),
          Text(
            'Starting live detection...',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _PermissionMessage extends StatelessWidget {
  const _PermissionMessage({
    required this.icon,
    required this.title,
    required this.buttonLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String buttonLabel;
  final VoidCallback onPressed;

  /// Displays a recoverable permission/error message with its corresponding action.
  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppConstants.primaryGreen),
            const SizedBox(height: AppConstants.sectionSpacing),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            ElevatedButton(onPressed: onPressed, child: Text(buttonLabel)),
          ],
        ),
      ),
    );
  }
}

class _LiveStatusBar extends StatelessWidget {
  const _LiveStatusBar({
    required this.isProcessing,
    required this.hasDetections,
    required this.errorMessage,
    required this.isSlow,
  });

  final bool isProcessing;
  final bool hasDetections;
  final String? errorMessage;
  final bool isSlow;

  /// Shows live-analysis feedback and errors without covering the whole preview.
  @override
  Widget build(BuildContext context) {
    final text =
        errorMessage ??
        (isSlow
            ? 'Hold steady. Capture gives a more detailed result.'
            : hasDetections
            ? 'Tap capture to review maturity'
            : 'Tap to focus. Move closer in good light.');
    final icon = errorMessage != null
        ? Icons.error_outline_rounded
        : hasDetections
        ? Icons.check_circle_rounded
        : Icons.sensors_rounded;

    return Align(
      alignment: Alignment.bottomCenter,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppConstants.overlayScrim,
          borderRadius: BorderRadius.circular(AppConstants.overlayRadius),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: Colors.white),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
