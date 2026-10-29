import 'dart:async';

import 'package:calabash_maturity_detection/integration_test/smoke_stage_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SmokeStageRunner', () {
    test('logs successful stage completion with elapsed time', () async {
      final messages = <String>[];
      final runner = SmokeStageRunner(log: messages.add);

      final result = await runner.run<int>(
        'photo processing',
        timeout: const Duration(seconds: 1),
        operation: () async => 42,
      );

      expect(result, 42);
      expect(messages, hasLength(2));
      expect(messages.first, contains('START photo processing'));
      expect(messages.last, contains('PASS photo processing'));
      expect(messages.last, contains('[stage='));
    });

    test(
      'reports the stage name and elapsed time when an operation stalls',
      () async {
        final messages = <String>[];
        final runner = SmokeStageRunner(log: messages.add);

        await expectLater(
          runner.run<void>(
            'live worker inference',
            timeout: const Duration(milliseconds: 10),
            operation: () => Completer<void>().future,
          ),
          throwsA(
            isA<SmokeStageTimeoutException>()
                .having(
                  (error) => error.stage,
                  'stage',
                  'live worker inference',
                )
                .having((error) => error.elapsed, 'elapsed', isNotNull),
          ),
        );
        expect(messages.join('\n'), contains('TIMEOUT live worker inference'));
      },
    );

    test('defers late cleanup until a timed-out operation settles', () async {
      final operation = Completer<int>();
      final cleanupFinished = Completer<void>();
      final runner = SmokeStageRunner(log: (_) {});

      await expectLater(
        runner.run<int>(
          'photo processing',
          timeout: const Duration(milliseconds: 10),
          operation: () => operation.future,
          onLateCompletion: cleanupFinished.complete,
        ),
        throwsA(isA<SmokeStageTimeoutException>()),
      );
      operation.complete(1);
      await cleanupFinished.future.timeout(const Duration(seconds: 1));
    });

    test('preserves operation errors and logs their details', () async {
      final messages = <String>[];
      final runner = SmokeStageRunner(log: messages.add);
      final failure = StateError('native model initialization failed');

      await expectLater(
        runner.run<void>(
          'interpreter initialization',
          timeout: const Duration(seconds: 1),
          operation: () => Future<void>.error(failure),
        ),
        throwsA(same(failure)),
      );
      expect(
        messages.join('\n'),
        contains('native model initialization failed'),
      );
    });
  });

  test('cleanup runs after failure and preserves the original error', () async {
    final messages = <String>[];
    final runner = SmokeStageRunner(log: messages.add);
    final cleanup = SmokeCleanupStack(runner);
    var resourceReleased = false;
    cleanup.add('fake interpreter', () async => resourceReleased = true);

    await expectLater(
      runWithSmokeCleanup<int>(
        runner: runner,
        cleanup: cleanup,
        operation: () async => throw StateError('inference failed'),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'inference failed',
        ),
      ),
    );

    expect(resourceReleased, isTrue);
    expect(messages.join('\n'), contains('PASS cleanup/fake interpreter'));
  });

  test('cleanup wrapper completes for a successful void operation', () async {
    final runner = SmokeStageRunner(log: (_) {});
    await expectLater(
      runWithSmokeCleanup<void>(
        runner: runner,
        cleanup: SmokeCleanupStack(runner),
        operation: () async {},
      ),
      completes,
    );
  });

  test(
    'smoke timeout configuration stays explicit and below loader timeout',
    () {
      expect(smokeTestTimeout, const Duration(minutes: 5));
      expect(smokeStageTimeouts, isNotEmpty);
      for (final timeout in smokeStageTimeouts.values) {
        expect(timeout, greaterThan(Duration.zero));
        expect(timeout, lessThan(smokeTestTimeout));
      }
    },
  );
}
