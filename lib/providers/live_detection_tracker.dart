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
  final List<_StableDetectionTrack> _tracks = [];
  int _nextTrackId = 1;

  int get activeTrackCount => _tracks.length;

  LiveDetectionUpdate update(List<Detection> detections) {
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
      liveDetections.add(
        LiveDetection(
          trackId: track.id,
          detection: Detection(
            boundingBox: detection.boundingBox,
            maturityClass: track.stableClass,
            confidence: detection.confidence,
            mask: detection.mask,
          ),
          confidenceTier: _confidenceTierFor(detection.confidence),
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

  bool clear() {
    final hadTracks = _tracks.isNotEmpty;
    _tracks.clear();
    return hadTracks;
  }

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
      final centerScore = math.max(0.0, 1.0 - centerDistance);
      final score = math.max(iou, centerScore);

      if (score > bestScore &&
          (iou >= AppConstants.liveTrackIouThreshold ||
              centerDistance <=
                  AppConstants.liveTrackCenterDistanceThreshold)) {
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

  double _sizeDeltaRatio(double previous, double next) {
    final baseline = math.max(previous.abs(), 0.0001);
    return (next - previous).abs() / baseline;
  }

  LiveConfidenceTier _confidenceTierFor(double confidence) {
    if (confidence >= AppConstants.liveHighConfidenceThreshold) {
      return LiveConfidenceTier.normal;
    }
    if (confidence >= AppConstants.liveWeakConfidenceThreshold) {
      return LiveConfidenceTier.weak;
    }
    return LiveConfidenceTier.low;
  }

  LiveStabilityStatus _stabilityStatusFor(
    List<LiveDetection> liveDetections,
    List<_StableDetectionTrack> tracks,
  ) {
    if (liveDetections.isEmpty) {
      return LiveStabilityStatus.noCalabashDetected;
    }

    final allNormalConfidence = liveDetections.every(
      (detection) => detection.confidenceTier == LiveConfidenceTier.normal,
    );
    final allTracksStable = tracks.every(
      (track) =>
          track.stableMotionFrameCount >=
          AppConstants.liveReadyStableFrameThreshold,
    );

    return allNormalConfidence && allTracksStable
        ? LiveStabilityStatus.ready
        : LiveStabilityStatus.holdSteady;
  }

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
    required this.stableMotionFrameCount,
  });

  factory _StableDetectionTrack.fromDetection({
    required int id,
    required Detection detection,
  }) {
    return _StableDetectionTrack(
      id: id,
      boundingBox: detection.boundingBox,
      stableClass: detection.maturityClass,
      stableMotionFrameCount:
          detection.confidence >= AppConstants.liveHighConfidenceThreshold
          ? 1
          : 0,
    );
  }

  final int id;
  Rect boundingBox;
  MaturityClass stableClass;
  int stableMotionFrameCount;
  MaturityClass? pendingClass;
  int pendingCount = 0;

  void updateWith(
    Detection detection, {
    required bool isStableMotion,
    required bool hasNormalConfidence,
  }) {
    stableMotionFrameCount = isStableMotion && hasNormalConfidence
        ? stableMotionFrameCount + 1
        : hasNormalConfidence
        ? 1
        : 0;
    boundingBox = detection.boundingBox;

    if (detection.maturityClass == stableClass) {
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
      pendingClass = null;
      pendingCount = 0;
    }
  }
}
