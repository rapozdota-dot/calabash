import 'package:calabash_maturity_detection/services/live_inference_worker.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prefers four-thread XNNPACK for fast Android startup', () {
    final preferred = LiveInferenceBackendPolicy.preferredQuickBackend(
      isAndroid: true,
    );

    expect(preferred, isNotNull);
    expect(preferred!.kind, TfliteBackendKind.xnnpack);
  });

  test('keeps CPU fallback candidates after XNNPACK', () {
    final fallbacks = LiveInferenceBackendPolicy.fallbackBackends(
      isAndroid: true,
      processorCount: 8,
      excludedCacheKeys: {LiveInferenceBackendPolicy.androidPreferred.cacheKey},
    );

    expect(
      fallbacks.map((config) => config.kind),
      contains(TfliteBackendKind.cpu),
    );
    expect(
      fallbacks.any(
        (config) =>
            config.kind == TfliteBackendKind.xnnpack &&
            config.threads ==
                LiveInferenceBackendPolicy.androidPreferred.threads,
      ),
      isFalse,
    );
  });

  test('does not change the preferred backend off Android', () {
    expect(
      LiveInferenceBackendPolicy.preferredQuickBackend(isAndroid: false),
      isNull,
    );
  });
}
