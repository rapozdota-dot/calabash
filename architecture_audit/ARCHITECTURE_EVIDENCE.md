# Architecture evidence ledger

The audited artifact is [assets/model/model.tflite](../assets/model/model.tflite), SHA-256 `d0a6959c7859a1fc4190fbbcd8ab95cecdfd2390aea6b7f359a86f719f8f4563`. Binary references are subgraph 0 operator indices and tensor IDs because the artifact has no source line numbers. The [full operator ledger](LAYER_BY_LAYER.md#operator-ledger) preserves the evidence in readable form.

**Code** means verified in checked-in source. **Artifact** means verified from the trained FP32 TFLite export, including its graph, constants or metadata as identified. **Runtime** means verified through an independent synthetic execution of the exported operators. **Historical** means a locally reachable source, build archive or prior diagnostic. **Inferred** marks an upstream-compatible interpretation. **Unknown** marks missing source or measurements. No original training checkpoint was available for checkpoint-level verification.

| Claim | Evidence anchor | Method | Confidence |
| --- | --- | --- | --- |
| One integrated model bundles and loads offline | [pubspec:74–76](../pubspec.yaml#L74-L76), [constants:7](../lib/utils/constants.dart#L7), [ModelService:227–239](../lib/services/model_service.dart#L227-L239), FlatBuffer model subgraphs and op 0 | Code + artifact and identical SHA-256 across both V7 copies | High |
| Source feature extractor is TorchVision MobileNetV3-Small | Ops 1–106, `TorchVision_0`, `torchvision.models.mobilenetv3.InvertedResidual_1…11`, `torchvision.ops.misc.SqueezeExcitation`. [TorchVision Small configuration](https://github.com/pytorch/vision/blob/v0.24.0/torchvision/models/mobilenetv3.py#L206-L248) | Artifact names plus operator-level structural comparison with upstream | High for exported architecture |
| Active YOLO feature extractor replaced, SPPF retained downstream | Ops 0–115, `SPPF_7` ops 116–125. V7 standalone [commit 770a88e](https://github.com/rapozdota-dot/calabash/commit/770a88ef98edb8b97bc6cf3bd37b64da810017e9) has the YOLO Conv/C2f backbone through op 98, followed by SPPF | Artifact graph traversal and baseline comparison | High |
| Stem and IR1–11 are active; stock 576-channel terminal projection, pooling and classifier do not participate | t251 through t354. Following ops consume t267/t321/t354 directly. [TorchVision source feature tail and classifier](https://github.com/pytorch/vision/blob/v0.24.0/torchvision/models/mobilenetv3.py#L152-L202) | Artifact operator scopes and reachability | High for export, unknown for training module registration |
| Tap positions and widths | IR3 op 19 t267 80×80×24, IR8 op 73 t321 40×40×48, IR11 op 106 t354 20×20×96. Conv_4–6 at 107–115 yield t357/t360/t363 | Artifact edges, independent synthetic execution | High |
| Exact source selectors and ImageNet initialization | [TorchVision wrapper upstream](https://github.com/ultralytics/ultralytics/blob/v8.4.191/ultralytics/nn/modules/block.py#L1449-L1506), [TorchVision constructor](https://github.com/pytorch/vision/blob/v0.24.0/torchvision/models/mobilenetv3.py#L367-L394) | Upstream split semantics support inferred list indices 4/9/12. Project model YAML, training checkpoint, constructor and training logs were unavailable | Inferred selector mechanism, unknown constructor arguments and weight lineage |
| SPPF, top-down and bottom-up routes | Ops 116–199. SPPF t373 and C2f_10 t390 are reused later at ops 184 and 164 respectively. `Segment_20` consumes t407/t427/t447 | Artifact graph traversal and independent synthetic execution | High |
| Class scores originate in the Segment head | Ops 228–255 and 298 feed three sigmoids into output t558, channels 4–6. [Metadata parser:20–31](../tool/validate_ios_release.py#L20-L31), [Dart class parser:682–729](../lib/services/model_service.dart#L682-L729) | Artifact + code | High |
| 16-bin DFL integral and normalized boxes | Ops 227, 284–297, 309. Kernel t159 contains 0–15, t241 is zero bias, t246 has stride values 8/16/32 in candidate order, t247 contains half-cell grid centers | Artifact constants + execution. Training DFL loss and weighting remain unknown | High for inference |
| 32 coefficients and 32 shared prototypes | Coeff ops 256–283. Prototype ops 299–308 and 311 consume P3 t407, use 128 hidden channels and emit t559 | Artifact edges + execution | High |
| No graph NMS or final instance-mask generation | t558 and t559 are the only outputs, raw candidate axis 8400. [NMS/mask orchestration:449–488](../lib/services/model_service.dart#L449-L488), [weighted mask sum:87–124](../lib/services/segmentation_postprocessor.dart#L87-L124) | Artifact + code | High |
| Stored parameter and convolution computation estimates | [Layer counts and conventions](LAYER_BY_LAYER.md#size-and-computation) | Direct summation of unique FP32 convolution buffers and nominal kernel work | High under stated counting convention |
| V7 comparison artifacts and local package drift | [System audit hashes and archive identities](SYSTEM_AUDIT.md#models-and-deployment-evidence), [archived IPA source-info:3–12](../.tmp-run22-artifact/Calabash-source-info.txt#L3-L12), [comparison workflow at acee015](https://github.com/rapozdota-dot/calabash/blob/acee0150c30b37f623e253c14691216291c7f41e/.github/workflows/android-release.yml) | Historical Git blobs and local ZIP entries hashed directly | High for inspected artifacts, unknown for devices and manuscript runs |
| Python diagnostic reports raw outputs | [diagnose_model.py:12–54](../tool/diagnose_model.py#L12-L54), [sample modes:57–91](../tool/diagnose_model.py#L57-L91) | Code trace | High |
| Python training source and export conversion stages | Embedded metadata names a Colab dataset YAML and Ultralytics 8.4.191. `_NormalizeCoords` scope and op 309 show normalization. [Upstream wrapper](https://github.com/ultralytics/ultralytics/blob/v8.4.191/ultralytics/utils/export/engine.py#L27-L55) | Metadata and artifact. Search of working tree and reachable history found no training or conversion invocation | High for exported normalization, unknown for exact commands and intermediate formats |

## Synthetic reference execution

A temporary Python evaluator read the FlatBuffer tables directly and executed all 312 operators using the stored weights, biases, literal constants and operator attributes with NumPy 2.2.6 and SciPy 1.15.3. Input was a uniform RGB tensor of shape `[1,3,640,640]`, value `114/255`, float32. The evaluator asserted the expected shape, dtype and finite values after every operation. This is reference execution of the artifact on Windows. The native LiteRT interpreter and Android/iOS device runtimes were unavailable for this run.

| Runtime observation | Result |
| --- | --- |
| Raw backbone taps t267, t321, t354 | `[1,80,80,24]`, `[1,40,40,48]`, `[1,20,20,96]` |
| Adapted taps t357, t360, t363 | `[1,80,80,48]`, `[1,40,40,96]`, `[1,20,20,192]` |
| Fused head inputs t407, t427, t447 | `[1,80,80,48]`, `[1,40,40,96]`, `[1,20,20,192]` |
| DFL softmax t534 / expected offsets t536 | `[1,4,8400,16]` / `[1,4,8400]` |
| Detection t558 | `[1,39,8400]`, all finite. Normalized box components spanned roughly −0.04360 to 0.99828. |
| Max class scores by output index | `2.1870e-4`, `3.9291e-7`, `1.3553e-7`. Zero candidates above 0.45. |
| Prototypes t559 | `[1,32,160,160]`, all finite, range roughly −0.27846 to 6.51325. |

## Reproducing the evidence

1. Record the checkout commit and compare the SHA-256 of the named export and bundled asset. Inspect metadata using `python tool/validate_ios_release.py model assets/model/model.tflite`.
2. Read the TFLite FlatBuffer with a schema-generated reader or inspect it with a graph viewer that exposes built-in op options and constants. Read `Model.subgraphs[0]`, then join `Operator.inputs` and `Operator.outputs` to the corresponding `Tensor` tables and `Model.buffers`. Match the exported node and tensor IDs in the [operator ledger](LAYER_BY_LAYER.md#operator-ledger). [Official TFLite FlatBuffer schema](https://raw.githubusercontent.com/tensorflow/tensorflow/master/tensorflow/compiler/mlir/lite/schema/schema.fbs)
3. Read the baseline Git blob at `770a88e:assets/model/model.tflite` and compare its graph and hash without replacing the active asset. Hash the exact asset entry inside any candidate APK/IPA before attributing a device result to a variant.
4. Where LiteRT and Pillow are available, run `python tool/diagnose_model.py --model assets/model/model.tflite` for its blank-input check. For a device path, use the repository's iOS worker smoke and record the tested model SHA. [CLI blank fixture:91](../tool/diagnose_model.py#L91), [iOS workflow:79–88](../.github/workflows/build-ios.yml#L79-L88)
