"""Structural release-guard tests; fixtures are not runtime model evidence."""
import hashlib
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

from validate_ios_release import validate_ipa, validate_model


class ReleaseValidationTest(unittest.TestCase):
    EXPECTED_METADATA = {
        'task': 'segment', 'head': 'Segment', 'batch': 1,
        'channels': 3, 'imgsz': [640, 640],
        'names': {'0': 'Immature', '1': 'Mature', '2': 'Overmature'},
    }

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.model = Path(self.temp.name) / 'model.tflite'
        self.write_model_description('Ultralytics YOLOv8n-seg fixture')
        self.model_sha = hashlib.sha256(self.model.read_bytes()).hexdigest()

    def write_model_description(self, description):
        self.model.write_bytes(b'\x08\x00\x00\x00TFL3')
        with zipfile.ZipFile(self.model, 'a') as archive:
            archive.writestr('metadata.json', json.dumps({
                'description': description,
                **self.EXPECTED_METADATA,
            }))

    def package(self, bundle='com.example.calabashMaturityDetection', build='42',
                model=None, executable=True):
        ipa = Path(self.temp.name) / 'fixture.ipa'
        prefix = 'Payload/Runner.app/'
        with zipfile.ZipFile(ipa, 'w') as archive:
            archive.writestr(prefix + 'Info.plist', plistlib.dumps({
                'CFBundleIdentifier': bundle, 'CFBundleVersion': build,
                'CFBundleExecutable': 'Runner',
            }))
            if executable:
                archive.writestr(prefix + 'Runner', b'fixture executable')
            archive.writestr(prefix + 'Frameworks/App.framework/flutter_assets/'
                             'assets/model/model.tflite',
                             self.model.read_bytes() if model is None else model)
        return ipa

    def check(self, ipa):
        return validate_ipa(ipa, 'com.example.calabashMaturityDetection', '42', self.model_sha)

    def test_model_metadata_class_order_and_hash(self):
        self.assertEqual(validate_model(self.model)['sha256'], self.model_sha)
        with zipfile.ZipFile(self.model, 'w') as archive:
            archive.writestr('metadata.json', '{}')
        with self.assertRaises(ValueError):
            validate_model(self.model)

    def test_current_mobilenet_yolov8seg_architecture_is_supported(self):
        self.write_model_description(
            'Ultralytics MobileNetV3Small_YOLOv8Seg_Architecture model fixture')
        self.assertEqual(validate_model(self.model)['metadata']['description'],
                         'Ultralytics MobileNetV3Small_YOLOv8Seg_Architecture model fixture')

    def test_unsupported_model_architecture_is_rejected(self):
        self.write_model_description('Ultralytics MobileNetV3 classification model fixture')
        with self.assertRaisesRegex(ValueError, 'Unexpected model architecture metadata'):
            validate_model(self.model)

    def test_valid_package(self):
        self.assertEqual(self.check(self.package())['bundle_identifier'],
                         'com.example.calabashMaturityDetection')

    def test_wrong_identity_or_build_blocks_package(self):
        for fields in [{'bundle': 'different.app'}, {'build': '41'}]:
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                self.check(self.package(**fields))

    def test_missing_executable_or_wrong_model_blocks_package(self):
        for fields in [{'executable': False}, {'model': b'wrong model'}]:
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                self.check(self.package(**fields))

    def test_wrong_class_order_is_rejected(self):
        # Valid TFLite header alone cannot establish the application's label map.
        self.model.write_bytes(b'\x08\x00\x00\x00TFL3')
        with zipfile.ZipFile(self.model, 'a') as archive:
            archive.writestr('metadata.json', json.dumps({
                'description': 'YOLOv8n-seg', 'task': 'segment', 'head': 'Segment',
                'batch': 1, 'channels': 3, 'imgsz': [640, 640],
                'names': {'0': 'Mature', '1': 'Immature', '2': 'Overmature'},
            }))
        with self.assertRaises(ValueError):
            validate_model(self.model)


if __name__ == '__main__':
    unittest.main()
