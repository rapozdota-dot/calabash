/// Slow inference is different from an old frame waiting in a queue.
class LiveResultPolicy {
  static const maxQueueAge = Duration(milliseconds: 250);
  static const maxResultAge = Duration(seconds: 3);

  /// Accepts results only within both the queue-age and total-age limits.
  static bool canPublish({
    required DateTime capturedAt,
    required DateTime startedAt,
    required DateTime publishedAt,
  }) {
    final queueAge = startedAt.difference(capturedAt);
    final age = publishedAt.difference(capturedAt);
    return queueAge >= Duration.zero &&
        queueAge <= maxQueueAge &&
        age >= queueAge &&
        age <= maxResultAge;
  }

  /// Gives slower inference a longer overlay lifetime, bounded to 2-3.5 seconds.
  static Duration overlayLifetime(Duration processingTime) => Duration(
    milliseconds: (processingTime.inMilliseconds + 500).clamp(2000, 3500),
  );
}
