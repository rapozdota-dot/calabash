import 'dart:async';
import 'dart:io';

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/services/image_service.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:calabash_maturity_detection/services/performance_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

class MeasuredTestModelService extends TestModelService {
  @override
  Future<PhotoDetectionResult> detectFruitsWithMetrics(File imageFile) async {
    calls++;
    return const PhotoDetectionResult(
      modelResult: ModelDetectionResult(
        detections: [],
        timings: ModelPipelineTimings(
          preprocessMicros: 1,
          resizeLetterboxMicros: 1,
          tensorFillMicros: 0,
          inferenceMicros: 1,
          invokeMicros: 1,
          inputTensorMicros: 0,
          outputTensorMicros: 0,
          candidateParsingMicros: 0,
          nmsMicros: 0,
          protoExtractionMicros: 0,
          maskReconstructionMicros: 0,
          postprocessMicros: 1,
          totalMicros: 3,
        ),
      ),
      imageWidth: 640,
      imageHeight: 480,
      fileReadMicros: 1,
      decodeMicros: 1,
      modelInitializationMicros: 1,
    );
  }
}

class FailingMeasuredTestModelService extends MeasuredTestModelService {
  @override
  Future<PhotoDetectionResult> detectFruitsWithMetrics(File imageFile) async {
    calls++;
    throw StateError('fixture inference failure');
  }
}

class TestImageService extends ImageService {
  TestImageService(this.pick);
  final Future<File?> Function() pick;
  int calls = 0;
  ImageSource? source;

  @override
  Future<File?> pickImage({required ImageSource source}) {
    calls++;
    this.source = source;
    return pick();
  }
}

class TestModelService extends ModelService {
  TestModelService({this.infer});
  final Future<List<Detection>> Function()? infer;
  int calls = 0;

  @override
  Future<List<Detection>> detectFruits(File imageFile) {
    calls++;
    return infer?.call() ?? Future.value([]);
  }
}

