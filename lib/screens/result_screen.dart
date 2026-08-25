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
import 'package:provider/provider.dart';

class ResultScreen extends StatelessWidget {
  const ResultScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<DetectionProvider>(
      builder: (context, provider, child) {
        if (provider.selectedImage == null) {
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
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).pushReplacement(
                          fadeRoute(const CameraScreen()),
                        );
                      },
                      child: const Text('Start New Scan'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        final imageFile = provider.selectedImage!;
        final detections = provider.detections;
        final hasDetections = detections.isNotEmpty;

        return Scaffold(
          appBar: AppBar(
            title: const Text('Detection Result'),
            actions: [
              IconButton(
                tooltip: 'New Scan',
                onPressed: () => Navigator.of(context).pushReplacement(
                  fadeRoute(const CameraScreen()),
                ),
                icon: const Icon(Icons.camera_alt_rounded),
              ),
            ],
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _imageWithOverlays(
                    imageFile: imageFile,
                    detections: detections,
                  ),
                  const SizedBox(height: 14),
                  _statusBanner(
                    context: context,
                    detectionsFound: hasDetections,
                    count: detections.length,
                  ),
                  const SizedBox(height: 12),
                  SummaryCard(
                    total: provider.totalDetected,
                    mature: provider.matureCount,
                    immature: provider.immatureCount,
                    overmature: provider.overmatureCount,
                  ),
                  const SizedBox(height: 12),
                  _recommendationCard(context, provider.recommendation),
                  const SizedBox(height: 14),
                  _detectedList(context, detections),
                  const SizedBox(height: 6),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pushReplacement(
                      fadeRoute(const CameraScreen()),
                    ),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Scan Again'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _statusBanner({
    required BuildContext context,
    required bool detectionsFound,
    required int count,
  }) {
    final color = detectionsFound ? AppConstants.primaryGreen : Colors.blueGrey;
    final title = detectionsFound
        ? '$count calabash ${count == 1 ? 'fruit' : 'fruits'} detected'
        : 'No calabash fruits detected';
    final message = detectionsFound
        ? 'Review each mask and maturity label below.'
        : 'Try a clearer photo with the calabash centered and well lit.';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(
            detectionsFound ? Icons.check_circle_rounded : Icons.search_off_rounded,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
                Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.black.withValues(alpha: 0.60),
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _recommendationCard(BuildContext context, String recommendation) {
    return Card(
      color: AppConstants.secondaryLightGreen.withValues(alpha: 0.24),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.tips_and_updates_rounded,
              color: AppConstants.primaryGreen,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                recommendation,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detectedList(BuildContext context, List<Detection> detections) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Detected Calabash Fruits',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: AppConstants.primaryGreen,
              ),
        ),
        const SizedBox(height: 8),
        if (detections.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  Icon(
                    Icons.eco_outlined,
                    color: Colors.blueGrey.shade400,
                    size: 38,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'No calabash fruits detected in the current image.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Other objects or non-calabash fruits may be present, but the model did not identify calabash.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.black.withValues(alpha: 0.60),
                        ),
                  ),
                ],
              ),
            ),
          )
        else
          ...detections.asMap().entries.map(
                (entry) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ResultCard(
                    detection: entry.value,
                    index: entry.key + 1,
                  ),
                ),
              ),
      ],
    );
  }

  Widget _imageWithOverlays({
    required File imageFile,
    required List<Detection> detections,
  }) {
    return FutureBuilder<ui.Image>(
      future: _decodeImage(imageFile),
      builder: (context, snapshot) {
        return Card(
          clipBehavior: Clip.antiAlias,
          child: AspectRatio(
            aspectRatio: 1,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final frameRect = _computeImageRect(
                  image: snapshot.data,
                  containerSize: Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  ),
                );

                return Stack(
                  children: [
                    Positioned.fromRect(
                      rect: frameRect,
                      child: snapshot.hasData
                          ? Image.file(
                              imageFile,
                              fit: BoxFit.fill,
                            )
                          : const ColoredBox(
                              color: Colors.black12,
                              child: Center(
                                child: CircularProgressIndicator(),
                              ),
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
