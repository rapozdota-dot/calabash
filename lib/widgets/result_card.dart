import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:calabash_maturity_detection/utils/prediction_explanations.dart';
import 'package:calabash_maturity_detection/widgets/information_button.dart';
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
              foregroundColor: AppConstants.softText,
              child: Text(
                '$index',
                style: Theme.of(context).textTheme.titleMedium,
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
                    ),
                  ),
                  Text(
                    detection.maturityClass.label,
                    style: Theme.of(context).textTheme.titleMedium,
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
    return InformationLabel(
      text: '${(confidence * 100).toStringAsFixed(0)}% Model confidence score',
      style: style,
      title: 'Model confidence score',
      message: PredictionExplanations.confidence,
    );
  }
}
