import 'dart:io';

import 'package:calabash_maturity_detection/models/detection.dart';
import 'package:calabash_maturity_detection/services/image_service.dart';
import 'package:calabash_maturity_detection/services/model_service.dart';
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

  String? _errorMessage;
  String _recommendation = 'Run a scan to get a harvest recommendation.';

  File? _selectedImage;
  List<Detection> _detections = [];

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
    if (_didInitialize) {
      return;
    }

    _didInitialize = true;
    _isInitializing = true;
    notifyListeners();

    try {
      await _modelService.loadModel();
    } catch (error) {
      _errorMessage = 'Model could not be loaded: $error';
    }

    _isInitializing = false;
    notifyListeners();
  }

  /// Opens the camera/gallery picker and analyzes the chosen file.
  /// Duplicate requests are blocked; cancellation preserves the previous result.
  Future<bool> scanFromSource(ImageSource source) async {
    if (isBusy) return false;
    _errorMessage = null;
    _isPickingImage = true;
    notifyListeners();

    File? pickedImage;
    try {
      pickedImage = await _imageService.pickImage(source: source);
    } catch (error) {
      _errorMessage = 'Unable to open the image picker. Please try again.';
      debugPrint('Image selection failed: $error');
    }
    _isPickingImage = false;
    if (pickedImage == null) {
      // Cancellation is a normal action; keep any existing result intact.
      notifyListeners();
      return false;
    }

    return scanFile(pickedImage);
  }

  /// Selects a captured or picked photo, clears old detections, and starts analysis.
  Future<bool> scanFile(File imageFile) async {
    if (isBusy) return false;

    _selectedImage = imageFile;
    _detections = [];
    return analyzeSelectedImage();
  }

  /// Runs the photo pipeline, updates detections and guidance, and reports errors.
  /// The finally block always clears the busy state and refreshes listeners.
  Future<bool> analyzeSelectedImage() async {
    if (isBusy) return false;
    if (_selectedImage == null) {
      _errorMessage = 'Please capture or choose an image first.';
      notifyListeners();
      return false;
    }

    _isAnalyzing = true;
    final image = _selectedImage!;
    _errorMessage = null;
    notifyListeners();

    try {
      _detections = await _modelService.detectFruits(image);
      // Recommendation logic is intentionally simple and explainable for field use.
      _recommendation = _buildRecommendation(
        mature: matureCount,
        immature: immatureCount,
        overmature: overmatureCount,
      );
      return true;
    } catch (error) {
      _errorMessage = 'Detection failed: $error';
      return false;
    } finally {
      _isAnalyzing = false;
      notifyListeners();
    }
  }

  /// Clears the selected photo, detections, errors, and guidance for a new scan.
  void clearCurrentResult() {
    _selectedImage = null;
    _detections = [];
    _recommendation = 'Run a scan to get a harvest recommendation.';
    _errorMessage = null;
    notifyListeners();
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
    _modelService.dispose();
    super.dispose();
  }
}
