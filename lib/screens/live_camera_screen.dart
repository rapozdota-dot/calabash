import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/providers/live_camera_provider.dart';
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
    return Consumer<LiveCameraProvider>(
      builder: (context, provider, child) {
        return Scaffold(
          appBar: AppBar(title: const Text('Live Detection')),
          body: SafeArea(child: _bodyFor(context, provider)),
        );
      },
    );
  }

  Widget _bodyFor(BuildContext context, LiveCameraProvider provider) {
    switch (provider.status) {
      case LiveCameraStatus.initial:
      case LiveCameraStatus.requestingPermission:
      case LiveCameraStatus.initializingCamera:
        return const _LiveLoadingState();
      case LiveCameraStatus.permissionDenied:
        return _PermissionMessage(
          icon: Icons.videocam_off_rounded,
          title: 'Camera permission is required to use Live Capture.',
          buttonLabel: 'Try Again',
          onPressed: provider.retryPermission,
        );
      case LiveCameraStatus.permissionPermanentlyDenied:
        return _PermissionMessage(
          icon: Icons.settings_rounded,
          title:
              'Camera access is disabled. Enable it in Settings to use Live Capture.',
          buttonLabel: 'Open Settings',
          onPressed: provider.openSettings,
        );
      case LiveCameraStatus.cameraError:
        return _PermissionMessage(
          icon: Icons.error_outline_rounded,
          title: provider.errorMessage ?? 'Camera could not be started.',
          buttonLabel: 'Try Again',
          onPressed: provider.retryPermission,
        );
      case LiveCameraStatus.cameraReady:
        return _LivePreview(provider: provider);
    }
  }
}

class _LivePreview extends StatelessWidget {
  const _LivePreview({required this.provider});

  final LiveCameraProvider provider;

  @override
  Widget build(BuildContext context) {
    final controller = provider.cameraController;
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
              provider.latestFrameSize ??
              _previewSourceSize(controller) ??
              containerSize;
          final previewRect = _coverRect(sourceSize, containerSize);

          return ClipRect(
            child: Stack(
              children: [
                Positioned.fromRect(
                  rect: previewRect,
                  child: CameraPreview(controller),
                ),
                ...provider.liveDetections.asMap().entries.map(
                  (entry) => DetectionBox(
                    detection: entry.value.detection,
                    fruitNumber: entry.key + 1,
                    imageWidth: previewRect.width,
                    imageHeight: previewRect.height,
                    offsetX: previewRect.left,
                    offsetY: previewRect.top,
                    label: _labelFor(entry.key + 1, entry.value),
                    subtitle: _subtitleFor(entry.value),
                    colorOverride: _colorFor(entry.value),
                  ),
                ),
                if (provider.shouldShowNoCalabash) const _NoCalabashOverlay(),
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 14,
                  child: _LiveStatusBar(
                    isProcessing: provider.isProcessingFrame,
                    hasDetections: provider.liveDetections.isNotEmpty,
                    errorMessage: provider.errorMessage,
                  ),
                ),
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
      LiveConfidenceTier.weak => Colors.blueGrey.shade700,
      LiveConfidenceTier.low => Colors.orange.shade800,
    };
  }
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
          SizedBox(height: 14),
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
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 18),
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
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded, color: Colors.white, size: 34),
            const SizedBox(height: 8),
            Text(
              'No Calabash Detected',
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
                color: Colors.white.withValues(alpha: 0.82),
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
            ? 'Live detection active'
            : 'Waiting for calabash');

    return Align(
      alignment: Alignment.bottomCenter,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.58),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                errorMessage == null
                    ? Icons.sensors_rounded
                    : Icons.error_outline_rounded,
                size: 18,
                color: Colors.white,
              ),
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
