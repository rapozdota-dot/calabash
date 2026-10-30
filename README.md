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

The bundled model is `latest14_10.tflite` (trained October 14, 2026).
It uses channel-first input and prototypes. Its SHA-256 is
`03d8d2dfbc5c385b41056e7d14aac22d3bf489ebc5ce5c7d1ad1d58c12d0c9d3`.
Android and iOS bundle this same asset through `pubspec.yaml`; live camera,
capture, and gallery scans use the shared inference pipeline. Updating this
asset applies the model weights to both platforms without separate model copies.
The export still exposes only `Immature`, `Mature`, and `Overmature`, with no
separate `Non-calabash` class. Non-calabash rejection means that no calabash
detection survives the confidence and mask checks. Negative/background training
examples do not require another app label; the export metadata does not record
which training examples were used. Validate rejection on independent images and
both devices before claiming reliable non-calabash filtering.

Both live camera frames and capture/gallery images use the same `ModelService`, which
reads the tensor signature to choose the correct layout. Images are letterboxed
to 640x640 with fill 114, packed as RGB float32 / 255, and boxes are decoded
from normalized coordinates. Prototype output order is identified by shape.
The 39 detection channels remain 4 box values, 3 class scores, and 32 mask
coefficients. Class-aware NMS removes duplicate predictions within the same
stage. Near-identical boxes of different stages are also suppressed above
0.85 IoU; other different-stage overlaps can remain. Only nonempty
final masks are counted.
The photo and live confidence thresholds are both 0.45; these
conservative settings can miss small or difficult fruits and should be checked
on independent phone images. Mask support requires at least four prototype
pixels and 10% of the candidate crop, followed by validation after smoothing.

Direct TFLite smoke testing produced fruit predictions at up to 97.7% confidence
on the supplied field photo that the previous two models missed. Sampled
Immature, Mature, and Overmature validation images also produced predictions;
a blank image and a cucumber sample had no candidates above the 0.45 threshold.
These checks confirm basic model behavior, not overall accuracy. More field
photos and on-device validation are still required before the final defense.

For inspecting a candidate model outside Flutter, `tool/diagnose_model.py`
reports actual tensor values, class scores, and image normalization. It needs
Python with `ai-edge-litert`, `numpy`, and `Pillow` installed:

```text
python tool/diagnose_model.py --model assets/model/model.tflite --image path/to/photo.jpg
```

## Run Locally

### Shared UI presentation

The existing Nunito Sans family and green/cream palette are retained. `AppTheme`
owns typography and component themes; `UiTokens` contains presentation dimensions
separately from inference and camera constants. The shared information button,
responsive label row, and scrollable information dialog are used by Home,
results, and live prediction help. See [DESIGN.md](DESIGN.md) for their mapping
and the screen hierarchy.

The displayed model confidence is the selected maturity-class score from the
detection model, rounded to a whole percentage for display. It is not measured
accuracy, a calibrated probability, or a margin of error. Live tracking retains
the score associated with its stabilized stage. No separate maturity classifier
is integrated.

### Start the app

The home screen has two direct actions: **Scan Calabash** opens the live camera
with its capture button, and **Choose from Gallery** opens the image picker and
then the result. There is no intermediate scan-options page. Cancelling the
picker keeps the current screen/result intact; repeated scans are blocked while
picking or analyzing. Result images share Flutter's image cache for dimensions
and rendering, so changing overlays does not decode the image again.

```bash
flutter pub get
flutter run -d <android-device-id> --dart-define=CALABASH_PERF=true
```

Pass the recording define on research runs so debug configuration is explicit
and reproducible. Without it, recording remains disabled.

## Live Camera Performance

Camera and AI worker startup run concurrently. Camera readiness does not clear
a worker failure; the message remains until worker initialization succeeds.
Returning to Live Capture retries a failed worker without reopening a healthy
camera stream. Native camera errors enter the existing error screen and release
the failed session; **Try Again** waits for cleanup before creating a new one.
Late capture callbacks cannot release or pause a replacement camera session.
Regression tests cover these paths with iOS and Android platform fakes; native
device testing is still required.

Android uses three-plane YUV420 with sensor rotation. iOS uses BGRA8888 with
four-byte pixels, retaining AVFoundation's already-oriented image buffers.
Both paths use the same converter, respecting row padding and plane strides.

