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

GitHub Actions pins Flutter `3.38.7` for reproducible APK builds. The Android
build keeps the `tflite_flutter` plugin's Kotlin bytecode target aligned with
that plugin module's existing Java 1.8 target; the app module remains configured
for Java/Kotlin 17.

The APK is generated at:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## Build Unsigned IPA

iOS builds require macOS and Xcode. From a Windows development machine, use the
GitHub Actions workflow instead of a local iOS build:

```text
.github/workflows/build-ios.yml
```

The workflow runs on the `feature/camera-shutter` branch and can also be started
manually with `workflow_dispatch`. It pins Flutter `3.38.7`, installs CocoaPods
dependencies, runs `flutter build ios --release --no-codesign`, packages
`Payload/Runner.app` into `build/ios/Calabash-unsigned.ipa`, and uploads that IPA
as a workflow artifact.

`Calabash-unsigned.ipa` is an unsigned artifact. It must be signed before it can
be installed on a physical iPhone.

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

## GitHub Build Workflows

Every push to `main` or `master` runs the Android release workflow:

```text
.github/workflows/android-release.yml
```

The Android workflow analyzes the project, runs tests, builds the APK, uploads a
downloadable APK artifact, and publishes a GitHub Release only when manually
started with `publish_release=true`.

Every push to `feature/camera-shutter` runs the iOS unsigned IPA workflow:

```text
.github/workflows/build-ios.yml
```

The iOS workflow analyzes the project, runs tests, builds an unsigned iOS app,
packages it as `Calabash-unsigned.ipa`, and uploads the IPA as a downloadable
artifact.