void main() {
  test(
    'instrumented gallery preserves result notifications and retains each scan',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'calabash-gallery-test-',
      );
      final probe = PerformanceProbe(
        enabled: true,
        documentsDirectory: () async => directory,
      );
      final model = MeasuredTestModelService();
      final provider = DetectionProvider(
        modelService: model,
        imageService: TestImageService(() async => File('fixture.jpg')),
        performanceProbe: probe,
      );
      addTearDown(() async {
        provider.dispose();
        await probe.close();
        await directory.delete(recursive: true);
      });
      var notifications = 0;
      provider.addListener(() => notifications++);
      expect(await provider.scanFromSource(ImageSource.gallery), isTrue);
      expect(notifications, 3);
      expect(provider.isBusy, isFalse);
      expect(provider.detections, isEmpty);
      expect(provider.recommendation, contains('No calabash'));
      expect(await provider.scanFromSource(ImageSource.gallery), isTrue);
      expect(model.calls, 2);
      expect(probe.summaryFor(PerformanceScanMethod.gallery).totalCount, 2);
      expect(probe.summaryFor(PerformanceScanMethod.gallery).warmUpCount, 1);
      expect(probe.summaryFor(PerformanceScanMethod.gallery).validCount, 1);
      await probe.flush();
      final rows = (await probe.rawFile!.readAsString()).trim().split('\r\n');
      final header = rows[0].split(',');
      expect(rows[1].split(',')[header.indexOf('scanning_method')], 'Gallery');
      expect(rows[1].split(',')[header.indexOf('decode_ms')], '0.001');
      expect(
        rows[1].split(',')[header.indexOf('interpreter_invoke_ms')],
        '0.001',
      );
      expect(
        rows[1].split(',')[header.indexOf('model_preprocess_ms')],
        '0.001',
      );
      expect(rows[1].split(',')[header.indexOf('frame_transfer_ms')], isEmpty);
      expect(
        rows[1].split(',')[header.indexOf('model_initialization_ms')],
        '0.001',
      );
    },
  );

  test(
    'shutter files stay separate and cancelling gallery creates no measurement',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'calabash-capture-test-',
      );
      final probe = PerformanceProbe(
        enabled: true,
        documentsDirectory: () async => directory,
      );
      final provider = DetectionProvider(
        modelService: MeasuredTestModelService(),
        imageService: TestImageService(() async => null),
        performanceProbe: probe,
      );
      addTearDown(() async {
        provider.dispose();
        await probe.close();
        await directory.delete(recursive: true);
      });
      expect(await provider.scanFile(File('shutter.jpg')), isTrue);
      expect(await provider.scanFromSource(ImageSource.gallery), isFalse);
      expect(probe.summaryFor(PerformanceScanMethod.gallery).totalCount, 0);
      expect(probe.summaryFor(PerformanceScanMethod.capture).totalCount, 1);
    },
  );

  test(
    'failed photo processing is recorded once with its failure outcome',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'calabash-failed-photo-test-',
      );
      final probe = PerformanceProbe(
        enabled: true,
        documentsDirectory: () async => directory,
      );
      final provider = DetectionProvider(
        modelService: FailingMeasuredTestModelService(),
        imageService: TestImageService(() async => File('failed.jpg')),
        performanceProbe: probe,
      );
      addTearDown(() async {
        provider.dispose();
        await probe.close();
        await directory.delete(recursive: true);
      });

      expect(await provider.scanFromSource(ImageSource.gallery), isFalse);
      expect(probe.summaryFor(PerformanceScanMethod.gallery).totalCount, 1);
      await probe.flush();
      final rows = (await probe.rawFile!.readAsString()).trim().split('\r\n');
      expect(rows, hasLength(2));
      final header = rows.first.split(',');
      final values = rows.last.split(',');
      expect(values[header.indexOf('scanning_method')], 'Gallery');
      expect(values[header.indexOf('outcome')], 'error');
      expect(values[header.indexOf('complete_processing_ms')], isNotEmpty);
      expect(values[header.indexOf('yolo_inference_ms')], isEmpty);
    },
  );

  test(
    'cancelling gallery preserves the existing result without an error',
    () async {
      final model = TestModelService();
      final picker = TestImageService(() async => null);
      final provider = DetectionProvider(
        modelService: model,
        imageService: picker,
      );
      addTearDown(provider.dispose);
      final original = File('original.jpg');
      expect(await provider.scanFile(original), isTrue);
      expect(await provider.scanFromSource(ImageSource.gallery), isFalse);
      expect(provider.selectedImage, original);
      expect(provider.errorMessage, isNull);
      expect(provider.isBusy, isFalse);
      expect(model.calls, 1);
    },
  );

  test(
    'a pending picker blocks repeated picker and capture requests',
    () async {
      final pending = Completer<File?>();
      final picker = TestImageService(() => pending.future);
      final model = TestModelService();
      final provider = DetectionProvider(
        modelService: model,
        imageService: picker,
      );
      addTearDown(provider.dispose);
      final first = provider.scanFromSource(ImageSource.gallery);
      expect(provider.isBusy, isTrue);
      expect(await provider.scanFromSource(ImageSource.gallery), isFalse);
      expect(await provider.scanFile(File('capture.jpg')), isFalse);
      expect(picker.calls, 1);
      pending.complete(null);
      await first;
      expect(provider.isBusy, isFalse);
      expect(model.calls, 0);
    },
  );

  test(
    'analysis cannot be started twice and emits only start/end notifications',
    () async {
      final pending = Completer<List<Detection>>();
      final model = TestModelService(infer: () => pending.future);
      final provider = DetectionProvider(
        modelService: model,
        imageService: TestImageService(() async => null),
      );
      addTearDown(provider.dispose);
      var notifications = 0;
      provider.addListener(() => notifications++);
      final first = provider.scanFile(File('fruit.jpg'));
      expect(provider.isAnalyzing, isTrue);
      expect(await provider.analyzeSelectedImage(), isFalse);
      expect(model.calls, 1);
      pending.complete([]);
      expect(await first, isTrue);
      expect(notifications, 2);
      expect(provider.isBusy, isFalse);
    },
  );

  test('picker errors are handled and release the busy state', () async {
    final provider = DetectionProvider(
      modelService: TestModelService(),
      imageService: TestImageService(
        () async => throw StateError('picker unavailable'),
      ),
    );
    addTearDown(provider.dispose);
    expect(await provider.scanFromSource(ImageSource.gallery), isFalse);
    expect(provider.isBusy, isFalse);
    expect(provider.errorMessage, contains('Unable to open'));
  });
}