Live results allow up to three seconds of processing, but reject camera frames
that waited over 250 ms before inference. Overlay expiry adapts to the measured
processing time (2 to 3.5 seconds), avoiding starvation on slower phones while
still removing missing detections immediately. Capture/gallery thresholds and
the 640x640 model are unchanged. Live uses the same base confidence threshold,
requires two observations, and presents weaker matches as tentative labels.

Channel-first mask prototypes are consumed directly without transposing the full
tensor on each frame. Backend selection loads the first compatible backend without
synthetic startup benchmarks. Device FPS must be measured on
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

## Cross-platform research performance CSV recording

Performance starts automatically during inference when the build has
`CALABASH_PERF=true`; there is no start/stop control. Always pass that define on
Android research runs and release builds. The manual iOS research workflow
enables it by default and writes the selected value to
`Calabash-source-info.txt` in the downloaded artifact. `CALABASH_PERF=false`
remains available for intentionally unrecorded builds.
The `PerformanceProbe` flag/timer approach from
`codex/app-performance-measurements` is adapted here for persistent CSV;
the existing `ModelPipelineTimings` and live conversion timers are reused.
No detector thresholds, model weights, or frame scheduling are changed. The
Home screen adds an export action. With the flag disabled, no performance files or additional
acquisition/queue timers are created. This measures **YOLOv8n-seg only**;
MobileNetV3 is not an implemented stage.

Home shows the enabled/disabled recording state and this launch's total and
Live/Capture/Gallery measurement counts. If the recorder has not saved any
measurement rows, export stops before creating a ZIP and reports: “No
performance data recorded yet. Run Live Detection, Capture, or Gallery
detection, then export again.” CSV headers and summary rows do not count as
measurements. Storage failures are shown with a user-facing error; source CSVs
remain intact after successful or repeated exports.

### Measurement boundaries

All new elapsed durations use `Stopwatch`; UTC wall-clock timestamps only label
samples. Durations are stored in milliseconds with microsecond resolution.

| CSV measurement | Boundary |
| --- | --- |
| Live `complete_processing_ms` | Dart camera callback receipt through prepared detection/tracking state, before listener notification/rendering. Includes pending-frame waiting. This is not sensor exposure-to-display latency. |
| Live `queue_ms` | Receipt through entry into `_processFrame()`. Includes the existing busy/cadence wait. |
| Live `frame_transfer_ms` | Monotonic stopwatch started before plane packaging, sampled on worker receipt before materialization/conversion. Includes packaging and message delivery; excludes queue waiting and return transport. Blank when unmeasured. |
| Live `processing_ms` | Complete elapsed time minus measured queue time. |
| Live `preprocess_ms` | Existing RGB conversion + orientation + model letterbox/tensor-fill durations. Materialization/transport overhead remains in complete processing. |
| Gallery/Capture `complete_processing_ms` / `processing_ms` | Selected/captured file available through prepared detections and harvest recommendation. Includes worker startup, file read/decode, per-photo model loading, inference, postprocessing, disposal and return transport. Excludes picker interaction, camera shutter/file creation and result-screen rendering. |
| `file_read_ms` | Worker file read start through bytes available. |
| `decode_ms` | Image decoding start through EXIF orientation baked into pixels. |
| Gallery `model_initialization_ms` | Photo worker `loadModel()` start through interpreter/signature validation completed. The current photo path creates an interpreter for every photo. |
| Gallery `preprocess_ms` | Existing letterbox resize and normalized tensor preparation. |
| `model_preprocess_ms` | Model letterbox resize and normalized RGB tensor preparation only, for all three methods. Excludes live camera conversion/orientation. |
| `yolo_inference_ms` | Legacy `_runInference()` aggregate: input tensor assignment + `Interpreter.invoke()` + output tensor bulk copies. Preserved for comparison with earlier CSVs. Excludes decoding, initialization, preprocessing and segmentation postprocessing. |
| `input_tensor_ms` / `output_tensor_ms` | Sequential input tensor assignment and output tensor access/copy portions of the legacy aggregate. |
| `interpreter_invoke_ms` | Elapsed `Interpreter.invoke()` call only, using snapshots on the same monotonic stopwatch as tensor handling. Includes native runtime/delegate execution overhead; it is not hardware kernel profiling. |
| `postprocess_ms` | Candidate parsing through NMS, mask reconstruction/filtering and final detection objects. |
| `result_preparation_ms` | Live tracking/state preparation or gallery counts/recommendation preparation. |
| `processed_fps` | Reciprocal elapsed interval between completed live results. First completion and first completion after a pause have no FPS sample. Summary throughput is interval sample count divided by summed interval seconds; it is not camera sensor FPS. |

