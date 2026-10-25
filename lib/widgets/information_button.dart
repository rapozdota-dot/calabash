import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:calabash_maturity_detection/utils/ui_tokens.dart';
import 'package:calabash_maturity_detection/widgets/information_dialog.dart';
import 'package:flutter/material.dart';

/// One outlined information affordance, including its full accessible tap target.
class InformationIconButton extends StatelessWidget {
  const InformationIconButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    this.color,
    this.disabledColor,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Color? color;
  final Color? disabledColor;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    color: color ?? AppConstants.primaryGreen,
    disabledColor: disabledColor,
    visualDensity: VisualDensity.standard,
    constraints: const BoxConstraints(
      minWidth: UiTokens.minimumTouchTarget,
      minHeight: UiTokens.minimumTouchTarget,
    ),
    icon: const Icon(
      Icons.info_outline_rounded,
      size: UiTokens.informationIconSize,
    ),
  );
}

class InformationButton extends StatelessWidget {
  const InformationButton({
    super.key,
    required this.title,
    required this.message,
    this.tooltip,
    this.enabled = true,
    this.color,
    this.disabledColor,
  });

  final String title;
  final String message;
  final String? tooltip;
  final bool enabled;
  final Color? color;
  final Color? disabledColor;

  @override
  Widget build(BuildContext context) => InformationIconButton(
    tooltip: tooltip ?? 'About ${title.toLowerCase()}',
    color: color,
    disabledColor: disabledColor,
    onPressed: enabled
        ? () => showDialog<void>(
            context: context,
            builder: (_) => InformationDialog(title: title, message: message),
          )
        : null,
  );
}

/// Keeps the help button next to its flexible label, including when it wraps.
class InformationLabel extends StatelessWidget {
  const InformationLabel({
    super.key,
    required this.text,
    required this.title,
    required this.message,
    this.style,
  });

  final String text;
  final String title;
  final String message;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Flexible(
        child: Text(
          text,
          style: style ?? Theme.of(context).textTheme.bodyMedium,
        ),
      ),
      const SizedBox(width: UiTokens.informationGap),
      InformationButton(title: title, message: message),
    ],
  );
}
