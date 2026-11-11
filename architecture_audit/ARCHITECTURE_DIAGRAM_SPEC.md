# Scientific illustration specification

**Calabash V7 hybrid instance-segmentation network with a TorchVision MobileNetV3-Small backbone**

Draw the FP32 TFLite model `d0a6959c7859a1fc4190fbbcd8ab95cecdfd2390aea6b7f359a86f719f8f4563`. Use batch 1. Use **H×W×C** for internal feature annotations and write both external output tensors with explicit axes. Read the [connection and operator ledger](LAYER_BY_LAYER.md) and [Mermaid source](HYBRID_ARCHITECTURE.mmd) as the drawing reference.

## A. Input and backbone

At the left, show one RGB calabash image after letterboxing and /255 packing as FP32 `[1,3,640,640]`. Place a small NCHW→NHWC annotation on the graph's input edge. Start the backbone at a 3×3/2 Conv stem, Hard-Swish, 320×320×16. Connect the stages in the order below. Annotate expanded channels or ratios and mark SE and identity additions using the legend.

| Stage | DW kernel / stride | Expanded channels | SE squeeze width | Activation | Output H×W×C | Add |
| --- | --- | ---: | ---: | --- | --- | --- |
| IR1 | 3×3 / 2 | 16, no expansion op | 8 | ReLU | 160×160×16 | — |
| IR2 | 3×3 / 2 | 72 | — | ReLU | 80×80×24 | — |
| IR3, P3 tap | 3×3 / 1 | 88 | — | ReLU | 80×80×24 | Yes |
| IR4 | 5×5 / 2 | 96 | 24 | Hard-Swish | 40×40×40 | — |
| IR5 | 5×5 / 1 | 240 | 64 | Hard-Swish | 40×40×40 | Yes |
| IR6 | 5×5 / 1 | 240 | 64 | Hard-Swish | 40×40×40 | Yes |
| IR7 | 5×5 / 1 | 120 | 32 | Hard-Swish | 40×40×48 | — |
| IR8, P4 tap | 5×5 / 1 | 144 | 40 | Hard-Swish | 40×40×48 | Yes |
| IR9 | 5×5 / 2 | 288 | 72 | Hard-Swish | 20×20×96 | — |
| IR10 | 5×5 / 1 | 576 | 144 | Hard-Swish | 20×20×96 | Yes |
| IR11, P5 tap | 5×5 / 1 | 576 | 144 | Hard-Swish | 20×20×96 | Yes |

A compact inset can show **optional 1×1 expansion → depthwise convolution → optional SE → linear 1×1 projection → optional residual add**. Place ReLU or Hard-Swish after expansion and depthwise convolution only. Show SE as a side gate with spatial average → 1×1 reduction with ReLU → 1×1 expansion with Hard-Sigmoid → channel-wise multiply. Route P3 and P4 forward through the subsequent IR stages while branching each to its lateral adapter. P5 branches only into its adapter. The final active MobileNet tensor has 96 channels.

## B. Feature adapters and YOLO fusion

Draw three scale lanes. Use a distinct shape or fill for each 1×1 Conv + SiLU adapter. The tensor after each arrow is the destination output. Concat inputs are listed in graph order.

