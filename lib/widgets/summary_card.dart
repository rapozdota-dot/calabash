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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
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
                Text(
                  'Detection Summary',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            _row('Calabash Fruits Detected', total, Colors.blueGrey),
            const Divider(height: 22),
            _row('Mature', mature, Colors.green.shade700),
            _row('Immature', immature, Colors.amber.shade700),
            _row('Overmature', overmature, Colors.red.shade700),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, int value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          Text(
            '$value',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}
