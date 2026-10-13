import 'dart:io';

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/widgets/detection_box.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Reuses Flutter's image cache for both dimensions and rendering.
class DetectionImage extends StatefulWidget {
  const DetectionImage({
    required this.imageFile,
    required this.detections,
    this.imageProvider,
    super.key,
  });

  final File imageFile;
  final List<Detection> detections;
  final ImageProvider? imageProvider;

  @override
  State<DetectionImage> createState() => _DetectionImageState();
}

class _DetectionImageState extends State<DetectionImage> {
  ImageStream? _stream;
  ImageInfo? _info;
  bool _failed = false;
  late final _listener = ImageStreamListener(_onImage, onError: _onError);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  @override
  void didUpdateWidget(covariant DetectionImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageFile.path != widget.imageFile.path ||
        oldWidget.imageProvider != widget.imageProvider) {
      _resolveImage();
    }
  }

  void _resolveImage() {
    final provider = widget.imageProvider ?? FileImage(widget.imageFile);
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _replaceImage(null);
    _failed = false;
    _stream = stream;
    stream.addListener(_listener);
  }

  void _replaceImage(ImageInfo? info) {
    final old = _info;
    _info = info;
    // The render object may still use the previous image until this frame ends.
    SchedulerBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    if (!mounted) {
      info.dispose();
      return;
    }
    setState(() {
      _replaceImage(info);
      _failed = false;
    });
  }

  void _onError(Object error, StackTrace? stack) {
    if (mounted) {
      setState(() {
        _replaceImage(null);
        _failed = true;
      });
    }
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _replaceImage(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _info?.image;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: AspectRatio(
        aspectRatio: image == null
            ? 1
            : (image.width / image.height).clamp(.72, 1.45).toDouble(),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (image == null) {
              return Center(
                child: _failed
                    ? const Text('Unable to display this image.')
                    : const CircularProgressIndicator(),
              );
            }
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            final fitted = applyBoxFit(
              BoxFit.contain,
              Size(image.width.toDouble(), image.height.toDouble()),
              size,
            );
            final rect = Alignment.center.inscribe(
              fitted.destination,
              Offset.zero & size,
            );
            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(color: Colors.black.withValues(alpha: .88)),
                ),
                Positioned.fromRect(
                  rect: rect,
                  child: RawImage(image: image, fit: BoxFit.fill),
                ),
                ...widget.detections.asMap().entries.map(
                  (entry) => DetectionBox(
                    detection: entry.value,
                    fruitNumber: entry.key + 1,
                    imageWidth: rect.width,
                    imageHeight: rect.height,
                    offsetX: rect.left,
                    offsetY: rect.top,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
