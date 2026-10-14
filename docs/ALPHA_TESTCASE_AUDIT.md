# Updated alpha checklist audit

Date: 14 October 2026 (Asia/Manila)

## Conclusion

The app is not certified as passing all 112 cases. Quick fixes were applied and all 80 automated tests pass (68 existing plus 12 new). These are software tests, not 80 passed checklist cases. No Android device was connected. The supplied Word form was left unchanged and no evaluator P/F results were invented.

Source: `C:/Users/Rapoz 2023/Downloads/CapstoneTestCase_updated-1.docx`.
Baseline code: `6d7b55b`; fixes are local working-tree changes. No GitHub release or iOS build was made by this audit.

## Fixes and evidence

- Pending analysis no longer publishes a result after clear/Back/disposal. Native work finishes in the background while busy remains guarded, preventing overlapping workers.
- Analysis errors have their own failure state, not "No calabash fruits detected". Old detections and harvest guidance are cleared for a new analysis.
- Successful results now offer Try Another Image as well as Capture Again. Cancelling the picker preserves the previous result.
- Returning from Android Settings now rechecks permission even when there was no camera controller.
- Labels are positioned using measured text dimensions, fixing narrow-image clamp exceptions and bottom-edge clipping. The guidance heading wraps at enlarged text sizes.
- Gallery/capture completion does not navigate over an unrelated current route.
- Theme font files and their OFL license are bundled. Runtime font fetching is disabled; the offline font-loading test passes.
- Model initialization can be retried after failure rather than permanently marking the failed initialization as complete.

Eight new regression checks were run before their corresponding fixes and failed: seven result/provider/layout checks and one Settings-recovery check. They pass after repair. Additional new checks cover font assets, nonempty picker cancellation, repeated image/count replacement, and actual result-route Back handling.

Validation: `flutter analyze` reports no issues; `flutter test --no-pub --reporter expanded` reports 80 passed; `git diff --check` is clean. New tests are in `test/alpha_regression_test.dart` and `test/live_camera_session_test.dart`.

## Model limitations

The bundled latest14_10 model is unchanged. SHA256: `2e377b3b81edc3398d9d3ebf41f77dd7ad46d60a321f27ddc499a51ba9e68547`.

Fresh desktop LiteRT checks used the three original 1536x2048 photos, float32 RGB/255, proportional 640x640 letterboxing, the model's NCHW input, confidence 0.45 and class-aware NMS IoU 0.60. Python/Pillow resizing approximates the app; this is not bit-exact Dart or on-device validation.

| Original photo prefix | NMS candidates retained | Large yellow fruit best region-matched score |
| --- | ---: | ---: |
| 7c37bf93 | 2 | 0.23% |
| 5127ea17 | 3 | 3.10% |
| 1fd8783a | 3 | 0.28% |
| Neutral synthetic blank | 0 | Not applicable |

The yellow-fruit regions are manual diagnostic estimates, not verified maturity annotations. Their scores are far below the 45% threshold before mask filtering. These are known counterexamples to complete fruit detection, not bugs that can safely be fixed by assigning higher confidence or globally lowering thresholds. Candidate counts are after desktop NMS, not an observed Android result. Model-dependent checks need labelled positive and negative examples, including all twelve look-alikes in cases 101-112.

Raw diagnostics: `build/alpha_audit/model/`; summary: `tmp/alpha_model_summary.jsonl`. The small yellow object is not assigned a ground-truth species or maturity by this audit.

## Case by case coverage

All **on-device evaluator statuses remain NT** in this audit. "Automated support" below means only the stated component behavior was verified, not that the complete external test passed. Cases with known model limitations must not be counted as passing. No 93-94% checklist pass rate can be calculated without executing and recording the actual cases.

