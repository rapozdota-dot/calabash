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

## Live Camera Performance

Live capture uses the back camera with `ResolutionPreset.medium`, YUV420 image
stream frames, and the existing 640x640 YOLOv8 segmentation model.

The live AI scheduler is latest-frame-only:

- YOLO starts immediately when no AI frame is running.
- While YOLO is busy, the app keeps a single pending camera frame.
- Newer pending frames replace older pending frames.
- No FIFO frame queue is built.
- Overlay results update when inference completes.

The previous fixed 1500 ms live inference delay has been removed. Camera FPS is
still configured separately from the YOLO pipeline and remains a later adaptive
camera configuration task.

Debug builds print an aggregated `LIVE PERF` report about once per second with
camera FPS, AI FPS, frame counts, replacement/drop counts, pending frame count,
conversion, preprocessing, TFLite inference, post-processing, mask, total AI,
and result-age timings.

## Build APK

```bash
flutter build apk --release
```

The APK is generated at:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## Windows 8 GB Android Build Profile

This project keeps Android Gradle builds conservative for low-memory Windows
development machines:

- Gradle heap is capped at 1024 MB.
- Kotlin daemon heap is capped at 512 MB.
- Gradle workers are limited to 2.
- Parallel project execution is disabled.
- Gradle daemon reuse is enabled, with a 10-minute idle timeout.
- Build cache and virtual file-system watching remain enabled.
- Kotlin incremental compilation is disabled because Pub-cache plugin sources on
  `C:` and this project on `G:` cause Kotlin incremental cache path failures.

Useful maintenance commands:

```powershell
cd android
.\gradlew.bat --status
.\gradlew.bat --stop
cd ..
flutter clean
flutter pub get
```

Use `.\gradlew.bat --stop` when Gradle daemons look stale or memory remains
high after builds. Avoid deleting the global Gradle cache unless there is clear
evidence that the cache is corrupted.

## GitHub APK Releases

Every push to `main` or `master` runs the Android release workflow:

```text
.github/workflows/android-release.yml
```

The workflow analyzes the project, runs tests, builds the APK, and publishes a GitHub Release with the APK attached.
