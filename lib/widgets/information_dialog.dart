import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:calabash_maturity_detection/utils/ui_tokens.dart';
import 'package:flutter/material.dart';

/// Content-sized help dialog with native modal focus and scrolling behavior.
class InformationDialog extends StatelessWidget {
  const InformationDialog({
    super.key,
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      scrollable: true,
      constraints: const BoxConstraints(maxWidth: UiTokens.dialogMaxWidth),
      insetPadding: const EdgeInsets.all(UiTokens.dialogPadding),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(UiTokens.dialogRadius),
      ),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: UiTokens.dialogPadding,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      title: Text(title),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyLarge,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, paragraph) in message.split('\n\n').indexed) ...[
            if (index > 0) const SizedBox(height: UiTokens.paragraphSpacing),
            Text(paragraph),
          ],
        ],
      ),
      actions: [
        TextButton(
          style: TextButton.styleFrom(
            foregroundColor: AppConstants.primaryGreen,
            textStyle: text.labelLarge,
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
