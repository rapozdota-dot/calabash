# Calabash Maturity Detection

Calabash Maturity Detection is an offline Flutter app for identifying calabash fruit maturity with a TensorFlow Lite YOLOv8 segmentation model.

The app classifies detected calabash fruits as:

- Immature
- Mature
- Overmature

## Core Stack

- Flutter
- `tflite_flutter`
- `image_picker`
- `provider`

## Model File

The bundled model lives at:

```text
assets/model/model.tflite
```

The app expects a YOLOv8 segmentation TFLite model with:

- input: `[1, 640, 640, 3] float32`
- output 0: `[1, 39, 8400] float32`
- output 1: `[1, 160, 160, 32] float32`

## Run Locally

```bash
flutter pub get
flutter run
```

## Build APK

```bash
flutter build apk --release
```

The APK is generated at:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## GitHub APK Releases

Every push to `main` or `master` runs the Android release workflow:

```text
.github/workflows/android-release.yml
```

The workflow analyzes the project, runs tests, builds the APK, and publishes a GitHub Release with the APK attached.
