# V7 hybrid neural network architecture

## Graph identity and evidence level

**Verified from exported artifact.** One FP32 `SegmentationModel` subgraph contains the Ultralytics `TorchVision_0` feature extractor and `Segment_20` prediction module. Tensor names identify `torchvision.models.mobilenetv3.InvertedResidual` and `torchvision.ops.misc.SqueezeExcitation`. The exact channel, stride, expansion, kernel and activation sequence of all 11 blocks matches TorchVision's Small configuration. The graph feeds the adapters exclusively from MobileNet features. The original YOLOv8 Conv/C2f feature extractor has been replaced on every active path. The YOLO-family SPPF is retained downstream of the deepest adapter, followed by the modified YOLO neck and segmentation head. There is one network invocation for boxes, three maturity scores, coefficients and prototypes. [Operator ledger](LAYER_BY_LAYER.md#operator-ledger), [TorchVision Small and Large definitions](https://github.com/pytorch/vision/blob/v0.24.0/torchvision/models/mobilenetv3.py#L206-L248).

**Verified from the active graph.** The backbone retains the stem and inverted residual blocks 1–11. The stock Small model's terminal 96→576 pointwise feature convolution, classifier pooling, and classifier are absent from the deployed graph. The 576-channel intermediates within blocks 10 and 11 are expansion tensors that project back to 96. Global means inside SE blocks implement channel gates. They supply no image-level class score. The artifact establishes the live endpoints even if training held extra modules that the exporter pruned. [Layer table](LAYER_BY_LAYER.md#torchvision-backbone), [upstream feature tail and classifier](https://github.com/pytorch/vision/blob/v0.24.0/torchvision/models/mobilenetv3.py#L152-L202).

