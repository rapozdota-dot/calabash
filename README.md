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

- input: `[1, 3, 640, 640]` or `[1, 640, 640, 3] float32`
- output 0: `[1, 39, 8400] float32`
- mask prototypes: `[1, 32, 160, 160]` or `[1, 160, 160, 32] float32`

The current `best.tflite` uses channel-first input and prototypes. Both live
camera frames and capture/gallery images use the same `ModelService`, which
reads the tensor signature to choose the correct layout. Images are letterboxed
to 640x640 with fill 114, packed as RGB float32 / 255, and boxes are decoded
from normalized coordinates. Prototype output order is identified by shape.
The 39 detection channels remain 4 box values, 3 class scores, and 32 mask
coefficients. Class-agnostic NMS removes conflicting maturity predictions on
strongly overlapping boxes, and only nonempty final masks are counted.
The photo confidence threshold is 0.45 and the live threshold is 0.50; these
conservative settings can miss small or difficult fruits and should be checked
on independent phone images. Mask support requires at least four prototype
pixels and 1% of the candidate crop, followed by validation after smoothing.

## Run Locally

```bash
flutter pub get
flutter run
```

## Live Camera Performance

Live results allow up to three seconds of processing, but reject camera frames
that waited over 250 ms before inference. Overlay expiry adapts to the measured
processing time (2 to 3.5 seconds), avoiding starvation on slower phones while
still removing missing detections immediately. Capture/gallery thresholds and
the 640x640 model are unchanged. Live uses the same base confidence threshold,
requires two observations, and presents weaker matches as tentative labels.

Channel-first mask prototypes are consumed directly without copying the full
tensor on each frame. Backend selection retains a warm-up and uses one timed
run per backend to reduce initial setup work. Device FPS must be measured on
hardware; these changes do not imply a particular frame rate.

The camera supports tap-to-focus/exposure where available. The home and scan
pages scroll for small screens and larger text, and page transitions respect
the device's reduced-motion preference.

Live capture uses the back camera with `ResolutionPreset.medium`, YUV420 image
stream frames, and the existing 640x640 YOLOv8 segmentation model.

The preview requests 30 FPS (subject to camera support), while AI inference is
limited to at most 10 starts per second and remains latest-frame-only. Mask
dot products run only within candidate boxes and are skipped on empty frames.
Live candidates require two observations before display. Stage changes need
three consecutive strong observations; missing detections disappear immediately.
These changes reduce post-processing and flicker, but device profiling is still
needed to establish achieved preview FPS, AI FPS, and thermal behavior.

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
