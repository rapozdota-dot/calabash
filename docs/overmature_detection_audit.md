# Overmature Detection Audit

Date: 22 October 2026

## Model rollback

Restored `assets/model/model.tflite` from commit `91ec458`, immediately before
the `demofix defense` replacement. SHA-256:
`2e377b3b81edc3398d9d3ebf41f77dd7ad46d60a321f27ddc499a51ba9e68547`.
The three-class mapping, 640-square input, preprocessing, masks, NMS, and
confidence thresholds are unchanged. No UI changes were made.

## Reproduced application issue

Live tracking previously processed detections in prediction order. With two
nearby fruits, a moving candidate could claim the neighboring fruit's track
before that neighbor's exact-position candidate was considered. The displayed
stage then came from the wrong track's stored maturity history. A regression
test failed before the fix (expected track 1, received track 2).

Matching now considers all eligible spatial pairs and reserves the strongest
pairs first, using the same overlap, center-distance, and area gates. Each
candidate/track is used once. Maturity class does not bias matching, and the
existing repeated-evidence rule for changing a confirmed stage is retained.
This reduces a reproducible source of neighbor-label transfer; it is not a
guarantee of identity tracking during occlusion or crossing fruit positions.

## Raw model checks

Used three earlier original 1536x2048 user photos, not annotated screenshots.
Ran the restored TFLite model on the computer using LiteRT, float32 RGB /255,
640-square letterboxing, and channel-first input. Pillow bilinear sampling and
desktop execution can differ slightly from Dart/mobile execution. These are
diagnostic predictions, not mobile speed or ground-truth accuracy measurements.

Inspected nine manually selected fruit regions and 36 isolated-crop rotations
(0, 90, 180, 270 degrees). Cropping changes apparent scale and background as
well as context; it does not prove that another fruit's class caused a miss.
No crop or rotation augmentation was added to the mobile pipeline.

| Original photo stem | Dark fruit in full scene | Same fruit isolated, 0 degrees |
| --- | --- | --- |
| `7c37bf93-cf22-4530-9967-524ce097f7c3` | Overmature 35.54%, below 45% threshold | Overmature 62.71% |
| `5127ea17-21a4-46f2-a191-d73d0a1423b4` | Overmature 91.22% | Overmature 33.41% |
| `1fd8783a-152f-41f0-ad25-fc4a78b8d2ba` | Overmature 77.10% | Overmature 41.90% |

For the first dark-fruit crop, overmature scores across rotations were 62.71%,
61.63%, 20.95%, and 0.17%. This variation occurs before Flutter filtering or
tracking. The selected foreground green-fruit regions remained Mature at
their highest-scoring matching anchor in the full scenes. Those photos alone
do not reproduce every reported mature-to-overmature misclassification.
A neutral blank image produced no candidates above the confidence threshold.

Local diagnostic data (not committed, and without copying private photos):
`output/overmature_audit/raw_model_comparison.json`.

## Remaining limitations

Some missed detections originate in the model's sensitivity to image
orientation, scale, and scene content, not a special application rule excluding
overmature fruit. Lowering only the overmature threshold would not fix
near-zero predictions and could increase false positives. Accordingly, no
class-specific threshold or forced label heuristic was introduced.

Further improvement requires representative labeled mixed-stage real photos,
multiple orientations/viewpoints and lighting conditions, followed by held-out
per-class evaluation. Fresh original examples of the reported label flips are
still needed for direct verification. Physical-device verification was not
performed in this audit because no ADB device was connected.
