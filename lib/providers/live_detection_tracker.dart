import 'dart:math' as math;

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/utils/constants.dart';
import 'package:flutter/widgets.dart';

enum LiveConfidenceTier { normal, weak, low }

enum LiveStabilityStatus { noCalabashDetected, holdSteady, ready }

class LiveDetection {
  const LiveDetection({
    required this.trackId,
    required this.detection,
    required this.confidenceTier,
    required this.animateBounds,
  });

  final int trackId;
  final Detection detection;
  final LiveConfidenceTier confidenceTier;
  final bool animateBounds;
}

class LiveDetectionUpdate {
  const LiveDetectionUpdate({
    required this.detections,
    required this.matchedTrackCount,
    required this.createdTrackCount,
    required this.removedTrackCount,
    required this.stabilityStatus,
  });

  final List<LiveDetection> detections;
  final int matchedTrackCount;
  final int createdTrackCount;
  final int removedTrackCount;
  final LiveStabilityStatus stabilityStatus;
}

class LiveDetectionTracker {
  LiveDetectionTracker({
    this.confirmationFrames = AppConstants.liveConfirmationFrames,
  }) : assert(confirmationFrames > 0);

  final int confirmationFrames;
  final List<_StableDetectionTrack> _tracks = [];
  int _nextTrackId = 1;

  /// Counts tracked candidates, including ones not yet confirmed for display.
  int get activeTrackCount => _tracks.length;

  /// Matches current detections to prior tracks and confirms repeated observations.
  /// Requires valid classes, confidence, and nonempty masks; missing tracks are removed immediately.
  LiveDetectionUpdate update(List<Detection> detections) {
    detections = detections
        .where(
          (detection) =>
              detection.confidence.isFinite &&
              detection.confidence >=
                  AppConstants.liveWeakConfidenceThreshold &&
              detection.maturityClass != MaturityClass.unknown &&
              detection.mask != null &&
              !detection.mask!.isEmpty,
        )
        .toList(growable: false);
    if (detections.isEmpty) {
      final removedTrackCount = _tracks.length;
      _tracks.clear();
      return LiveDetectionUpdate(
        detections: const [],
        matchedTrackCount: 0,
        createdTrackCount: 0,
        removedTrackCount: removedTrackCount,
        stabilityStatus: LiveStabilityStatus.noCalabashDetected,
      );
    }

    final oldTracks = List<_StableDetectionTrack>.of(_tracks);
    final usedTrackIndexes = <int>{};
    final updatedTracks = <_StableDetectionTrack>[];
    final liveDetections = <LiveDetection>[];
    var matchedTrackCount = 0;
    var createdTrackCount = 0;

    for (final detection in detections) {
      final match = _findBestTrackMatch(detection, oldTracks, usedTrackIndexes);

      late final _StableDetectionTrack track;
      late final bool animateBounds;
      if (match == null) {
        track = _StableDetectionTrack.fromDetection(
          id: _nextTrackId++,
          detection: detection,
        );
        track.isConfirmed = confirmationFrames == 1;
        animateBounds = false;
        createdTrackCount++;
      } else {
        track = oldTracks[match.trackIndex];
        animateBounds = _shouldAnimateBounds(
          previous: track.boundingBox,
          next: detection.boundingBox,
          centerDistance: match.centerDistance,
        );
        track.updateWith(
          detection,
          isStableMotion: _isReadyStableMotion(
            previous: track.boundingBox,
            next: detection.boundingBox,
            centerDistance: match.centerDistance,
          ),
          hasNormalConfidence:
              _confidenceTierFor(detection.confidence) ==
              LiveConfidenceTier.normal,
        );
        usedTrackIndexes.add(match.trackIndex);
        matchedTrackCount++;
      }

      updatedTracks.add(track);
      // Do not paint one-frame candidates, and never retain a missing overlay.
      if (track.observationCount < confirmationFrames) continue;
      track.isConfirmed = true;
      liveDetections.add(
        LiveDetection(
          trackId: track.id,
          detection: Detection(
            boundingBox: detection.boundingBox,
            maturityClass: track.stableClass,
            confidence: track.stableConfidence,
            mask: detection.mask,
          ),
          confidenceTier: _confidenceTierFor(
            math.min(track.stableConfidence, detection.confidence),
          ),
          animateBounds: animateBounds,
        ),
      );
    }

    final removedTrackCount = oldTracks.length - usedTrackIndexes.length;
    _tracks
      ..clear()
      ..addAll(updatedTracks);

    return LiveDetectionUpdate(
      detections: liveDetections,
      matchedTrackCount: matchedTrackCount,
      createdTrackCount: createdTrackCount,
      removedTrackCount: removedTrackCount,
      stabilityStatus: _stabilityStatusFor(liveDetections, updatedTracks),
    );
  }

