import 'dart:typed_data';

import 'package:calabash_maturity_detection/services/live_inference_worker.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _StartupModel extends ModelService {
  _StartupModel({this.fail = false});
  final bool fail;
  int loads = 0;
  bool disposed = false;
  @override
  Future<void> loadModel() async {
    loads++;
    if (fail) throw StateError('Delegate unavailable');
  }

  @override
  Future<TfliteBackendBenchmark> benchmarkInference({
    int warmupRuns = 1,
    int measuredRuns = 3,
  }) => throw StateError('Startup must never benchmark');

  @override
  void dispose() => disposed = true;
}

void main() {
  test('starts on first compatible backend without dummy inference', () async {
    final configs = <TfliteBackendConfig>[];
    final model = _StartupModel();
    final runtime = LiveInferenceWorkerRuntime(
      isAndroid: true,
      processorCount: 8,
      modelServiceFactory: (bytes, config) {
        configs.add(config);
        return model;
      },
    );
    final info = await runtime.initialize(
      modelBytes: Uint8List(0),
      cachedBackendConfig: null,
    );
    expect(configs, hasLength(1));
    expect(info.selectedConfig.kind, TfliteBackendKind.xnnpack);
    expect(info.selectedConfig.threads, 4);
    expect(model.loads, 1);
    expect(info.fromCache, isFalse);
    runtime.dispose();
    expect(model.disposed, isTrue);
  });

  test(
    'disposes failed delegates and stops as soon as fallback loads',
    () async {
      final models = <_StartupModel>[];
      final runtime = LiveInferenceWorkerRuntime(
        isAndroid: true,
        processorCount: 8,
        modelServiceFactory: (bytes, config) {
          final model = _StartupModel(fail: models.isEmpty);
          models.add(model);
          return model;
        },
      );
      final info = await runtime.initialize(
        modelBytes: Uint8List(0),
        cachedBackendConfig: null,
      );
      expect(models, hasLength(2));
      expect(models.first.disposed, isTrue);
      expect(info.attempts.map((a) => a.initialized), [false, true]);
      runtime.dispose();
    },
  );

  test(
    'cached backend is reused without benchmark or duplicate attempts',
    () async {
      final configs = <TfliteBackendConfig>[];
      final runtime = LiveInferenceWorkerRuntime(
        isAndroid: true,
        modelServiceFactory: (bytes, config) {
          configs.add(config);
          return _StartupModel();
        },
      );
      final info = await runtime.initialize(
        modelBytes: Uint8List(0),
        cachedBackendConfig: TfliteBackendConfig.cpu2,
      );
      expect(configs, [TfliteBackendConfig.cpu2]);
      expect(info.fromCache, isTrue);
      runtime.dispose();
    },
  );

  test('failed cached preference is not tried twice', () async {
    final keys = <String>[];
    final runtime = LiveInferenceWorkerRuntime(
      isAndroid: true,
      modelServiceFactory: (bytes, config) {
        keys.add(config.cacheKey);
        return _StartupModel(fail: true);
      },
    );
    await expectLater(
      runtime.initialize(
        modelBytes: Uint8List(0),
        cachedBackendConfig: LiveInferenceBackendPolicy.androidPreferred,
      ),
      throwsStateError,
    );
    expect(keys.toSet().length, keys.length);
    runtime.dispose();
  });
}
