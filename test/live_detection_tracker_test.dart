import 'dart:typed_data';

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/providers/live_detection_tracker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('photo-level confidence appears as tentative after confirmation', () {
    final tracker = LiveDetectionTracker();
    final candidate = _detection(left: 0.1, top: 0.1, confidence: 0.47);
    expect(tracker.update([candidate]).detections, isEmpty);
    final result = tracker.update([candidate]);
    expect(result.detections.single.confidenceTier, LiveConfidenceTier.weak);
    expect(result.stabilityStatus, LiveStabilityStatus.holdSteady);
  });
  test('keeps stable IDs when matched detections arrive reordered', () {
    final tracker = LiveDetectionTracker(confirmationFrames: 1);
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
    final tracker = LiveDetectionTracker(confirmationFrames: 1);
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
    final tracker = LiveDetectionTracker(confirmationFrames: 1);
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
      final tracker = LiveDetectionTracker(confirmationFrames: 1);
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

  test('reports ready after three stable normal-confidence frames', () {
    final tracker = LiveDetectionTracker(confirmationFrames: 1);

    final first = tracker.update([_detection(left: 0.10, top: 0.10)]);
    final second = tracker.update([_detection(left: 0.12, top: 0.10)]);
    final third = tracker.update([_detection(left: 0.13, top: 0.10)]);

    expect(first.stabilityStatus, LiveStabilityStatus.holdSteady);
    expect(second.stabilityStatus, LiveStabilityStatus.holdSteady);
    expect(third.stabilityStatus, LiveStabilityStatus.ready);
  });

  test('keeps weak or unstable detections in hold steady', () {
    final tracker = LiveDetectionTracker(confirmationFrames: 1);

    final weak = tracker.update([
      _detection(left: 0.10, top: 0.10, confidence: 0.55),
    ]);
    final unstable = tracker.update([
      _detection(left: 0.16, top: 0.10, confidence: 0.92),
    ]);

    expect(weak.stabilityStatus, LiveStabilityStatus.holdSteady);
    expect(unstable.stabilityStatus, LiveStabilityStatus.holdSteady);
  });

  test('reports no calabash after detections clear', () {
    final tracker = LiveDetectionTracker(confirmationFrames: 1);
    tracker.update([_detection(left: 0.10, top: 0.10)]);

    final cleared = tracker.update([]);

    expect(cleared.stabilityStatus, LiveStabilityStatus.noCalabashDetected);
  });
  test(
    'requires two observations and removes missing overlays immediately',
    () {
      final tracker = LiveDetectionTracker();
      final first = tracker.update([_detection(left: 0.1, top: 0.1)]);
      expect(first.detections, isEmpty);
      expect(first.stabilityStatus, LiveStabilityStatus.holdSteady);
      expect(
        tracker.update([_detection(left: 0.11, top: 0.1)]).detections,
        hasLength(1),
      );
      expect(tracker.update([]).detections, isEmpty);
      expect(
        tracker.update([_detection(left: 0.1, top: 0.1)]).detections,
        isEmpty,
      );
    },
  );

  test('rejects weak, unknown, and maskless candidates', () {
    final tracker = LiveDetectionTracker(confirmationFrames: 1);
    final update = tracker.update([
      _detection(left: 0.1, top: 0.1, confidence: 0.26),
      _detection(left: 0.1, top: 0.1, maturityClass: MaturityClass.unknown),
      const Detection(
        boundingBox: Rect.fromLTWH(0.1, 0.1, 0.2, 0.2),
        maturityClass: MaturityClass.immature,
        confidence: 0.99,
      ),
    ]);
    expect(update.detections, isEmpty);
  });

  test(
    'a conflicting tentative stage is not promoted to a confirmed label',
    () {
      final tracker = LiveDetectionTracker();
      tracker.update([
        _detection(
          left: 0.1,
          top: 0.1,
          confidence: 0.55,
          maturityClass: MaturityClass.immature,
        ),
      ]);
      expect(
        tracker.update([_detection(left: 0.1, top: 0.1)]).detections,
        isEmpty,
      );
      final result = tracker.update([_detection(left: 0.1, top: 0.1)]);
      expect(
        result.detections.single.detection.maturityClass,
        MaturityClass.mature,
      );
      expect(result.detections.single.detection.confidence, 0.92);
    },
  );

  test(
    'weak conflicting classes do not change confirmed labels or their scores',
    () {
      final tracker = LiveDetectionTracker(confirmationFrames: 1);
      tracker.update([_detection(left: 0.1, top: 0.1, confidence: 0.95)]);
      for (var i = 0; i < 4; i++) {
        final update = tracker.update([
          _detection(
            left: 0.1,
            top: 0.1,
            confidence: 0.55,
            maturityClass: MaturityClass.immature,
          ),
        ]);
        expect(
          update.detections.single.detection.maturityClass,
          MaturityClass.mature,
        );
        expect(update.detections.single.detection.confidence, 0.95);
        expect(
          update.detections.single.confidenceTier,
          LiveConfidenceTier.weak,
        );
        expect(update.stabilityStatus, LiveStabilityStatus.holdSteady);
      }
    },
  );

  test('class changes need three consecutive strong observations', () {
    final tracker = LiveDetectionTracker(confirmationFrames: 1);
    tracker.update([_detection(left: 0.1, top: 0.1)]);
    for (var i = 0; i < 3; i++) {
      final update = tracker.update([
        _detection(
          left: 0.1,
          top: 0.1,
          confidence: 0.88,
          maturityClass: MaturityClass.immature,
        ),
      ]);
      expect(
        update.detections.single.detection.maturityClass,
        i < 2 ? MaturityClass.mature : MaturityClass.immature,
      );
      expect(
        update.detections.single.detection.confidence,
        i < 2 ? 0.92 : 0.88,
      );
    }
  });

  test('does not attach a tiny nearby false box to a large fruit track', () {
    final tracker = LiveDetectionTracker(confirmationFrames: 1);
    final first = tracker.update([
      _detection(left: 0.1, top: 0.1, width: 0.4, height: 0.4),
    ]);
    final next = tracker.update([
      _detection(left: 0.29, top: 0.29, width: 0.02, height: 0.02),
    ]);
    expect(
      next.detections.single.trackId,
      isNot(first.detections.single.trackId),
    );
  });
}

Detection _detection({
  required double left,
  required double top,
  double width = 0.20,
  double height = 0.20,
  double confidence = 0.92,
  MaturityClass maturityClass = MaturityClass.mature,
}) {
  return Detection(
    boundingBox: Rect.fromLTWH(left, top, width, height),
    maturityClass: maturityClass,
    confidence: confidence,
    mask: SegmentationMask(
      bounds: Rect.fromLTWH(left, top, width, height),
      width: 2,
      height: 2,
      pixels: Uint8List.fromList([1, 1, 1, 1]),
    ),
  );
}
