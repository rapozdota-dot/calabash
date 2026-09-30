import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/material.dart';

class AnimatedDetectionBox extends ImplicitlyAnimatedWidget {
  const AnimatedDetectionBox({
    super.key,
    required this.detection,
    required this.fruitNumber,
    required this.imageWidth,
    required this.imageHeight,
    required super.duration,
    super.curve,
    this.offsetX = 0,
    this.offsetY = 0,
    this.label,
    this.subtitle,
    this.colorOverride,
  });

  final Detection detection;
  final int fruitNumber;
  final double imageWidth;
  final double imageHeight;
  final double offsetX;
  final double offsetY;
  final String? label;
  final String? subtitle;
  final Color? colorOverride;

  @override
  AnimatedWidgetBaseState<AnimatedDetectionBox> createState() =>
      _AnimatedDetectionBoxState();
}

class _AnimatedDetectionBoxState
    extends AnimatedWidgetBaseState<AnimatedDetectionBox> {
  _RectTween? _boundingBoxTween;
  _RectTween? _maskBoundsTween;

  @override
  void forEachTween(TweenVisitor<dynamic> visitor) {
    _boundingBoxTween =
        visitor(
              _boundingBoxTween,
              widget.detection.boundingBox,
              (dynamic value) => _RectTween(begin: value as Rect),
            )
            as _RectTween?;

    final maskBounds = widget.detection.mask?.bounds;
    _maskBoundsTween = maskBounds == null
        ? null
        : visitor(
                _maskBoundsTween,
                maskBounds,
                (dynamic value) => _RectTween(begin: value as Rect),
              )
              as _RectTween?;
  }

  @override
  Widget build(BuildContext context) {
    final animatedDetection = _animatedDetection();
    return DetectionBox(
      detection: animatedDetection,
      fruitNumber: widget.fruitNumber,
      imageWidth: widget.imageWidth,
      imageHeight: widget.imageHeight,
      offsetX: widget.offsetX,
      offsetY: widget.offsetY,
      label: widget.label,
      subtitle: widget.subtitle,
      colorOverride: widget.colorOverride,
    );
  }

  Detection _animatedDetection() {
    final detection = widget.detection;
    final animatedBoundingBox =
        _boundingBoxTween?.evaluate(animation) ?? detection.boundingBox;
    final mask = detection.mask;
    if (mask == null) {
      return Detection(
        boundingBox: animatedBoundingBox,
        maturityClass: detection.maturityClass,
        confidence: detection.confidence,
      );
    }

    final animatedMaskBounds =
        _maskBoundsTween?.evaluate(animation) ?? mask.bounds;
    return Detection(
      boundingBox: animatedBoundingBox,
      maturityClass: detection.maturityClass,
      confidence: detection.confidence,
      mask: SegmentationMask(
        bounds: animatedMaskBounds,
        width: mask.width,
        height: mask.height,
        pixels: mask.pixels,
      ),
    );
  }
}

class _RectTween extends Tween<Rect> {
  _RectTween({super.begin});

  @override
  Rect lerp(double t) => Rect.lerp(begin, end, t)!;
}

class DetectionBox extends StatelessWidget {
  const DetectionBox({
    super.key,
    required this.detection,
    required this.fruitNumber,
    required this.imageWidth,
    required this.imageHeight,
    this.offsetX = 0,
    this.offsetY = 0,
    this.label,
    this.subtitle,
    this.colorOverride,
  });

  final Detection detection;
  final int fruitNumber;
  final double imageWidth;
  final double imageHeight;
  final double offsetX;
  final double offsetY;
  final String? label;
  final String? subtitle;
  final Color? colorOverride;

  @override
  Widget build(BuildContext context) {
    final color = colorOverride ?? detection.maturityClass.color;
    final labelBounds = _labelBounds;
    final subtitleText = subtitle;

    if (labelBounds.width <= 0 || labelBounds.height <= 0) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: offsetX,
      top: offsetY,
      width: imageWidth,
      height: imageHeight,
      child: IgnorePointer(
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _DetectionMaskPainter(
                  detection: detection,
                  color: color,
                ),
                isComplex: true,
              ),
            ),
            Positioned(
              left: labelBounds.left,
              top: labelBounds.top,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: (imageWidth - labelBounds.left - 8).clamp(
                    92.0,
                    220.0,
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.95),
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.16),
                        blurRadius: 6,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label ??
                              '#$fruitNumber ${detection.maturityClass.label} ${(detection.confidence * 100).toStringAsFixed(0)}%',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        if (subtitleText != null) ...[
                          const SizedBox(height: 1),
                          Text(
                            subtitleText,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.86),
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Rect get _labelBounds {
    final mask = detection.mask;
    final bounds = mask?.bounds ?? detection.boundingBox;
    final left = (bounds.left * imageWidth).clamp(6.0, imageWidth - 96);
    final top = ((bounds.top * imageHeight) - 8).clamp(6.0, imageHeight - 44);

    return Rect.fromLTWH(
      left,
      top,
      bounds.width * imageWidth,
      bounds.height * imageHeight,
    );
  }
}

class _DetectionMaskPainter extends CustomPainter {
  const _DetectionMaskPainter({required this.detection, required this.color});

  final Detection detection;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final mask = detection.mask;
    if (mask == null || mask.isEmpty) {
      _paintSoftFallback(canvas, size);
      return;
    }

    final maskRect = Rect.fromLTWH(
      mask.bounds.left * size.width,
      mask.bounds.top * size.height,
      mask.bounds.width * size.width,
      mask.bounds.height * size.height,
    );
    if (maskRect.width <= 0 || maskRect.height <= 0) {
      return;
    }

    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.14)
      ..style = PaintingStyle.fill;
    final edgePaint = Paint()
      ..color = color.withValues(alpha: 0.42)
      ..style = PaintingStyle.fill;
    final cellWidth = maskRect.width / mask.width;
    final cellHeight = maskRect.height / mask.height;
    final fillPath = Path();
    final edgePath = Path();

    for (var y = 0; y < mask.height; y++) {
      for (var x = 0; x < mask.width; x++) {
        if (!mask.isActive(x, y)) {
          continue;
        }

        final cell = Rect.fromLTWH(
          maskRect.left + (x * cellWidth),
          maskRect.top + (y * cellHeight),
          cellWidth + 0.6,
          cellHeight + 0.6,
        );
        if (_isEdge(mask, x, y)) {
          edgePath.addRect(cell);
        } else {
          fillPath.addRect(cell);
        }
      }
    }

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(edgePath, edgePaint);
  }

  void _paintSoftFallback(Canvas canvas, Size size) {
    final box = detection.boundingBox;
    final rect = Rect.fromLTWH(
      box.left * size.width,
      box.top * size.height,
      box.width * size.width,
      box.height * size.height,
    );
    if (rect.width <= 0 || rect.height <= 0) {
      return;
    }

    final paint = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect,
        const Radius.circular(AppConstants.cardRadius),
      ),
      paint,
    );
  }

  bool _isEdge(SegmentationMask mask, int x, int y) {
    return !mask.isActive(x - 1, y) ||
        !mask.isActive(x + 1, y) ||
        !mask.isActive(x, y - 1) ||
        !mask.isActive(x, y + 1);
  }

  @override
  bool shouldRepaint(covariant _DetectionMaskPainter oldDelegate) {
    return oldDelegate.detection != detection || oldDelegate.color != color;
  }
}