| Destination | Incoming edges and operation | Output |
| --- | --- | --- |
| `Conv_4` | IR3 P3, 24→48 | 80×80×48 |
| `Conv_5` | IR8 P4, 48→96 | 40×40×96 |
| `Conv_6` | IR11 P5, 96→192 | 20×20×192 |
| `SPPF_7` | `Conv_6` → 1×1 Conv + SiLU 192→96 → 5×5 stride-1 max pool ×3 in series. Join unpooled and all three pool outputs (384 channels) → 1×1 Conv + SiLU 384→192 | 20×20×192 |
| `Upsample_8` | `SPPF_7`, nearest-neighbor ×2 | 40×40×192 |
| `Concat_9` | `Upsample_8` + `Conv_5` | 40×40×288 |
| `C2f_10` | `Concat_9`, internal split width 48 | 40×40×96 |
| `Upsample_11` | `C2f_10`, nearest-neighbor ×2 | 80×80×96 |
| `Concat_12` | `Upsample_11` + `Conv_4` | 80×80×144 |
| `C2f_13` | `Concat_12`, internal split width 24. Fork to the P3 prediction towers, Proto and `Conv_14). | 80×80×48 |
| `Conv_14` | `C2f_13`, 3×3 / 2 | 40×40×48 |
| `Concat_15` | `Conv_14` + skip from `C2f_10` | 40×40×144 |
| `C2f_16` | `Concat_15`, internal split width 48. Fork to P4 towers and `Conv_17`. | 40×40×96 |
| `Conv_17` | `C2f_16`, 3×3 / 2 | 20×20×96 |
| `Concat_18` | `Conv_17` + skip from `SPPF_7` | 20×20×288 |
| `C2f_19` | `Concat_18`, internal split width 96, feeds P5 towers | 20×20×192 |

Use a C2f inset if space allows. Show 1×1 Conv → two equal channel slices `a,b` → two 3×3 Conv on `b` → concat `[a,b,processed b]` → 1×1 Conv. The four stage bottlenecks have no internal addition. Give the top-down route and bottom-up route visibly distinct arrow directions. Retain both cross-route skips.

## C. Segment head and the two exported outputs

Draw a single head group named **Ultralytics Segment_20**. Draw separate box, maturity, and coefficient towers at each scale, or one clearly labeled three-scale matrix. Each tower receives the corresponding neck output and applies 3×3 Conv + SiLU → 3×3 Conv + SiLU → linear 1×1 Conv. All tower strides are 1. The hidden-to-output widths are 64→64 for box, 48→3 for maturity and 32→32 for coefficients.

- **Box row.** Label the 64 values per cell as four 16-bin distance distributions. Flatten the three grids in P3/P4/P5 order to `[1,64,8400]`. Show bin softmax → fixed expectation → grid-point and stride decode → normalize center `xywh` by 640 → `[1,4,8400]`.
- **Maturity row.** Flatten to `[1,3,8400]` and apply sigmoid. Label the class order **Immature, Mature, Overmature**. App confidence is the selected class score.
- **Mask coefficient row.** Flatten the 32 signed coefficients per grid cell to `[1,32,8400]`. Preserve candidate alignment across all three rows.
- **Detection output.** Concatenate the three rows on the channel axis in the order `4+3+32` → **FP32 `[1,39,8400]`**. Show that 8400 candidates come from 80² + 40² + 20² at strides 8, 16 and 32.
- **Prototype row.** Branch from `C2f_13` P3 only. Draw 3×3 Conv + SiLU → **80×80×128**, learned 2×2 stride-2 transpose Conv → **160×160×128**, 3×3 Conv + SiLU → **160×160×128**, 1×1 Conv + SiLU → **160×160×32**, and NHWC→NCHW → **FP32 `[1,32,160,160]`**.

## D. Instance output outside the neural graph

Use a dashed boundary around the mobile postprocessing block. Route detection predictions through **class selection and confidence >0.45 → box mapping → NMS**. Same-class and cross-class suppression cutoffs are 0.60 and 0.85 IoU respectively. Merge each survivor's coefficient vector with the prototype bank in a dot-product box labeled `L(y,x)=Σ c[k]P[k,y,x]`. Show prototype crop, threshold `L>0`, mask support filtering and source-image mapping. End with one sample annotated image labeled **per-fruit bounding box, maturity stage, class score, and instance mask**. Keep the acquisition modes and live tracking in the optional [mobile pipeline figure](INFERENCE_PIPELINE.md).

## Caption and presentation

Use a landscape figure with left-to-right input, backbone, three-lane neck, head, and outputs. Keep type legible at manuscript size and label the scale lanes directly so the routing remains clear in grayscale. Use solid arrows for tensor flow and a dashed frame for application postprocessing. The operator names and shape labels take precedence over decorative network illustrations. Export the eventual manuscript figure as vector artwork where practical.

Suggested caption:

> Architecture reconstructed from the Calabash V7 FP32 TFLite export. The TorchVision MobileNetV3-Small stem and 11 inverted residual blocks supply stride-8, stride-16, and stride-32 feature maps. Learned channel projections and a YOLOv8-style SPPF/C2f neck feed the shared Segment head. The head exports normalized boxes, three maturity scores and 32 coefficients per candidate, plus 32 shared mask prototypes. The mobile application filters candidates and reconstructs instance masks.

The artifact establishes the inference topology. ImageNet initialization, the exact training YAML and checkpoint lineage remain unverified. Keep these source-level details out of verified figure labels. The figure contains the three maturity outputs of the Segment head. The last MobileNet stage, coefficients, prototypes and app mask reconstruction must remain visually distinct.
