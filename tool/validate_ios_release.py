"""Dependency-free metadata/IPA guards. Native inference is a separate CI gate."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import zipfile


SUPPORTED_MODEL_ARCHITECTURES = (
    'MobileNetV3Small_YOLOv8Seg_Architecture',
    'YOLOv8n-seg',
)


def validate_model(path):
    data = Path(path).read_bytes()
    if data[4:8] != b'TFL3':
        raise ValueError('Expected a TFLite model (TFL3 identifier).')
    with zipfile.ZipFile(path) as archive:
        metadata = json.loads(archive.read('metadata.json'))
    expected = {'task': 'segment', 'head': 'Segment', 'batch': 1, 'channels': 3,
                'imgsz': [640, 640],
                'names': {'0': 'Immature', '1': 'Mature', '2': 'Overmature'}}
    description = metadata.get('description', '')
    if not isinstance(description, str) or not any(
            architecture in description for architecture in SUPPORTED_MODEL_ARCHITECTURES):
        raise ValueError('Unexpected model architecture metadata.')
    for field, value in expected.items():
        if metadata.get(field) != value:
            raise ValueError(f'Model metadata {field}: expected {value!r}, got {metadata.get(field)!r}')
    return {'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data),
            'metadata': metadata}


def validate_ipa(path, bundle_id, build_number, model_sha256):
    prefix = 'Payload/Runner.app/'
    with zipfile.ZipFile(path) as archive:
        bad_entry = archive.testzip()
        if bad_entry:
            raise ValueError(f'IPA CRC failure: {bad_entry}')
        names = set(archive.namelist())
        apps = {name.split('/')[1] for name in names
                if name.startswith('Payload/') and len(name.split('/')) > 2
                and name.split('/')[1].endswith('.app')}
        if apps != {'Runner.app'} or prefix + 'Info.plist' not in names:
            raise ValueError('IPA must contain exactly Payload/Runner.app with Info.plist.')
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        if info.get('CFBundleIdentifier') != bundle_id:
            raise ValueError(f'Bundle identifier mismatch: {info.get("CFBundleIdentifier")!r}')
        if str(info.get('CFBundleVersion')) != str(build_number):
            raise ValueError(f'Build number mismatch: {info.get("CFBundleVersion")!r}')
        executable = info.get('CFBundleExecutable', '')
        if not executable or '/' in executable or prefix + executable not in names:
            raise ValueError('Runner executable is missing or invalid.')
        model_path = prefix + 'Frameworks/App.framework/flutter_assets/assets/model/model.tflite'
        if model_path not in names:
            raise ValueError('Bundled Flutter model asset is missing from IPA.')
        actual_sha = hashlib.sha256(archive.read(model_path)).hexdigest()
        if actual_sha != model_sha256:
            raise ValueError(f'Packaged model checksum mismatch: {actual_sha}')
    return {'bundle_identifier': bundle_id, 'build_number': str(build_number),
            'model_sha256': actual_sha, 'ipa_sha256': hashlib.sha256(Path(path).read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    model = commands.add_parser('model')
    model.add_argument('path', type=Path)
    ipa = commands.add_parser('ipa')
    ipa.add_argument('path', type=Path)
    ipa.add_argument('--bundle-id', required=True)
    ipa.add_argument('--build-number', required=True)
    ipa.add_argument('--model-sha256', required=True)
    args = parser.parse_args()
    result = validate_model(args.path) if args.command == 'model' else validate_ipa(
        args.path, args.bundle_id, args.build_number, args.model_sha256)
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