CSV schema 2 appends columns; earlier column order and definitions remain intact.
`input_tensor_ms + interpreter_invoke_ms + output_tensor_ms = yolo_inference_ms`
before millisecond display rounding. Do not add these parts to their aggregate.
For Live, `preprocess_ms` already includes `conversion_ms + orientation_ms +
model_preprocess_ms`; these are nested component fields. Complete processing is
measured independently, never reconstructed by summing overlapping fields.

The first completed live frame after each worker initialization and the first
successful Gallery/Capture image of each app session are marked `warm_up=true`.
They remain in raw data but are excluded from averages. Startup performs no
neutral-image benchmarks, and no extra inference or
automatically repeated gallery scan is introduced. Later gallery images still
include their own interpreter initialization; they are not persistent-worker
warm runs.

`Capture` labels shutter photos separately from continuous `Live` frames and
`Gallery` images. Empty/no-fruit results count as successful processing, not as
accuracy evidence. Picker cancellation produces no processing sample.

### Files, fields and calculations

Files are written asynchronously in approximately one-second batches after
the producing sample's processing stopwatch has stopped. Detection never waits
for CSV writes. Background/inactive lifecycle events request a flush, including
late results returned while backgrounded. Recording overhead still requires
physical-device evaluation; no zero-overhead claim is made.

Storage is the app's Documents directory under `calabash_performance/`:

```text
calabash_performance_<UTC-date>_<session-id>_raw.csv
calabash_performance_<UTC-date>_<session-id>_summary.csv
```

Each launch has a new timestamp/random session ID. Existing session files are
retained across normal restarts. Raw rows append; the paired summary is refreshed
from successfully written rows. Use **Export Performance Data** on Home to flush
the recorder and share a ZIP containing the raw CSV, refreshed summary CSV, and
`session_metadata.json`. Each export gets a unique timestamped filename;
exporting again never appends duplicate rows or deletes source CSVs. ZIP creation
runs off the UI isolate. Abrupt termination can lose a not-yet-flushed batch;
lifecycle flush requests do not guarantee persistence after a force-quit or
crash. Raw data is authoritative if a summary is out of date.

Raw fields include session/measurement IDs, UTC time, platform/available OS and
processor information, source revision, build number, model SHA-256, scan method,
runtime/threshold configuration, outcome, image dimensions, frame/detection
counts, all timing columns above, FPS interval, warm-up status, separate
processing/inference inclusion flags, exclusion reason and successful-run count.
Unavailable values are blank, never estimated. An optional
`CALABASH_PERF_DEVICE` define supplies a manually identified device label;
hardware model/RAM are not automatically detected or hardcoded.
The workflow's optional `device_label` input supplies this define (for example,
`iPhone 12, 4 GB RAM`); confirm the label against the actual test device.

The summary contains separate Live, Gallery and Capture rows: successful,
valid/excluded/warm-up/error/stale/invalidated counts; complete-processing
mean/minimum/maximum; processing mean excluding queue time; inference mean;
sampled inference P50/P90/P95; processed throughput; separate
processing/inference percentages within 3,000 ms; and the average-inference
requirement verdict. The threshold is inclusive. Percentiles use a uniform
reservoir sample capped at 4,096 valid inference timings per method, keeping
summary memory bounded during long live sessions. They are exact when a method
has at most 4,096 valid timings; for longer sessions, use raw rows for exact
offline percentile calculations.
The verdict is `NOT_ENOUGH_DATA` until 30 valid **inference** samples exist.
Schema 2 additionally reports invocation-only valid count, mean/minimum/maximum,
percentage within 3,000 ms and a separately named `interpreter_invoke_requirement`.
The older inference statistics/verdict retain their aggregate boundary. Missing
invocation metrics remain blank and do not count as zero-duration executions.
Collect at least 30 valid prepared-result samples per requested method as well;
warm-ups do not count toward that target. There is no 30-sample upper limit.

Full processing averages include only successful prepared results with valid
timings. Inference averages additionally include completed model runs whose
result is `stale` or `invalidated`, preventing freshness policy from censoring
slow executions. Failed/missing/invalid timings and warm-ups are excluded.
Always report outcome counts beside averages; a good model-only mean does not
establish responsive complete application processing.