  /// Discards all tracks and reports whether any were present.
  bool clear() {
    final hadTracks = _tracks.isNotEmpty;
    _tracks.clear();
    return hadTracks;
  }

  /// Finds an unused prior track using overlap, center distance, and compatible area.
  _TrackMatch? _findBestTrackMatch(
    Detection detection,
    List<_StableDetectionTrack> tracks,
    Set<int> usedTrackIndexes,
  ) {
    _TrackMatch? bestMatch;
    var bestScore = 0.0;

    for (var index = 0; index < tracks.length; index++) {
      if (usedTrackIndexes.contains(index)) {
        continue;
      }

      final track = tracks[index];
      final iou = _iou(detection.boundingBox, track.boundingBox);
      final centerDistance = _centerDistance(
        detection.boundingBox,
        track.boundingBox,
      );
      final areaRatio =
          math.min(
            detection.boundingBox.width * detection.boundingBox.height,
            track.boundingBox.width * track.boundingBox.height,
          ) /
          math.max(
            detection.boundingBox.width * detection.boundingBox.height,
            track.boundingBox.width * track.boundingBox.height,
          );
      final diagonal = math.sqrt(
        track.boundingBox.width * track.boundingBox.width +
            track.boundingBox.height * track.boundingBox.height,
      );
      final matchRadius = math.min(
        AppConstants.liveTrackCenterDistanceThreshold,
        diagonal * 0.35,
      );
      final centerScore = matchRadius > 0
          ? math.max(0.0, 1.0 - centerDistance / matchRadius)
          : 0.0;
      final score = 0.75 * iou + 0.25 * centerScore;

      if (score > bestScore &&
          areaRatio >= 0.35 &&
          (iou >= AppConstants.liveTrackIouThreshold ||
              centerDistance <= matchRadius)) {
        bestScore = score;
        bestMatch = _TrackMatch(
          trackIndex: index,
          iou: iou,
          centerDistance: centerDistance,
        );
      }
    }

    return bestMatch;
  }

  /// Allows interpolation only for small movements, avoiding sliding masks across large jumps.
  bool _shouldAnimateBounds({
    required Rect previous,
    required Rect next,
    required double centerDistance,
  }) {
    final widthDelta = _sizeDeltaRatio(previous.width, next.width);
    final heightDelta = _sizeDeltaRatio(previous.height, next.height);
    return centerDistance <=
            AppConstants.liveOverlayAnimationMaxCenterDistance &&
        widthDelta <= AppConstants.liveOverlayAnimationMaxSizeDelta &&
        heightDelta <= AppConstants.liveOverlayAnimationMaxSizeDelta;
  }

  /// Checks stricter motion/size limits used to declare a capture-ready view.
  bool _isReadyStableMotion({
    required Rect previous,
    required Rect next,
    required double centerDistance,
  }) {
    final widthDelta = _sizeDeltaRatio(previous.width, next.width);
    final heightDelta = _sizeDeltaRatio(previous.height, next.height);
    return centerDistance <= AppConstants.liveReadyCenterDistanceThreshold &&
        widthDelta <= AppConstants.liveReadySizeDeltaThreshold &&
        heightDelta <= AppConstants.liveReadySizeDeltaThreshold;
  }

  /// Measures relative size change using a nonzero baseline for tiny boxes.
  double _sizeDeltaRatio(double previous, double next) {
    final baseline = math.max(previous.abs(), 0.0001);
    return (next - previous).abs() / baseline;
  }

  /// Groups confidence into normal, weak, or low for cautious live labels.
  LiveConfidenceTier _confidenceTierFor(double confidence) {
    if (confidence >= AppConstants.liveHighConfidenceThreshold) {
      return LiveConfidenceTier.normal;
    }
    if (confidence >= AppConstants.liveWeakConfidenceThreshold) {
      return LiveConfidenceTier.weak;
    }
    return LiveConfidenceTier.low;
  }

