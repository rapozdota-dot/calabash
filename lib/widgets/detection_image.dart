import 'dart:io';

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/widgets/detection_box.dart';
import 'package:calabash_maturity_detection/utils/ui_tokens.dart';
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

  /// Creates state that retains the resolved image while detection overlays update.
  @override
  State<DetectionImage> createState() => _DetectionImageState();
}

class _DetectionImageState extends State<DetectionImage> {
  ImageStream? _stream;
  ImageInfo? _info;
  bool _failed = false;
  late final _listener = ImageStreamListener(_onImage, onError: _onError);

  /// Resolves the image using current Flutter image-cache and display configuration.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveImage();
  }

  /// Reloads only when the file/provider changes, not when new detections arrive.
  @override
  void didUpdateWidget(covariant DetectionImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageFile.path != widget.imageFile.path ||
        oldWidget.imageProvider != widget.imageProvider) {
      _resolveImage();
    }
  }

  /// Subscribes to a cached image stream and replaces listeners only for a different image.
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

  /// Replaces the retained image and disposes its predecessor after rendering completes.
  void _replaceImage(ImageInfo? info) {
    final old = _info;
    _info = info;
    // The render object may still use the previous image until this frame ends.
    SchedulerBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  /// Stores a decoded frame for both dimensions and rendering, releasing it if unmounted.
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

  /// Clears an unusable image and switches the widget to its friendly error state.
  void _onError(Object error, StackTrace? stack) {
    if (mounted) {
      setState(() {
        _replaceImage(null);
        _failed = true;
      });
    }
  }

  /// Detaches the image listener and safely releases the retained native image reference.
  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _replaceImage(null);
    super.dispose();
  }

  /// Contains the cached image and maps normalized masks into the identical fitted rectangle.
  @override
  Widget build(BuildContext context) {
    final image = _info?.image;
    return LayoutBuilder(
      builder: (context, available) {
        final maxHeight =
            (MediaQuery.sizeOf(context).height *
                    UiTokens.previewViewportFraction)
                .clamp(1.0, UiTokens.previewMaxHeight);
        final preview = applyBoxFit(
          BoxFit.contain,
          image == null
              ? const Size(1, 1)
              : Size(image.width.toDouble(), image.height.toDouble()),
          Size(available.maxWidth, maxHeight),
        ).destination;
        return Align(
          alignment: Alignment.topCenter,
          child: Card(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: preview.width,
              height: preview.height,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (image == null) {
                    return Center(
                      child: _failed
                          ? const Text('Unable to display this image.')
                          : const CircularProgressIndicator(),
                    );
                  }
                  final size = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
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
          ),
        );
      },
    );
  }
}