CSV strings are quoted/escaped and numeric units are milliseconds. A schematic
raw row is `<session>,<measurement>,<UTC-time>,...,<actual elapsed values>,...`;
no example numbers in tests or documentation are actual research results.
If storage is unavailable, recording errors are logged without failing
detection. The retry buffer is bounded; overflow is counted as
`dropped_recordings` and prevents a normal research verdict.

### Build and install through Windows/AltStore

1. Review, commit and push these changes on the branch intended for measurement.
   `ios-11` used the earlier Calabash v4 export; the current bundled v5 model's
   SHA-256 is `9408010cf54792cfefdb6af926e4249abd94a0e9f2c15d72549d58ac16539d86`.
   Keep prior measurements identified by their original build/model checksum.
2. On GitHub, open **Actions → Build Calabash iOS IPA → Run workflow**.
3. Select that pushed branch, leave **performance_recording=true** (the default),
   enter the **device_label**, and leave **publish_release=false** for a testing
   artifact. The workflow builds a release IPA with `CALABASH_PERF=true`, records
   the same configuration in `Calabash-source-info.txt`, embeds source/build/model
   identifiers in CSV metadata, and preserves unsigned IPA packaging for AltStore
   signing.
   If the web form has not picked up the new input, use an authenticated GitHub
   CLI to dispatch the updated branch explicitly:

   ```bash
   gh workflow run build-ios.yml --ref <pushed-branch> -f performance_recording=true -f publish_release=false -f device_label="iPhone 12, 4 GB RAM"
   ```

4. Wait for analysis, tests, native iOS simulator model smoke, the macOS build,
   and IPA validation to succeed. Download
   `Calabash-unsigned.ipa` and `Calabash-source-info.txt` from that exact run or
   its `ios-<run-number>` release only when publication was explicitly enabled.
   The IPA artifact also includes model metadata, native smoke log and IPA validation JSON.
   The separate `calabash-ios-model-smoke-<run-number>` artifact preserves the
   simulator smoke log even when that step fails and IPA packaging is skipped.
   Check commit, build number, model checksum and
   `Performance recording: true` in the source-info file.
5. Before updating, background the existing app, allow its pending CSV batch to
   flush, and copy the entire `calabash_performance` folder out of its Documents
   storage. Retain the original raw/summary files and build provenance separately.
   Keep the same bundle identifier/signing identity and update the existing app;
   deleting/reinstalling or changing app identity can lose its data container.
   Keep AltServer running on Windows and connect the existing trusted iPhone
   through USB or the supported same-network setup. Transfer the IPA to iPhone
   Files, then import it using AltStore Classic's **My Apps → +** file picker.
   Alternatively, Windows AltServer exposes **Sideload .ipa…** by holding Shift
   while clicking its tray icon. AltStore/AltServer handles signing; this
   workflow's unsigned IPA is not directly installable by itself.
6. Open the installed build and use Live Detection, Capture, and Gallery as usual.
   Recording starts automatically. Choose **Export Performance Data** on Home
   when collection is complete, then save/share the ZIP from the iOS share sheet.

