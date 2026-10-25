import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/material.dart';

class ResultCard extends StatelessWidget {
  const ResultCard({super.key, required this.detection, required this.index});

  final Detection detection;
  final int index;

  /// Shows one fruit's number, maturity label, color, and rounded confidence percentage.
  @override
  Widget build(BuildContext context) {
    final color = detection.maturityClass.color;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.compactCardPadding),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.16),
              foregroundColor: color,
              child: Text(
                '$index',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Fruit $index',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppConstants.mutedText,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    detection.maturityClass.label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  ModelConfidenceScore(
                    confidence: detection.confidence,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppConstants.mutedText,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.eco_rounded, color: color),
          ],
        ),
      ),
    );
  }
}

/// Keeps the score wording, rounding, and explanation consistent across results.
class ModelConfidenceScore extends StatelessWidget {
  const ModelConfidenceScore({super.key, required this.confidence, this.style});

  final double confidence;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            '${(confidence * 100).toStringAsFixed(0)}% Model confidence score',
            style: style,
          ),
        ),
        const ResultInformationButton(
          title: 'Model confidence score',
          message:
              "The model confidence score indicates how strongly the model favors the predicted maturity class. It does not represent the model's measured accuracy or statistical margin of error.",
        ),
      ],
    );
  }
}

/// Opens optional result explanations through a labeled, keyboard-accessible button.
class ResultInformationButton extends StatelessWidget {
  const ResultInformationButton({
    super.key,
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'About ${title.toLowerCase()}',
      icon: const Icon(Icons.info_outline_rounded, size: 20),
      color: AppConstants.primaryGreen,
      onPressed: () => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}
