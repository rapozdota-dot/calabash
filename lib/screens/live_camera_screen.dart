import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/providers/live_camera_provider.dart';
import 'package:calabash_maturity_detection/providers/live_detection_tracker.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:calabash_maturity_detection/widgets/detection_box.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class LiveCameraScreen extends StatelessWidget {
  const LiveCameraScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => LiveCameraProvider()..initialize(),
      child: const _LiveCameraView(),
    );
  }
}

class _LiveCameraView extends StatelessWidget {
  const _LiveCameraView();

  @override
  Widget build(BuildContext context) {
    final status = context.select<LiveCameraProvider, LiveCameraStatus>(
      (provider) => provider.status,
    );
    final errorMessage = context.select<LiveCameraProvider, String?>(
      (provider) => provider.errorMessage,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Live Detection'),
        actions: const [_TorchAction()],
      ),
      body: SafeArea(child: _bodyFor(context, status, errorMessage)),
    );
  }

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

class _TorchAction extends StatelessWidget {
  const _TorchAction();

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

  @override
  Widget build(BuildContext context) {
    final controller = context.select<LiveCameraProvider, CameraController?>(
      (provider) => provider.cameraController,
    );
    final latestFrameSize = context.select<LiveCameraProvider, Size?>(
      (provider) => provider.latestFrameSize,
    );
    if (controller == null || !controller.value.isInitialized) {
      return const _LiveLoadingState();
    }

    return Container(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final containerSize = Size(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          final sourceSize =
              latestFrameSize ??
              _previewSourceSize(controller) ??
              containerSize;
          final previewRect = _coverRect(sourceSize, containerSize);

          return ClipRect(
            child: Stack(
              children: [
                Positioned.fromRect(
                  rect: previewRect,
                  child: RepaintBoundary(child: CameraPreview(controller)),
                ),
                _LiveDetectionOverlay(previewRect: previewRect),
                const _LiveStatusBarHost(),
              ],
            ),
          );
        },
      ),
    );
  }

  Size? _previewSourceSize(CameraController controller) {
    final previewSize = controller.value.previewSize;
    if (previewSize == null) {
      return null;
    }

    final orientation = controller.value.deviceOrientation;
    final isPortrait =
        orientation == DeviceOrientation.portraitUp ||
        orientation == DeviceOrientation.portraitDown;
    return isPortrait
        ? Size(previewSize.height, previewSize.width)
        : Size(previewSize.width, previewSize.height);
  }

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

class _LiveDetectionOverlay extends StatelessWidget {
  const _LiveDetectionOverlay({required this.previewRect});

  final Rect previewRect;

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
            if (state.shouldShowNoCalabash) const _NoCalabashOverlay(),
          ],
        ),
      ),
    );
  }

  String _labelFor(int number, LiveDetection detection) {
    return switch (detection.confidenceTier) {
      LiveConfidenceTier.normal =>
        '#$number ${detection.detection.maturityClass.label}',
      LiveConfidenceTier.weak => 'Analyzing...',
      LiveConfidenceTier.low => 'Low confidence',
    };
  }

  String _subtitleFor(LiveDetection detection) {
    return switch (detection.confidenceTier) {
      LiveConfidenceTier.normal =>
        '${(detection.detection.confidence * 100).toStringAsFixed(0)}%',
      LiveConfidenceTier.weak => 'Keep the fruit steady',
      LiveConfidenceTier.low => 'Reposition camera',
    };
  }

  Color _colorFor(LiveDetection detection) {
    return switch (detection.confidenceTier) {
      LiveConfidenceTier.normal => detection.detection.maturityClass.color,
      LiveConfidenceTier.weak => AppConstants.unknownMaturityColor,
      LiveConfidenceTier.low => AppConstants.immatureColor,
    };
  }
}

class _LiveStatusBarHost extends StatelessWidget {
  const _LiveStatusBarHost();

  @override
  Widget build(BuildContext context) {
    final state = context.select<LiveCameraProvider, _LiveStatusState>(
      (provider) => _LiveStatusState(
        isProcessing: provider.isProcessingFrame,
        hasDetections: provider.liveDetections.isNotEmpty,
        errorMessage: provider.errorMessage,
      ),
    );

    return Positioned(
      left: AppConstants.compactCardPadding,
      right: AppConstants.compactCardPadding,
      bottom: AppConstants.compactCardPadding,
      child: _LiveStatusBar(
        isProcessing: state.isProcessing,
        hasDetections: state.hasDetections,
        errorMessage: state.errorMessage,
      ),
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

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _LiveOverlayState &&
            identical(other.detections, detections) &&
            other.shouldShowNoCalabash == shouldShowNoCalabash;
  }

  @override
  int get hashCode =>
      Object.hash(identityHashCode(detections), shouldShowNoCalabash);
}

class _LiveStatusState {
  const _LiveStatusState({
    required this.isProcessing,
    required this.hasDetections,
    required this.errorMessage,
  });

  final bool isProcessing;
  final bool hasDetections;
  final String? errorMessage;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _LiveStatusState &&
            other.isProcessing == isProcessing &&
            other.hasDetections == hasDetections &&
            other.errorMessage == errorMessage;
  }

  @override
  int get hashCode => Object.hash(isProcessing, hasDetections, errorMessage);
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

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is _TorchButtonState &&
            other.isCameraReady == isCameraReady &&
            other.isTorchOn == isTorchOn &&
            other.isSettingTorch == isSettingTorch;
  }

  @override
  int get hashCode => Object.hash(isCameraReady, isTorchOn, isSettingTorch);
}

class _LiveLoadingState extends StatelessWidget {
  const _LiveLoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: AppConstants.sectionSpacing),
          Text(
            'Starting live detection...',
            style: TextStyle(fontWeight: FontWeight.w800),
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

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
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
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: AppConstants.sectionSpacing),
            ElevatedButton(onPressed: onPressed, child: Text(buttonLabel)),
          ],
        ),
      ),
    );
  }
}

class _NoCalabashOverlay extends StatelessWidget {
  const _NoCalabashOverlay();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: AppConstants.cardPadding,
        ),
        decoration: BoxDecoration(
          color: AppConstants.overlayScrim,
          borderRadius: BorderRadius.circular(AppConstants.overlayRadius),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded, color: Colors.white, size: 34),
            const SizedBox(height: 8),
            Text(
              'No calabash detected',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Point the camera toward a calabash fruit.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white.withValues(alpha: 0.84),
                fontWeight: FontWeight.w700,
              ),
            ),
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
  });

  final bool isProcessing;
  final bool hasDetections;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final text =
        errorMessage ??
        (isProcessing
            ? 'Analyzing...'
            : hasDetections
            ? 'Calabash detected'
            : 'Waiting for calabash');
    final icon = errorMessage != null
        ? Icons.error_outline_rounded
        : isProcessing
        ? Icons.autorenew_rounded
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
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