Official installation/connection guidance:
[AltServer](https://faq.altstore.io/altstore-classic/altserver) and
[AltServer sideload menu](https://faq.altstore.io/release-notes/altserver).

The equivalent build command on a machine with macOS/Xcode is:

```bash
flutter build ios --release --no-codesign --build-number=<build-number> \
  --dart-define=CALABASH_PERF=true \
  --dart-define=CALABASH_SOURCE_REVISION=<actual-commit-sha> \
  --dart-define=CALABASH_BUILD_NUMBER=<build-number> \
  --dart-define="CALABASH_PERF_DEVICE=iPhone 12, 4 GB RAM" \
  --dart-define=CALABASH_MODEL_SHA256=<actual-model-sha256>
```

For a physical Android debug run, explicitly enable recording:

```bash
flutter run --debug --dart-define=CALABASH_PERF=true
```

Windows development uses the GitHub macOS workflow instead of a local iOS build.

### Export and physical-device acceptance

The export action flushes pending rows before creating the ZIP. The ZIP remains
in the app Documents folder under `calabash_performance/exports/` and opens the
native share sheet. On iOS, it can also be found in **Files → Browse → On My
iPhone → Calabash Maturity Detection → calabash_performance → exports**;
`UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` expose Documents.
On Android, the original CSVs and ZIP are in app-private Documents storage; use
the Android share sheet to save/send the ZIP to a user-selected destination.
Exports leave the original raw and summary files intact.

On the physical iPhone, verify the folder is visible, values are recorded by
the release build, counts reach 30 valid samples per method, prior session files
survive a normal restart, camera/gallery/shutter still work, and recording has
acceptable overhead. Compare CSV source/model identifiers to the downloaded
artifact. Local automated tests validate synthetic calculations, CSV structure,
persistence and provider control flow; they do not establish measured iPhone
performance or satisfaction of the 3,000 ms requirement.

Validation commands:

```bash
flutter analyze
flutter test
flutter test --dart-define=CALABASH_PERF=false test/performance_probe_test.dart
flutter test --dart-define=CALABASH_PERF=true test/performance_probe_test.dart
python -m unittest discover -s tool -p test_validate_ios_release.py
python -m unittest tool.test_performance_recording_workflow
python tool/validate_ios_release.py model assets/model/model.tflite
# macOS with a booted iPhone simulator; uses the actual iOS TFLite pod:
flutter test integration_test/model_runtime_smoke_test.dart -d <simulator-udid>
```

The CI smoke test emits timestamped stage logs and validates float32 tensor
signatures, finite native outputs, confidence channels, non-square photo
preprocessing/decoding, output parsing, and the live isolate/BGRA/backend path.
Metadata validation checks class order.
Returned masks/classes are checked when the synthetic inputs produce detections;
deterministic postprocessor tests cover mask reconstruction separately. Synthetic
inputs do not prove fruit-recognition accuracy, real-camera behavior, iPhone 12
performance, or iOS 26.7.1 compatibility. A native smoke failure stops the job
before release build/IPA packaging; a queued CI configuration is not a passed run.
The test case has a five-minute timeout; the pinned `test_api` runner also has a
separate 12-minute suite-loading watchdog, while the GitHub Actions smoke step is
capped at 20 minutes. Async stages have their own limits. A synchronous native
`Interpreter.invoke()` cannot be interrupted by a Dart future timeout; its
stage-start log and the workflow cap bound diagnosis at the runner level.

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

## Branding Assets

Approved branding source files live in:

```text
assets/branding/app_icon_master.png
assets/branding/BG.png
assets/branding/splash_screen.png
assets/branding/splash_foreground.png
```

Launcher icons and native splash resources are generated with the existing free
tooling:

```bash
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

The Android adaptive icon uses a derived transparent safe-zone foreground. The
native launch screens use a solid Calabash green background so the Flutter
startup screen is the single visible branded splash design. The Flutter startup
screen uses `BG.png` as the immediate background, fades in the derived
`splash_foreground.png` fruit and scanning layer, fades in the approved
typography, then crossfades to Home. The full startup targets about two seconds
when model initialization is ready and remains on the completed splash while the
existing model initialization is still running.

## Build Unsigned IPA

iOS builds require macOS and Xcode. From a Windows development machine, use the
GitHub Actions workflow instead of a local iOS build:

```text
.github/workflows/build-ios.yml
```

Automatic iOS builds are disabled. Only start this workflow manually with
`workflow_dispatch` when an iOS build is explicitly requested. It pins Flutter
`3.38.7`, runs analysis and tests, installs CocoaPods dependencies during the
iOS build, and runs `flutter build ios --release --no-codesign`. It packages
`Payload/Runner.app` into `dist/Calabash-unsigned.ipa` and uploads that IPA as a
workflow artifact. A named iOS GitHub Release is created only when
`publish_release=true`. Each build uses its workflow run number as the app build number.

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
downloadable APK artifact, and publishes a named GitHub Release on pushes to
`main` or `master`. Manual runs can disable publication with `publish_release=false`.

The iOS unsigned IPA workflow is manual-only and does not run on pushes:

```text
.github/workflows/build-ios.yml
```

The iOS workflow analyzes the project, runs tests, builds an unsigned iOS app,
packages it as `Calabash-unsigned.ipa`, and uploads the IPA as a downloadable
artifact. Publication as a public iOS release asset requires the explicit
`publish_release` input; its default is false. iOS releases do not replace the latest
Android release. The IPA still requires signing before installation.
