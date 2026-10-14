import 'dart:io';

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/services/image_service.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
import 'package:calabash_maturity_detection/services/performance_probe.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

class DetectionProvider extends ChangeNotifier {
  DetectionProvider({
    required ModelService modelService,
    required ImageService imageService,
  }) : _modelService = modelService,
       _imageService = imageService;

  final ModelService _modelService;
  final ImageService _imageService;

  bool _isInitializing = false;
  bool _isAnalyzing = false;
  bool _isPickingImage = false;
  bool _didInitialize = false;
  bool _isDisposed = false;
  int _scanGeneration = 0;

  String? _errorMessage;
  String _recommendation = 'Run a scan to get a harvest recommendation.';

  File? _selectedImage;
  List<Detection> _detections = [];
  String _measurementMethod = 'photo';

  /// Exposes model-loading progress to the startup screen.
  bool get isInitializing => _isInitializing;

  /// Exposes photo inference progress to loading indicators.
  bool get isAnalyzing => _isAnalyzing;

  /// Blocks new scans while initialization, image selection, or inference is active.
  bool get isBusy => _isInitializing || _isAnalyzing || _isPickingImage;

  /// Exposes the latest model, picker, or photo-analysis failure for the UI.
  String? get errorMessage => _errorMessage;

  /// Exposes count-based harvest guidance for the current photo result.
  String get recommendation => _recommendation;

  /// Provides access to the shared photo-inference service.
  ModelService get modelService => _modelService;

  /// Returns the file currently shown and analyzed on the result screen.
  File? get selectedImage => _selectedImage;

  /// Returns the current photo's filtered detections and their display masks.
  List<Detection> get detections => _detections;

  /// Counts final detections, not raw anchors produced by YOLO.
  int get totalDetected => _detections.length;

  /// Counts detections classified as Mature for the summary and recommendation.
  int get matureCount =>
      _detections.where((d) => d.maturityClass == MaturityClass.mature).length;

  /// Counts detections classified as Immature for the summary and recommendation.
  int get immatureCount => _detections
      .where((d) => d.maturityClass == MaturityClass.immature)
      .length;

  /// Counts detections classified as Overmature for the summary and recommendation.
  int get overmatureCount => _detections
      .where((d) => d.maturityClass == MaturityClass.overmature)
      .length;

  /// Loads the bundled model once and notifies the splash when loading finishes.
  /// Failures are exposed as UI errors rather than crashing startup.
  Future<void> initialize() async {
    if (_didInitialize || _isInitializing || _isDisposed) {
      return;
    }

    _isInitializing = true;
    notifyListeners();

    try {
      await _modelService.loadModel();
      _didInitialize = true;
      _errorMessage = null;
    } catch (error) {
      _errorMessage = 'Model could not be loaded: $error';
    }

    _isInitializing = false;
    notifyListeners();
  }

  /// Opens the camera/gallery picker and analyzes the chosen file.
  /// Duplicate requests are blocked; cancellation preserves the previous result.
  Future<bool> scanFromSource(ImageSource source) async {
    if (isBusy || _isDisposed) return false;
    final generation = _scanGeneration;
    _errorMessage = null;
    _isPickingImage = true;
    notifyListeners();

    File? pickedImage;
    try {
      pickedImage = await _imageService.pickImage(source: source);
    } catch (error) {
      if (measurementTimer != null) {
        PerformanceProbe.record(
          method: _measurementMethod,
          timer: measurementTimer,
          startedAt: measurementStart!,
          detections: 0,
          backend: 'CPU, threads=2',
          imagePath: image.path,
          outcome: 'error',
        );
      }
      if (!_isDisposed && generation == _scanGeneration) {
        _errorMessage = 'Unable to open the image picker. Please try again.';
      }
      debugPrint('Image selection failed: $error');
    }
    _isPickingImage = false;
    if (_isDisposed || generation != _scanGeneration) {
      notifyListeners();
      return false;
    }
    if (pickedImage == null) {
      // Cancellation is a normal action; keep any existing result intact.
      notifyListeners();
      return false;
    }

    return scanFile(pickedImage, measurementMethod: source.name);
  }

  /// Selects a captured or picked photo, clears old detections, and starts analysis.
  Future<bool> scanFile(
    File imageFile, {
    String measurementMethod = 'photo',
  }) async {
    if (isBusy || _isDisposed) return false;

    _selectedImage = imageFile;
    _measurementMethod = measurementMethod;
    _detections = [];
    return analyzeSelectedImage();
  }

  /// Runs the photo pipeline, updates detections and guidance, and reports errors.
  /// The finally block always clears the busy state and refreshes listeners.
  Future<bool> analyzeSelectedImage() async {
    if (isBusy || _isDisposed) return false;
    if (_selectedImage == null) {
      _errorMessage = 'Please capture or choose an image first.';
      notifyListeners();
      return false;
    }

    final measurementStart = PerformanceProbe.enabled ? DateTime.now() : null;
    final measurementTimer = PerformanceProbe.enabled
        ? (Stopwatch()..start())
        : null;
    _isAnalyzing = true;
    final generation = ++_scanGeneration;
    final image = _selectedImage!;
    _detections = [];
    _recommendation = 'Analysis has not completed. Please try again.';
    _errorMessage = null;
    notifyListeners();

    try {
      final detections = await _modelService.detectFruits(image);
      // Back/clear/dispose invalidates the result, not the native computation.
      // Keep busy until computation ends to prevent overlapping photo workers.
      if (_isDisposed || generation != _scanGeneration) return false;
      _detections = detections;
      // Recommendation logic is intentionally simple and explainable for field use.
      _recommendation = _buildRecommendation(
        mature: matureCount,
        immature: immatureCount,
        overmature: overmatureCount,
      );
      if (measurementTimer != null) {
        PerformanceProbe.record(
          method: _measurementMethod,
          timer: measurementTimer,
          startedAt: measurementStart!,
          detections: _detections.length,
          backend: 'CPU, threads=2',
          imagePath: image.path,
        );
      }
      return true;
    } catch (error) {
      if (!_isDisposed && generation == _scanGeneration) {
        _errorMessage = 'Unable to analyze this image. Try another photo.';
        debugPrint('Photo analysis failed: $error');
      }
      return false;
    } finally {
      _isAnalyzing = false;
      notifyListeners();
    }
  }

  /// Clears the selected photo, detections, errors, and guidance for a new scan.
  void clearCurrentResult() {
    _scanGeneration++;
    _selectedImage = null;
    _detections = [];
    _recommendation = 'Run a scan to get a harvest recommendation.';
    _errorMessage = null;
    notifyListeners();
  }

  /// Async completions must never notify widgets after this provider is removed.
  @override
  void notifyListeners() {
    if (!_isDisposed) super.notifyListeners();
  }

  /// Chooses simple guidance from stage counts, not another AI model.
  /// Ties favor Mature first, then Immature; zero detections have separate guidance.
  String _buildRecommendation({
    required int mature,
    required int immature,
    required int overmature,
  }) {
    if ((mature + immature + overmature) == 0) {
      return 'No calabash fruits detected. Please capture a clearer image.';
    }

    if (mature >= immature && mature >= overmature) {
      return 'These fruits are ready for harvesting.';
    }

    if (immature >= mature && immature >= overmature) {
      return 'Allow more time for ripening before harvest.';
    }

    return 'These fruits may be overripe. Prioritize immediate sorting.';
  }

  /// Releases the shared interpreter when this provider is removed.
  @override
  void dispose() {
    _isDisposed = true;
    _scanGeneration++;
    _modelService.dispose();
    super.dispose();
  }
}