| Case | Test area | Evidence or finding | Remaining verification |
| --- | --- | --- | --- |
| 001 | App identity | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 002 | Splash screen | Splash timing and nine size/text-scale combinations pass. | Cold launch on the evaluation phone. |
| 003 | Home screen layout | Home navigation/layout tests pass; TC08 regression fixes result guidance overflow at 1.8x text. | Inspect installed build at the actual Android font size. |
| 004 | Scan action label | Home navigation/layout tests pass; TC08 regression fixes result guidance overflow at 1.8x text. | Inspect installed build at the actual Android font size. |
| 005 | Gallery action label | Home navigation/layout tests pass; TC08 regression fixes result guidance overflow at 1.8x text. | Inspect installed build at the actual Android font size. |
| 006 | Live camera controls | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 007 | Result readability | Narrow-screen enlarged-text result test passes; result remains scrollable. | Inspect real multi-fruit labels and details. |
| 008 | Large text layout | Home navigation/layout tests pass; TC08 regression fixes result guidance overflow at 1.8x text. | Inspect installed build at the actual Android font size. |
| 009 | Direct live navigation | home_navigation_test.dart verifies direct routes, picker cancellation and duplicate-tap blocking. | Native picker and camera hardware. |
| 010 | Direct gallery navigation | home_navigation_test.dart verifies direct routes, picker cancellation and duplicate-tap blocking. | Native picker and camera hardware. |
| 011 | Back from live view | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 012 | Cancel image selection | home_navigation_test.dart verifies direct routes, picker cancellation and duplicate-tap blocking. | Native picker and camera hardware. |
| 013 | Processing feedback | Provider busy-state tests pass; loading and failure states are separated. | Measure processing latency on the target phone. |
| 014 | Cancel replacement photo | TC14 regression preserves image, nonempty detections and guidance after cancellation; gallery retry is now available on successful results too. | Cancel the native gallery on the phone. |
| 015 | Capture Again navigation | result_navigation_test.dart verifies return to existing live route and gallery-to-camera replacement. | Repeat with a native camera and real photo. |
| 016 | Result scrolling | Narrow-screen enlarged-text result test passes; result remains scrollable. | Inspect real multi-fruit labels and details. |
| 017 | Permission allowed | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 018 | Permission denied | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 019 | Permission recovery | TC19/59 reproduced Settings recovery failure and now passes with a mocked permission service and camera. | Grant permission through Android Settings and return. |
| 020 | Live preview | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 021 | Still photo capture | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 022 | JPEG gallery input | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 023 | PNG gallery input | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 024 | Portrait image input | Image cache/fit and camera conversion tests pass; photo preprocessing bakes EXIF orientation. | Actual JPEG metadata and mask alignment still need image/device checks. |
| 025 | Landscape image input | Image cache/fit and camera conversion tests pass; photo preprocessing bakes EXIF orientation. | Actual JPEG metadata and mask alignment still need image/device checks. |
| 026 | Switch selected photo | TC81/98 alternates empty/nonempty results over ten files, checking image identity and all counts. | Use five original gallery photos with the real model. |
| 027 | Live fruit detection | Tracker/result-policy tests cover confirmation, maturity uncertainty and expiry; no change to model scores. | Real moving camera, live/still parity and localization accuracy. |
| 028 | Stable live localization | Tracker/result-policy tests cover confirmation, maturity uncertainty and expiry; no change to model scores. | Real moving camera, live/still parity and localization accuracy. |
| 029 | Immature reference | Three-class mapping is unchanged and tested; no independent maturity ground truth supplied for this audit. | Independently labelled examples for every maturity stage. |
| 030 | Mature reference | Three-class mapping is unchanged and tested; no independent maturity ground truth supplied for this audit. | Independently labelled examples for every maturity stage. |
| 031 | Overmature reference | Three-class mapping is unchanged and tested; no independent maturity ground truth supplied for this audit. | Independently labelled examples for every maturity stage. |
| 032 | Multiple visible fruits | Model limitation: desktop inference on original photos retains only 2/3/3 candidates after NMS; large yellow fruit is missed. | Known-count reference scenes on the evaluation phone; do not mark passed from this audit. |
| 033 | Mixed maturity scene | Three-class mapping is unchanged and tested; no independent maturity ground truth supplied for this audit. | Independently labelled examples for every maturity stage. |
| 034 | Empty scene | Desktop CPU model smoke check: neutral blank image has zero candidates above 0.45. | Real wall/floor gallery and live scenes; one synthetic blank is not full coverage. |
| 035 | Non calabash fruit | No suitable negative-image set executed during this audit. Parser guards cannot guarantee species rejection. | Run each named fruit/object through both gallery and live detection; record false positives. |
| 036 | Background objects | No suitable negative-image set executed during this audit. Parser guards cannot guarantee species rejection. | Run each named fruit/object through both gallery and live detection; record false positives. |
| 037 | Repeat the same file | Photo inference uses deterministic CPU and shared postprocessing; raw tensors saved for diagnosis. | Three repeated real scans and mask comparison on the phone. |
| 038 | Live and capture comparison | Tracker/result-policy tests cover confirmation, maturity uncertainty and expiry; no change to model scores. | Real moving camera, live/still parity and localization accuracy. |
| 039 | Selected photo display | Image cache/fit and camera conversion tests pass; photo preprocessing bakes EXIF orientation. | Actual JPEG metadata and mask alignment still need image/device checks. |
| 040 | Transparent masks | Painter uses 14% mask fill and 42% edge opacity; mask reconstruction/smoothing tests pass. | Check actual silhouettes, not merely bounding boxes, on representative photos. |
| 041 | Mask alignment | Image cache/fit and camera conversion tests pass; photo preprocessing bakes EXIF orientation. | Actual JPEG metadata and mask alignment still need image/device checks. |
| 042 | Mask presentation | Painter uses 14% mask fill and 42% edge opacity; mask reconstruction/smoothing tests pass. | Check actual silhouettes, not merely bounding boxes, on representative photos. |
| 043 | Maturity color mapping | Class labels/colors and tensor/postprocessing tests pass; labels now clamp to their measured dimensions. | Compare every actual label, confidence and result row. |
| 044 | Confidence display | Class labels/colors and tensor/postprocessing tests pass; labels now clamp to their measured dimensions. | Compare every actual label, confidence and result row. |
| 045 | Fruit identification | Class labels/colors and tensor/postprocessing tests pass; labels now clamp to their measured dimensions. | Compare every actual label, confidence and result row. |
| 046 | Total detection count | TC81/98 checks total and per-stage count replacement; shared provider supplies all summary counts. | Compare rendered multi-fruit image labels with summary and rows. |
| 047 | Stage count totals | TC81/98 checks total and per-stage count replacement; shared provider supplies all summary counts. | Compare rendered multi-fruit image labels with summary and rows. |
| 048 | Result list consistency | Class labels/colors and tensor/postprocessing tests pass; labels now clamp to their measured dimensions. | Compare every actual label, confidence and result row. |
| 049 | No detection wording | Regression tests distinguish analysis failure from a successful empty scan and clear stale harvest guidance. | Run corrupt/blurred, empty and successful photos on Android. |
| 050 | Harvest guidance | Regression tests distinguish analysis failure from a successful empty scan and clear stale harvest guidance. | Run corrupt/blurred, empty and successful photos on Android. |
| 051 | Offline gallery analysis | Nunito Sans is bundled; test loads the full theme with runtime fetching disabled. Model remains a bundled asset. | Fresh install in airplane mode, including native camera/gallery. |
| 052 | Offline live operation | Nunito Sans is bundled; test loads the full theme with runtime fetching disabled. Model remains a bundled asset. | Fresh install in airplane mode, including native camera/gallery. |
| 053 | Repeated capture cycle | Mock camera tests cover repeated capture, duplicate capture prevention and stalled-camera timeout/recovery. | Five actual capture/result/Capture Again cycles and rapid shutter taps. |
| 054 | Repeated shutter taps | Mock camera tests cover repeated capture, duplicate capture prevention and stalled-camera timeout/recovery. | Five actual capture/result/Capture Again cycles and rapid shutter taps. |
| 055 | Background and return | Session tests cover lifecycle release/resume overlap; disposed photo inference no longer notifies removed widgets. | Screen lock, call, notification shade and app switching on hardware. |
| 056 | Restart after closing | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 057 | Second Android device | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 058 | Incoming call recovery | Session tests cover lifecycle release/resume overlap; disposed photo inference no longer notifies removed widgets. | Screen lock, call, notification shade and app switching on hardware. |
| 059 | Permission denial | TC19/59 reproduced Settings recovery failure and now passes with a mocked permission service and camera. | Grant permission through Android Settings and return. |
| 060 | Device rotation recovery | Camera policy tests cover Android sensor rotation in all four orientations. | Rotate a running native preview and verify live mask alignment; not certified by unit tests. |
| 061 | Low-light detection | Model/scene dependent; robustness is not established by UI or parser tests. | Labelled reference scene under the specified lighting, size, placement or occlusion. |
| 062 | Bright sunlight exposure | Model/scene dependent; robustness is not established by UI or parser tests. | Labelled reference scene under the specified lighting, size, placement or occlusion. |
| 063 | Uneven illumination | Model/scene dependent; robustness is not established by UI or parser tests. | Labelled reference scene under the specified lighting, size, placement or occlusion. |
| 064 | Cluttered vegetation | Model/scene dependent; robustness is not established by UI or parser tests. | Labelled reference scene under the specified lighting, size, placement or occlusion. |
| 065 | Similar-colored background | Model/scene dependent; robustness is not established by UI or parser tests. | Labelled reference scene under the specified lighting, size, placement or occlusion. |
| 066 | Dark background | Model/scene dependent; robustness is not established by UI or parser tests. | Labelled reference scene under the specified lighting, size, placement or occlusion. |
| 067 | Small distant fruit | Model/scene dependent; robustness is not established by UI or parser tests. | Labelled reference scene under the specified lighting, size, placement or occlusion. |
| 068 | Close-up fruit | Model/scene dependent; robustness is not established by UI or parser tests. | Labelled reference scene under the specified lighting, size, placement or occlusion. |
| 069 | Partially occluded fruit | Model/scene dependent; robustness is not established by UI or parser tests. | Labelled reference scene under the specified lighting, size, placement or occlusion. |
| 070 | Partially cropped fruit | Prototype crops clamp to tensor bounds; mask postprocessing tests pass. | Actual partially cropped fruit and display-edge inspection. |
| 071 | Overlapping calabashes | Model/scene dependent; robustness is not established by UI or parser tests. | Labelled reference scene under the specified lighting, size, placement or occlusion. |
| 072 | Different fruit sizes | Model limitation: desktop inference on original photos retains only 2/3/3 candidates after NMS; large yellow fruit is missed. | Known-count reference scenes on the evaluation phone; do not mark passed from this audit. |
| 073 | Irregular fruit shape | Model/scene dependent; robustness is not established by UI or parser tests. | Labelled reference scene under the specified lighting, size, placement or occlusion. |
| 074 | Fruit near image border | Both edge-label regressions failed before repair and now pass at 80x240 and 320x180 with 1.8x text. | Top/bottom/side fruits in actual captured and gallery photos. |
| 075 | Fruit near top or bottom | Both edge-label regressions failed before repair and now pass at 80x240 and 320x180 with 1.8x text. | Top/bottom/side fruits in actual captured and gallery photos. |
| 076 | Multiple similar-stage fruits | Model limitation: desktop inference on original photos retains only 2/3/3 candidates after NMS; large yellow fruit is missed. | Known-count reference scenes on the evaluation phone; do not mark passed from this audit. |
| 077 | High-resolution gallery photo | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 078 | Low-resolution gallery photo | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 079 | Blurred photo handling | Regression tests distinguish analysis failure from a successful empty scan and clear stale harvest guidance. | Run corrupt/blurred, empty and successful photos on Android. |
| 080 | Image with rotated metadata | Image cache/fit and camera conversion tests pass; photo preprocessing bakes EXIF orientation. | Actual JPEG metadata and mask alignment still need image/device checks. |
| 081 | Repeated gallery analysis | TC81/98 alternates empty/nonempty results over ten files, checking image identity and all counts. | Use five original gallery photos with the real model. |
| 082 | Rapid gallery replacement | Back-during-analysis widget test passes; cancelled generations cannot publish late results; duplicate requests remain blocked. | Android Back and rapid native picker replacement. |
| 083 | Return during image processing | Back-during-analysis widget test passes; cancelled generations cannot publish late results; duplicate requests remain blocked. | Android Back and rapid native picker replacement. |
| 084 | Reopen same result workflow | result_navigation_test.dart verifies return to existing live route and gallery-to-camera replacement. | Repeat with a native camera and real photo. |
| 085 | Screen lock during live view | Session tests cover lifecycle release/resume overlap; disposed photo inference no longer notifies removed widgets. | Screen lock, call, notification shade and app switching on hardware. |
| 086 | Notification interruption | Session tests cover lifecycle release/resume overlap; disposed photo inference no longer notifies removed widgets. | Screen lock, call, notification shade and app switching on hardware. |
| 087 | App switching recovery | Session tests cover lifecycle release/resume overlap; disposed photo inference no longer notifies removed widgets. | Screen lock, call, notification shade and app switching on hardware. |
| 088 | Low battery operation | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 089 | Low storage handling | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 090 | Extended live detection | Code inspected; no end-to-end execution of this case. | Run on the Android evaluation device with the specified setup. |
| 091 | Camera movement recovery | Tracker/result-policy tests cover confirmation, maturity uncertainty and expiry; no change to model scores. | Real moving camera, live/still parity and localization accuracy. |
| 092 | Fast camera movement | Tracker/result-policy tests cover confirmation, maturity uncertainty and expiry; no change to model scores. | Real moving camera, live/still parity and localization accuracy. |
| 093 | Confidence near threshold | Confidence filtering and uncertain live maturity wording are retained; threshold stays 0.45. | Labelled near-threshold field examples; confidence is not a correctness guarantee. |
| 094 | Adjacent maturity stages | Three-class mapping is unchanged and tested; no independent maturity ground truth supplied for this audit. | Independently labelled examples for every maturity stage. |
| 095 | Mature and Overmature boundary | Three-class mapping is unchanged and tested; no independent maturity ground truth supplied for this audit. | Independently labelled examples for every maturity stage. |
| 096 | Mask consistency across repeats | Photo inference uses deterministic CPU and shared postprocessing; raw tensors saved for diagnosis. | Three repeated real scans and mask comparison on the phone. |
| 097 | Detection overlay after zooming | Result uses a shared contain-fit rectangle; no interactive zoom is implemented. | Record zoom as unsupported; verify normal fit remains usable. |
| 098 | No-result recovery | TC81/98 alternates empty/nonempty results over ten files, checking image identity and all counts. | Use five original gallery photos with the real model. |
| 099 | Long-session result consistency | Ten sequential mock photo analyses pass; navigation and recovery tests also pass separately. | Mixed native live/gallery session and complete cold-launch workflow. |
| 100 | Final end-to-end verification | Ten sequential mock photo analyses pass; navigation and recovery tests also pass separately. | Mixed native live/gallery session and complete cold-launch workflow. |
| 101 | Cucumber as non-calabash | No suitable negative-image set executed during this audit. Parser guards cannot guarantee species rejection. | Run each named fruit/object through both gallery and live detection; record false positives. |
| 102 | Cantaloupe as non-calabash | No suitable negative-image set executed during this audit. Parser guards cannot guarantee species rejection. | Run each named fruit/object through both gallery and live detection; record false positives. |
| 103 | Brown coconut as non-calabash | No suitable negative-image set executed during this audit. Parser guards cannot guarantee species rejection. | Run each named fruit/object through both gallery and live detection; record false positives. |
| 104 | Green coconut as non-calabash | No suitable negative-image set executed during this audit. Parser guards cannot guarantee species rejection. | Run each named fruit/object through both gallery and live detection; record false positives. |
| 105 | Brown ball as non-calabash | No suitable negative-image set executed during this audit. Parser guards cannot guarantee species rejection. | Run each named fruit/object through both gallery and live detection; record false positives. |
| 106 | Bottle gourd as non-calabash | No suitable negative-image set executed during this audit. Parser guards cannot guarantee species rejection. | Run each named fruit/object through both gallery and live detection; record false positives. |
| 107 | Avocado as non-calabash | No suitable negative-image set executed during this audit. Parser guards cannot guarantee species rejection. | Run each named fruit/object through both gallery and live detection; record false positives. |
| 108 | Green mango as non-calabash | No suitable negative-image set executed during this audit. Parser guards cannot guarantee species rejection. | Run each named fruit/object through both gallery and live detection; record false positives. |
| 109 | Green apple as non-calabash | No suitable negative-image set executed during this audit. Parser guards cannot guarantee species rejection. | Run each named fruit/object through both gallery and live detection; record false positives. |
| 110 | Lanzones as non-calabash | No suitable negative-image set executed during this audit. Parser guards cannot guarantee species rejection. | Run each named fruit/object through both gallery and live detection; record false positives. |
| 111 | Green peppers as non-calabash | No suitable negative-image set executed during this audit. Parser guards cannot guarantee species rejection. | Run each named fruit/object through both gallery and live detection; record false positives. |
| 112 | Papaya as non-calabash | No suitable negative-image set executed during this audit. Parser guards cannot guarantee species rejection. | Run each named fruit/object through both gallery and live detection; record false positives. |
