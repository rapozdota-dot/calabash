import 'dart:async';
import 'dart:io';

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/providers/detection_provider.dart';
import 'package:calabash_maturity_detection/services/image_service.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

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
