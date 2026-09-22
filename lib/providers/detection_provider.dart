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
  bool _didInitialize = false;

  String? _errorMessage;
  String _recommendation = 'Run a scan to get a harvest recommendation.';

  File? _selectedImage;
  List<Detection> _detections = [];

  bool get isInitializing => _isInitializing;
  bool get isAnalyzing => _isAnalyzing;
  bool get isBusy => _isInitializing || _isAnalyzing;

  String? get errorMessage => _errorMessage;
  String get recommendation => _recommendation;

  ModelService get modelService => _modelService;

  File? get selectedImage => _selectedImage;
  List<Detection> get detections => _detections;

  int get totalDetected => _detections.length;
  int get matureCount =>
      _detections.where((d) => d.maturityClass == MaturityClass.mature).length;
  int get immatureCount => _detections
      .where((d) => d.maturityClass == MaturityClass.immature)
      .length;
  int get overmatureCount => _detections
      .where((d) => d.maturityClass == MaturityClass.overmature)
      .length;

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

  Future<bool> scanFromSource(ImageSource source) async {
    _errorMessage = null;
    notifyListeners();

    final pickedImage = await _imageService.pickImage(source: source);
    if (pickedImage == null) {
      _errorMessage = 'No image selected.';
      notifyListeners();
      return false;
    }

    _selectedImage = pickedImage;
    notifyListeners();

    return analyzeSelectedImage();
  }

  Future<bool> analyzeSelectedImage() async {
    if (_selectedImage == null) {
      _errorMessage = 'Please capture or choose an image first.';
      notifyListeners();
      return false;
    }

    _isAnalyzing = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _detections = await _modelService.detectFruits(_selectedImage!);
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

  void clearCurrentResult() {
    _selectedImage = null;
    _detections = [];
    _recommendation = 'Run a scan to get a harvest recommendation.';
    _errorMessage = null;
    notifyListeners();
  }

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

  @override
  void dispose() {
    _modelService.dispose();
    super.dispose();
  }
}