  /// Requires visible confirmed tracks, normal confidence, and stable motion for readiness.
  LiveStabilityStatus _stabilityStatusFor(
    List<LiveDetection> liveDetections,
    List<_StableDetectionTrack> tracks,
  ) {
    if (liveDetections.isEmpty) {
      return tracks.isEmpty
          ? LiveStabilityStatus.noCalabashDetected
          : LiveStabilityStatus.holdSteady;
    }

    final allNormalConfidence = liveDetections.every(
      (detection) => detection.confidenceTier == LiveConfidenceTier.normal,
    );
    final allTracksStable = tracks.every(
      (track) =>
          track.stableMotionFrameCount >=
              AppConstants.liveReadyStableFrameThreshold &&
          track.pendingClass == null,
    );

    return allNormalConfidence && allTracksStable
        ? LiveStabilityStatus.ready
        : LiveStabilityStatus.holdSteady;
  }

  /// Measures box overlap relative to their combined area for track matching.
  double _iou(Rect a, Rect b) {
    final left = math.max(a.left, b.left);
    final top = math.max(a.top, b.top);
    final right = math.min(a.right, b.right);
    final bottom = math.min(a.bottom, b.bottom);
    final width = right - left;
    final height = bottom - top;
    if (width <= 0 || height <= 0) {
      return 0.0;
    }

    final intersection = width * height;
    final union = (a.width * a.height) + (b.width * b.height) - intersection;
    if (union <= 0) {
      return 0.0;
    }

    return intersection / union;
  }

  /// Measures distance between box centers in normalized image coordinates.
  double _centerDistance(Rect a, Rect b) {
    final dx = a.center.dx - b.center.dx;
    final dy = a.center.dy - b.center.dy;
    return math.sqrt((dx * dx) + (dy * dy));
  }
}

class _TrackMatch {
  const _TrackMatch({
    required this.trackIndex,
    required this.iou,
    required this.centerDistance,
  });

  final int trackIndex;
  final double iou;
  final double centerDistance;
}

class _StableDetectionTrack {
  _StableDetectionTrack({
    required this.id,
    required this.boundingBox,
    required this.stableClass,
    required this.stableConfidence,
    required this.stableMotionFrameCount,
  });

  /// Starts an unconfirmed track from one observation; later frames establish stability.
  factory _StableDetectionTrack.fromDetection({
    required int id,
    required Detection detection,
  }) {
    return _StableDetectionTrack(
      id: id,
      boundingBox: detection.boundingBox,
      stableClass: detection.maturityClass,
      stableConfidence: detection.confidence,
      stableMotionFrameCount:
          detection.confidence >= AppConstants.liveHighConfidenceThreshold
          ? 1
          : 0,
    );
  }

  final int id;
  Rect boundingBox;
  MaturityClass stableClass;
  double stableConfidence;
  int observationCount = 1;
  bool isConfirmed = false;
  int stableMotionFrameCount;
  MaturityClass? pendingClass;
  int pendingCount = 0;

  /// Updates motion/confidence and requires repeated evidence before switching a stage.
  /// Weak conflicting predictions cannot overwrite a confirmed maturity label.
  void updateWith(
    Detection detection, {
    required bool isStableMotion,
    required bool hasNormalConfidence,
  }) {
    observationCount++;
    stableMotionFrameCount = isStableMotion && hasNormalConfidence
        ? stableMotionFrameCount + 1
        : hasNormalConfidence
        ? 1
        : 0;
    boundingBox = detection.boundingBox;

    // Confirmation requires a consistent stage, not just a nearby box twice.
    if (!isConfirmed && detection.maturityClass != stableClass) {
      stableClass = detection.maturityClass;
      stableConfidence = detection.confidence;
      observationCount = 1;
      stableMotionFrameCount = hasNormalConfidence ? 1 : 0;
      pendingClass = null;
      pendingCount = 0;
      return;
    }

    if (detection.maturityClass == stableClass) {
      stableConfidence = detection.confidence;
      pendingClass = null;
      pendingCount = 0;
      return;
    }

    // A weak conflicting stage cannot overwrite a confirmed label.
    if (!hasNormalConfidence) {
      pendingClass = null;
      pendingCount = 0;
      return;
    }

    if (pendingClass == detection.maturityClass) {
      pendingCount++;
    } else {
      pendingClass = detection.maturityClass;
      pendingCount = 1;
    }

    if (pendingCount >= AppConstants.liveStableClassFrames) {
      stableClass = detection.maturityClass;
      stableConfidence = detection.confidence;
      pendingClass = null;
      pendingCount = 0;
    }
  }
}
