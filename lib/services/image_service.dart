import 'dart:io';

import 'package:image_picker/image_picker.dart';

class ImageService {
  ImageService({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  Future<File?> pickImage({required ImageSource source}) async {
    final picked = await _picker.pickImage(
      source: source,
      imageQuality: 92,
      maxWidth: 1600,
    );

    if (picked == null) {
      return null;
    }

    return File(picked.path);
  }
}
