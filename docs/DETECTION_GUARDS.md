# Detection safeguards

The bundled model, RGB normalization, 640x640 letterbox preprocessing and
three-class YOLO segmentation tensor layout are unchanged.

- Same-class NMS uses the existing 0.60 IoU limit.
- Different-class predictions with box IoU above 0.85 are treated as duplicate
  predictions of one fruit. The higher-confidence prediction is retained.
  Ordinary overlapping fruits with different maturity labels remain separate.
- A mask must have at least four foreground prototype pixels and foreground
  covering at least 10% of its box crop. Previously the fraction was only 1%.
- Any non-finite mask pixel within the crop rejects the candidate, even if
  earlier pixels already met the foreground count.
- Invalid scores, class IDs outside 0-2, and non-finite or degenerate boxes
  cannot survive NMS. Both photo and live detection use these shared checks.

These checks reduce duplicate and unsupported detections. They do not prove
an object is a calabash: a confidently incorrect, coherent model prediction
can still survive. A negative image that reproduces that behavior is needed
to distinguish model generalization errors from app post-processing issues.
The 10% fraction is a conservative sanity threshold, not a dataset-calibrated
operating point. Tiny or highly occluded fruits may need further validation.

Regression tests cover cross-stage duplicates, preservation of distinct
overlapping fruits, sparse/non-finite masks, and invalid NMS inputs. Archived
outputs for three earlier calabash photographs retain 3, 3 and 2 predictions;
the archived blank-image output has none. This is a post-processing replay,
not a fresh accuracy benchmark or validation of a new false-positive photo.

This release also includes first-permission lifecycle recovery, bounded camera
startup, rotation invalidation of old overlays, landscape capture controls,
and side-by-side results on wide screens. iOS remains manual-build only.
