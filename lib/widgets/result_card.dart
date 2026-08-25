import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:flutter/material.dart';

class ResultCard extends StatelessWidget {
  const ResultCard({
    super.key,
    required this.detection,
    required this.index,
  });

  final Detection detection;
  final int index;

  @override
  Widget build(BuildContext context) {
    final color = detection.maturityClass.color;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
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
                    detection.maturityClass.label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                  ),
                  Text(
                    'Confidence ${(detection.confidence * 100).toStringAsFixed(0)}%',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.black.withValues(alpha: 0.60),
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
