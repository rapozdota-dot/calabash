import 'dart:io';
import 'dart:ui' as ui;

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/screens/camera_screen.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:calabash_maturity_detection/utils/navigation.dart';
import 'package:calabash_maturity_detection/widgets/detection_box.dart';
import 'package:calabash_maturity_detection/widgets/result_card.dart';
import 'package:calabash_maturity_detection/widgets/summary_card.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

class ResultScreen extends StatelessWidget {
  const ResultScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<DetectionProvider>(
      builder: (context, provider, child) {
        if (provider.selectedImage == null) {
          return _noImageScaffold(context, provider);
        }

        final imageFile = provider.selectedImage!;
        final detections = provider.detections;

        return Scaffold(
          appBar: AppBar(title: const Text('Detection Result')),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppConstants.resultPagePadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _imageWithOverlays(
                    imageFile: imageFile,
                    detections: detections,
                  ),
                  if (provider.errorMessage != null && !provider.isBusy) ...[
                    const SizedBox(height: AppConstants.sectionSpacing),
                    _messageBanner(context, provider.errorMessage!),
                  ],
                  const SizedBox(height: AppConstants.sectionSpacing),
                  ..._resultSections(context, provider),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Scaffold _noImageScaffold(BuildContext context, DetectionProvider provider) {
    return Scaffold(
      appBar: AppBar(title: const Text('Detection Result')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.image_not_supported_rounded,
                size: 58,
                color: Colors.black45,
              ),
              const SizedBox(height: 10),
              const Text(
                'No image available. Please start a scan first.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppConstants.sectionSpacing),
              ElevatedButton(
                onPressed: () => _startNewScan(context, provider),
                child: const Text('Start New Scan'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _resultSections(
    BuildContext context,
    DetectionProvider provider,
  ) {
    final detections = provider.detections;
    if (detections.isEmpty) {
      return [_zeroDetectionState(context, provider)];
    }

    if (detections.length == 1) {
      return [
        _singleDetectionResult(context, detections.first),
        const SizedBox(height: AppConstants.sectionSpacing),
        _scanAgainButton(context, provider),
      ];
    }

    return [
      SummaryCard(
        total: provider.totalDetected,
        mature: provider.matureCount,
        immature: provider.immatureCount,
        overmature: provider.overmatureCount,
      ),
      const SizedBox(height: 12),
      _recommendationCard(context, _guidanceForMultipleDetections(provider)),
      const SizedBox(height: AppConstants.sectionSpacing),
      _detectedList(context, detections),
      const SizedBox(height: 6),
      _scanAgainButton(context, provider),
    ];
  }

  Widget _messageBanner(BuildContext context, String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppConstants.errorSurface,
        borderRadius: BorderRadius.circular(AppConstants.cardRadius),
        border: Border.all(color: AppConstants.errorBorder),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: AppConstants.errorColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppConstants.softText,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _singleDetectionResult(BuildContext context, Detection detection) {
    final color = detection.maturityClass.color;
    final confidence = (detection.confidence * 100).toStringAsFixed(0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: color.withValues(alpha: 0.10),
          child: Padding(
            padding: const EdgeInsets.all(AppConstants.cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  detection.maturityClass.label.toUpperCase(),
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$confidence% AI confidence',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppConstants.softText,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _recommendationCard(context, _guidanceForSingleDetection(detection)),
      ],
    );
  }

  Widget _zeroDetectionState(BuildContext context, DetectionProvider provider) {
    final isBusy = provider.isBusy;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              isBusy ? Icons.analytics_rounded : Icons.search_off_rounded,
              color: isBusy
                  ? AppConstants.primaryGreen
                  : AppConstants.unknownMaturityColor,
              size: 42,
            ),
            const SizedBox(height: AppConstants.smallSpacing),
            Text(
              isBusy ? 'Analyzing image...' : 'No calabash detected',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(
              isBusy
                  ? 'Please wait while the selected image is being processed.'
                  : 'We could not find a calabash fruit in this image. Try a clearer photo with the fruit visible and well lit.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppConstants.mutedText),
            ),
            if (isBusy) ...[
              const SizedBox(height: AppConstants.sectionSpacing),
              const LinearProgressIndicator(),
            ] else ...[
              const SizedBox(height: AppConstants.sectionSpacing),
              ElevatedButton.icon(
                onPressed: () => _tryAnotherImage(provider),
                icon: const Icon(Icons.photo_library_rounded, size: 20),
                label: const Text('Try Another Image'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => _startNewScan(context, provider),
                icon: const Icon(Icons.videocam_rounded, size: 20),
                label: const Text('Use Camera'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _recommendationCard(BuildContext context, String recommendation) {
    return Card(
      color: AppConstants.secondaryLightGreen.withValues(alpha: 0.24),
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.compactCardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.tips_and_updates_rounded,
                  color: AppConstants.primaryGreen,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Suggested guidance',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppConstants.primaryGreen,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              recommendation,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: AppConstants.softText,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _guidanceForSingleDetection(Detection detection) {
    switch (detection.maturityClass) {
      case MaturityClass.immature:
        return 'This fruit may need more time to mature before harvesting.';
      case MaturityClass.mature:
        return 'This fruit appears mature and may be ready for harvesting.';
      case MaturityClass.overmature:
        return 'This fruit appears overmature. Consider evaluating it before use or harvest.';
      case MaturityClass.unknown:
        return 'Review the result as guidance before making a harvest decision.';
    }
  }

  String _guidanceForMultipleDetections(DetectionProvider provider) {
    final detectedClasses = provider.detections
        .map((detection) => detection.maturityClass)
        .toSet();
    if (detectedClasses.length == 1) {
      return _guidanceForUniformMultipleDetections(detectedClasses.first);
    }

    final guidanceParts = <String>[
      if (provider.immatureCount > 0)
        '${_fruitCount(provider.immatureCount)} may need more time to mature',
      if (provider.matureCount > 0)
        '${_fruitCount(provider.matureCount)} appear mature',
      if (provider.overmatureCount > 0)
        '${_fruitCount(provider.overmatureCount)} appear overmature',
    ];

    return '${guidanceParts.join('. ')}. Review the individual results below.';
  }

  String _fruitCount(int count) {
    return '$count ${count == 1 ? 'fruit' : 'fruits'}';
  }

  String _guidanceForUniformMultipleDetections(MaturityClass maturityClass) {
    switch (maturityClass) {
      case MaturityClass.immature:
        return 'These fruits may need more time to mature before harvesting.';
      case MaturityClass.mature:
        return 'These fruits appear mature and may be ready for harvesting.';
      case MaturityClass.overmature:
        return 'These fruits appear overmature. Consider evaluating them before use or harvest.';
      case MaturityClass.unknown:
        return 'Review the individual results before making a harvest decision.';
    }
  }

  Widget _detectedList(BuildContext context, List<Detection> detections) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Individual results',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w900,
            color: AppConstants.primaryGreen,
          ),
        ),
        const SizedBox(height: 8),
        ...detections.asMap().entries.map(
          (entry) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ResultCard(detection: entry.value, index: entry.key + 1),
          ),
        ),
      ],
    );
  }

  Widget _scanAgainButton(BuildContext context, DetectionProvider provider) {
    return OutlinedButton.icon(
      onPressed: () => _startNewScan(context, provider),
      icon: const Icon(Icons.refresh_rounded, size: 20),
      label: const Text('Scan Again'),
    );
  }

  void _startNewScan(BuildContext context, DetectionProvider provider) {
    provider.clearCurrentResult();
    Navigator.of(context).pushReplacement(fadeRoute(const CameraScreen()));
  }

  Future<void> _tryAnotherImage(DetectionProvider provider) async {
    await provider.scanFromSource(ImageSource.gallery);
  }

  Widget _imageWithOverlays({
    required File imageFile,
    required List<Detection> detections,
  }) {
    return FutureBuilder<ui.Image>(
      future: _decodeImage(imageFile),
      builder: (context, snapshot) {
        final image = snapshot.data;
        final aspectRatio = image == null
            ? 1.0
            : (image.width / image.height).clamp(0.72, 1.45).toDouble();

        return Card(
          clipBehavior: Clip.antiAlias,
          child: AspectRatio(
            aspectRatio: aspectRatio,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final frameRect = _computeImageRect(
                  image: image,
                  containerSize: Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  ),
                );

                return Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.88),
                      ),
                    ),
                    Positioned.fromRect(
                      rect: frameRect,
                      child: snapshot.hasData
                          ? Image.file(imageFile, fit: BoxFit.fill)
                          : const ColoredBox(
                              color: Colors.black12,
                              child: Center(child: CircularProgressIndicator()),
                            ),
                    ),
                    ...detections.asMap().entries.map(
                      (entry) => DetectionBox(
                        detection: entry.value,
                        fruitNumber: entry.key + 1,
                        imageWidth: frameRect.width,
                        imageHeight: frameRect.height,
                        offsetX: frameRect.left,
                        offsetY: frameRect.top,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<ui.Image> _decodeImage(File file) async {
    final bytes = await file.readAsBytes();
    return decodeImageFromList(bytes);
  }

  Rect _computeImageRect({
    required ui.Image? image,
    required Size containerSize,
  }) {
    if (image == null) {
      return Offset.zero & containerSize;
    }

    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(image.width.toDouble(), image.height.toDouble()),
      containerSize,
    );
    return Alignment.center.inscribe(
      fitted.destination,
      Offset.zero & containerSize,
    );
  }
}