**Inferred source wiring.** The three fan-out edges and adapter names `Conv_4`, `Conv_5`, `Conv_6` are consistent with three Ultralytics feature-selection layers occupying positions 1–3 after a split `TorchVision_0`. If upstream `TorchVision.forward` split semantics were used without extra stages, its list begins with the input and the tap indices would be 4, 9 and 12. The artifact contains direct edges after export. The model YAML, Index constructor arguments, explicit wrapper truncation, TorchVision package version, width configuration syntax, checkpoint load call, `weights` argument, ImageNet initialization and freeze schedule are **unverified**. Upstream defaults only explain a possible construction. [Ultralytics TorchVision implementation](https://github.com/ultralytics/ultralytics/blob/v8.4.191/ultralytics/nn/modules/block.py#L1449-L1506).

## Backbone and feature integration

The external RGB tensor is `[1,3,640,640]` FP32. Op 0 transposes it to `[1,640,640,3]`; the following spatial shapes are written as H × W × C with batch 1 implicit. The stem is 3×3, stride 2, 16 channels, with Hard-Swish. The inverted residuals optionally expand channels with a pointwise convolution, apply a 3×3 or 5×5 depthwise convolution, optionally gate with SE, and project linearly with 1×1 convolution. ReLU is used in blocks 1–3, Hard-Swish in blocks 4–11. Identity additions occur at blocks 3, 5, 6, 8, 10 and 11. SE uses per-channel spatial mean, two 1×1 convolutions with ReLU and Hard-Sigmoid, and channel-wise multiplication. [Exact stage parameters](LAYER_BY_LAYER.md#torchvision-backbone).

| Scale | Raw backbone tap | Adapter | Destination |
| --- | --- | --- | --- |
| P3 / stride 8 | IR3, op 19, t267, 80×80×24 | `Conv_4`, 1×1 + SiLU, t357, 80×80×48 | `Concat_12` with upsampled `C2f_10` |
| P4 / stride 16 | IR8, op 73, t321, 40×40×48 | `Conv_5`, 1×1 + SiLU, t360, 40×40×96 | `Concat_9` with upsampled `SPPF_7` |
| P5 / stride 32 | IR11, op 106, t354, 20×20×96 | `Conv_6`, 1×1 + SiLU, t363, 20×20×192 | `SPPF_7`, then both the top-down and bottom-up paths |

`SPPF_7` projects 192→96, applies three serial 5×5, stride-1 SAME max pools, concatenates the unpooled tensor and all three pool outputs to 384 channels, then projects 384→192. Both SPPF convolutions have SiLU in the export, including ops 116–118 before pooling. The tagged Ultralytics 8.4.191 SPPF constructor disables activation on its first convolution. This artifact/constructor difference prevents reconstructing SPPF by instantiating the tagged default alone. [Tagged SPPF source](https://github.com/ultralytics/ultralytics/blob/v8.4.191/ultralytics/nn/modules/block.py#L195-L220). The top-down path upsamples by 2× nearest neighbor before each lateral concat. The bottom-up path uses 3×3, stride-2 convolution before each concat. Each of the four C2f stages uses one bottleneck with two 3×3 convolutions and no local residual addition. C2f splits its first projected tensor into equal halves and concatenates both halves plus the processed second half, then applies its final 1×1 projection. See [routing table](LAYER_BY_LAYER.md#feature-routing).

## Prediction and export

`Segment_20` receives `C2f_13` (80×80×48), `C2f_16` (40×40×96), and `C2f_19` (20×20×192) in that order. Each feature map feeds three independent convolutional towers. The first two convolutions per tower are dense 3×3, stride 1 with SiLU. The last is a linear 1×1. Intermediate widths are 64 for box regression, 48 for maturity classification, and 32 for coefficients across all scales. Each cell predicts 64 regression logits, three class logits, and 32 mask coefficients. Each branch flattens its spatial dimensions in row-major order. The three scale ranges in the concatenated candidate axis are 0–6399, 6400–7999 and 8000–8399.

The effective head dimensions correspond to `Segment(nc=3, nm=32, npr=128, reg_max=16, end2end=False, ch=(48,96,192))`. The observed dense maturity towers correspond to the tagged `Detect.legacy` construction. These are graph-derived settings, with the original construction call and source configuration still unavailable. [Detect class tower variants](https://github.com/ultralytics/ultralytics/blob/v8.4.191/ultralytics/nn/modules/head.py#L112-L130), [Segment constructor](https://github.com/ultralytics/ultralytics/blob/v8.4.191/ultralytics/nn/modules/head.py#L292-L314).

- **Box regression.** The 64 logits are 4 distance distributions of 16 bins each. Ops 284–288 apply softmax over the bin dimension and a fixed integral with weights 0 through 15 and zero bias. The four expected distances are interpreted as left, top, right and bottom relative to the grid center at `(x+0.5,y+0.5)`. Ops 289–297 compute corner offsets, convert to center/width/height and apply strides 8, 16 and 32. Op 309 divides by 640 through multiplication by `0.0015625`. The exported coordinates may extend outside the image. Training loss configuration and loss gains remain unverified. [Export wrapper reference](https://github.com/ultralytics/ultralytics/blob/v8.4.191/ultralytics/utils/export/engine.py#L27-L55).
- **Maturity.** Op 298 applies elementwise sigmoid to the three concatenated class logits. Class 0 is Immature, 1 Mature, 2 Overmature. Output channels 4–6 hold these scores. The graph exposes three class scores per grid location and no independent objectness or species-verification output. App confidence is the selected maturity-class score. [App parser:682–729](../lib/services/model_service.dart#L682-L729).
- **Coefficients and prototypes.** The 32 coefficients per candidate remain signed. A single `Proto_proto` branch starts at `C2f_13`. It applies 3×3 + SiLU (48→128 at 80²), 2×2 stride-2 learned transposed convolution with bias (128→128 at 160², linear), 3×3 + SiLU (128→128), then 1×1 + SiLU (128→32). It transposes the prototype bank to NCHW. The prototype values are shared continuous basis maps. The app combines them with selected coefficients to construct individual masks. [Ultralytics Segment reference](https://github.com/ultralytics/ultralytics/blob/v8.4.191/ultralytics/nn/modules/head.py#L274-L347), [app mask sum:87–124](../lib/services/segmentation_postprocessor.dart#L87-L124).

Output slot 0 is tensor 558, `[1,39,8400]`, with channels 0–3 normalized `cx,cy,w,h`, 4–6 sigmoid maturity scores, and 7–38 coefficients. Output slot 1 is tensor 559, `[1,32,160,160]`, the prototype bank. Confidence filtering, NMS, mask reconstruction and rendering run outside the graph. [Mobile inference and geometry](INFERENCE_PIPELINE.md).

## Comparison with the V7 standalone artifact

| Graph property | V7 standalone `770a88e` | V7 hybrid |
| --- | --- | --- |
| Active feature extractor | YOLO Conv/C2f hierarchy | TorchVision Small stem and 11 inverted residuals |
| SPPF output | 20×20×256 | 20×20×192 |
| Head input channels P3/P4/P5 | 64 / 128 / 256 | 48 / 96 / 192 |
| Hidden box/class/coeff channels | 64 / 80 / 32 | 64 / 48 / 32 |
| Proto hidden width | 64 | 128 |
| Prototype and detection output shapes | `[1,32,160,160]`, `[1,39,8400]` | Same |
| Folded convolution kernel/bias scalars | 3,385,610 | 2,462,130 |
| Estimated convolution MACs at 640² | 5,949,638,400 | 6,990,468,352 |

The hybrid file is about 26% smaller, but its convolution estimate is about 17.5% higher. In particular, the 160×160 prototype branch has a 128→128 3×3 convolution, which by itself contributes 3,774,873,600 MACs. Report export storage, graph computation, training parameter count and measured device latency with their own units and methodology. Counts and assumptions are documented in the [layer report](LAYER_BY_LAYER.md#size-and-computation).
