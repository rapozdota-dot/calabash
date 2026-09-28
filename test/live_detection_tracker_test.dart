import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/providers/live_detection_tracker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps stable IDs when matched detections arrive reordered', () {
    final tracker = LiveDetectionTracker();
    final first = tracker.update([
      _detection(left: 0.10, top: 0.10),
      _detection(left: 0.60, top: 0.10),
    ]);

    final leftFruitId = first.detections[0].trackId;
    final rightFruitId = first.detections[1].trackId;

    final second = tracker.update([
      _detection(left: 0.61, top: 0.10),
      _detection(left: 0.11, top: 0.10),
    ]);

    expect(second.detections[0].trackId, rightFruitId);
    expect(second.detections[1].trackId, leftFruitId);
    expect(second.matchedTrackCount, 2);
    expect(second.createdTrackCount, 0);
  });

  test('creates a new track instead of forcing a weak association', () {
    final tracker = LiveDetectionTracker();
    final first = tracker.update([_detection(left: 0.10, top: 0.10)]);

    final second = tracker.update([_detection(left: 0.70, top: 0.10)]);

    expect(
      second.detections.single.trackId,
      isNot(first.detections.single.trackId),
    );
    expect(second.createdTrackCount, 1);
    expect(second.removedTrackCount, 1);
    expect(second.detections.single.animateBounds, isFalse);
  });

  test('clear removes active tracks and does not reuse the next ID', () {
    final tracker = LiveDetectionTracker();
    final first = tracker.update([_detection(left: 0.10, top: 0.10)]);

    expect(tracker.clear(), isTrue);

    final second = tracker.update([_detection(left: 0.10, top: 0.10)]);

    expect(
      second.detections.single.trackId,
      isNot(first.detections.single.trackId),
    );
    expect(second.createdTrackCount, 1);
  });

  test(
    'marks only small matched movement as eligible for bounds animation',
    () {
      final tracker = LiveDetectionTracker();
      final first = tracker.update([
        _detection(left: 0.10, top: 0.10, width: 0.40, height: 0.40),
      ]);

      final smallMove = tracker.update([
        _detection(left: 0.13, top: 0.10, width: 0.40, height: 0.40),
      ]);

      expect(
        smallMove.detections.single.trackId,
        first.detections.single.trackId,
      );
      expect(smallMove.detections.single.animateBounds, isTrue);

      final largerMove = tracker.update([
        _detection(left: 0.25, top: 0.10, width: 0.40, height: 0.40),
      ]);

      expect(
        largerMove.detections.single.trackId,
        first.detections.single.trackId,
      );
      expect(largerMove.detections.single.animateBounds, isFalse);
    },
  );
}

Detection _detection({
  required double left,
  required double top,
  double width = 0.20,
  double height = 0.20,
  MaturityClass maturityClass = MaturityClass.mature,
}) {
  return Detection(
    boundingBox: Rect.fromLTWH(left, top, width, height),
    maturityClass: maturityClass,
    confidence: 0.92,
  );
}
