import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/material.dart';

class SummaryCard extends StatelessWidget {
  const SummaryCard({
    super.key,
    required this.total,
    required this.mature,
    required this.immature,
    required this.overmature,
  });

  final int total;
  final int mature;
  final int immature;
  final int overmature;

  @override
  Widget build(BuildContext context) {
    final fruitLabel = total == 1 ? 'fruit' : 'fruits';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppConstants.compactCardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.summarize_rounded,
                  color: AppConstants.primaryGreen,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$total calabash $fruitLabel detected',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppConstants.smallSpacing),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _pill(
                  MaturityClass.mature.label,
                  mature,
                  MaturityClass.mature.color,
                ),
                _pill(
                  MaturityClass.immature.label,
                  immature,
                  MaturityClass.immature.color,
                ),
                _pill(
                  MaturityClass.overmature.label,
                  overmature,
                  MaturityClass.overmature.color,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(String label, int value, Color color) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppConstants.cardRadius),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Text(
              '$value $label',
              style: TextStyle(color: color, fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }
}
