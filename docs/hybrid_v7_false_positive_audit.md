# V7 Hybrid False-Positive Check

Date: 30 October 2026

## Model And Scope

Model: `calabash_v7_mobilenetv3small_yolov8seg_final_fp32.tflite`.
This updates only the hybrid test branch. The standalone model on `main` is
unchanged. The hybrid metadata identifies a MobileNetV3-small backbone with a
YOLOv8 segmentation head, not an independent species-verification classifier.

Verified float32 input `[1,3,640,640]`, detection output `[1,39,8400]`,
prototypes `[1,32,160,160]`, and class order Immature/Mature/Overmature.
No changes to input normalization, thresholds, masks, tracking, or UI were made.

## Desktop Diagnostics

Ran LiteRT directly on the supplied model, independent of Flutter and camera
tracking. Used the same 640-square RGB letterbox and /255 normalization, with
Pillow bilinear resizing. Results can differ slightly from Dart/mobile runs.

Checked all 57 explicitly empty-label validation/test images in the user's
`CalabashProject_retrainw-negativeimages.v7i.yolov8.zip`. Missing labels were
not silently treated as negatives; training images were not used. These are
dataset-labeled negatives, not an independently collected real-world test set.

| Split | Negative Images | Images With Raw Scores Above 0.45 | Images With Mask-Supported Predictions |
| --- | ---: | ---: | ---: |
| Validation | 24 | 3 | 3 |
| Test | 33 | 5 | 5 |
| Total | 57 | 8 | 8 |

Postprocessing used the app's confidence threshold 0.45, same-class/cross-class
NMS limits 0.60/0.85, and positive mask-logit support of at least four pixels
and 10% of the prototype crop. Desktop results exclude Dart display-mask
smoothing and live temporal confirmation. These are not phone measurements,
formal accuracy estimates, or proof of the exact final rendered app count.

Examples already present in raw model output:

- Test cantaloupe: Overmature 96.18%, mask crop support 75.49%.
- Validation cantaloupe: Overmature 92.97%, mask crop support 79.30%.
- Test guava: Overmature 82.69%, mask crop support 74.39%.
- Validation green coconut: Overmature 78.41%, mask crop support 76.60%.

The model returned predictions on three earlier original calabash photos, and
zero above-threshold candidates on a uniform neutral image. This is a smoke
test, not a claim that every calabash was detected or classified correctly.

## User Screenshot Stress Tests

The five supplied files are annotated app screenshots, not original camera
images. Both full screenshots and approximate inner scene crops were checked.
Labels, masks, screen sampling, and changed apparent scale contaminate these
inputs, so the results must not be presented as reproduction of the original
phone predictions or as an independent accuracy benchmark.

| Screenshot Subject | Full Screenshot Top Raw Score | Scene Crop Top Raw Score |
| --- | ---: | ---: |
| Balloon | 0.04% | 69.69% |
| Citrus | 0.15% | 7.01% |
| Drive page | 68.37% | 88.51% |
| Beach ball | 70.66% | 96.26% |
| Coconut | 85.53% | 11.40% |

## Findings And Decision

The known channel layout and class order match the parser. No frame-wide
maturity reassignment or mask-coefficient-as-class parsing was found. The
measured negative-image predictions originate in the model, before Flutter
rendering or temporal tracking. A coherent segmentation mask can outline a
wrong object; it is not proof that the object is a calabash.

Raising confidence alone cannot eliminate a 96% false positive without also
discarding legitimate lower-confidence fruit detections. The test already
shows substantial mask support on wrong objects, so merely tightening the
existing sparse-mask check does not establish species verification either.
No unvalidated color, shape, screen-blocking, or class-specific heuristic was
added. Such a change could hide real overmature fruits or break gallery use.

False-positive reduction remains an unresolved model/generalization issue.
Original failing camera photos are still needed for exact mobile-pipeline
reproduction and evaluation of any proposed remedy. No claim of a model
accuracy improvement or completed phone verification is made by this build.

Local evidence, without committing private images:

- `output/hybrid_v7_audit/new_hybrid.json`
- `output/hybrid_v7_audit/annotated_screenshot_stress_tests.json`
