import 'package:calabash_maturity_detection/providers/live_result_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 10, 12);
  test('publishes fresh frames even when inference takes over 1.2 seconds', () {
    expect(
      LiveResultPolicy.canPublish(
        capturedAt: now,
        startedAt: now.add(const Duration(milliseconds: 40)),
        publishedAt: now.add(const Duration(milliseconds: 1800)),
      ),
      isTrue,
    );
  });
  test('rejects old queued frames and excessive processing time', () {
    expect(
      LiveResultPolicy.canPublish(
        capturedAt: now,
        startedAt: now.add(const Duration(milliseconds: 500)),
        publishedAt: now.add(const Duration(milliseconds: 700)),
      ),
      isFalse,
    );
    expect(
      LiveResultPolicy.canPublish(
        capturedAt: now,
        startedAt: now,
        publishedAt: now.add(const Duration(seconds: 4)),
      ),
      isFalse,
    );
  });
  test('expiry allows the next slow frame but remains bounded', () {
    expect(
      LiveResultPolicy.overlayLifetime(const Duration(milliseconds: 2300)),
      const Duration(milliseconds: 2800),
    );
    expect(
      LiveResultPolicy.overlayLifetime(const Duration(seconds: 10)),
      const Duration(milliseconds: 3500),
    );
    expect(
      LiveResultPolicy.overlayLifetime(const Duration(milliseconds: 100)),
      const Duration(seconds: 2),
    );
  });
}
