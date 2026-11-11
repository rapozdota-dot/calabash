# V7 hybrid layer and tensor ledger

The identifiers `op` and `t` refer to zero-based FlatBuffer subgraph 0 operator and tensor indices in the SHA-256 `d0a6959…8f4563` export. Export scopes such as `Conv_4` and `Segment_20` identify source modules where preserved. Shapes in the spatial stage tables are H × W × C with batch 1 implicit and list the logical tensor before explicit zero padding. Bracketed tensors give the full storage order. Scalar counts are embedded convolution kernels plus biases after export folding, with the fixed DFL kernel and zero bias identified separately. Non-convolution operators add zero to these counts.

## TorchVision backbone

Op 0 converts RGB FP32 `[1,3,640,640]` t0 to NHWC `[1,640,640,3]` t248. The stem uses a 3×3 convolution, stride 2, and Hard-Swish. Each `InvertedResidual_i` uses an optional 1×1 expansion, one depthwise convolution with channel multiplier 1, optional SE and a linear 1×1 projection. Expansion activations match the listed depthwise activation. Residual additions take the stage input and linear projection as operands. All pointwise convolution strides are 1. The graph has explicit padding before stride-2 spatial convolution, and stage dimensions below exclude the pad.

| Module | Ops | Input H×W×C | Expanded C (ratio) | DW kernel / stride | SE expanded→squeeze→expanded | Expansion / DW activation | Identity add | Output H×W×C and tensor | Scalars |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | ---: |
| `TorchVision_0` stem `Conv2dNormActivation_0` | 1–3 | 640×640×3 | — | Dense 3×3 / 2 | — | Hard-Swish | — | 320×320×16 t251 → IR1 | 448 |
| `InvertedResidual_1` | 4–11 | 320×320×16 | 16 (1×, expansion omitted) | 3×3 / 2 | 16→8→16 | ReLU | — | 160×160×16 t259 → IR2 | 712 |
| `InvertedResidual_2` | 12–15 | 160×160×16 | 72 (4.5×) | 3×3 / 2 | — | ReLU | — | 80×80×24 t263 → IR3 | 3,696 |
| `InvertedResidual_3` | 16–19 | 80×80×24 | 88 (11/3×) | 3×3 / 1 | — | ReLU | op 19 | 80×80×24 t267 → IR4 and `Conv_4` | 5,216 |
| `InvertedResidual_4` | 20–30 | 80×80×24 | 96 (4×) | 5×5 / 2 | 96→24→96 | Hard-Swish | — | 40×40×40 t278 → IR5 | 13,504 |
| `InvertedResidual_5` | 31–41 | 40×40×40 | 240 (6×) | 5×5 / 1 | 240→64→240 | Hard-Swish | op 41 | 40×40×40 t289 → IR6 | 56,744 |
| `InvertedResidual_6` | 42–52 | 40×40×40 | 240 (6×) | 5×5 / 1 | 240→64→240 | Hard-Swish | op 52 | 40×40×40 t300 → IR7 | 56,744 |
| `InvertedResidual_7` | 53–62 | 40×40×40 | 120 (3×) | 5×5 / 1 | 120→32→120 | Hard-Swish | — | 40×40×48 t310 → IR8 | 21,680 |
| `InvertedResidual_8` | 63–73 | 40×40×48 | 144 (3×) | 5×5 / 1 | 144→40→144 | Hard-Swish | op 73 | 40×40×48 t321 → IR9 and `Conv_5` | 29,464 |
| `InvertedResidual_9` | 74–84 | 40×40×48 | 288 (6×) | 5×5 / 2 | 288→72→288 | Hard-Swish | — | 20×20×96 t332 → IR10 | 91,176 |
| `InvertedResidual_10` | 85–95 | 20×20×96 | 576 (6×) | 5×5 / 1 | 576→144→576 | Hard-Swish | op 95 | 20×20×96 t343 → IR11 | 292,848 |
| `InvertedResidual_11` | 96–106 | 20×20×96 | 576 (6×) | 5×5 / 1 | 576→144→576 | Hard-Swish | op 106 | 20×20×96 t354 → `Conv_6` | 292,848 |
| Backbone total | 0–106 | | | | | | | | **865,080** |

For each SE module, the activation tensor is averaged over H and W to `[1,1,1,Cexp]`. Two learned 1×1 kernels reduce and expand it with ReLU on the first. The exported gate uses a second convolution with the shift folded into its bias, fused ReLU6, then multiplication by 1/6. The resulting Hard-Sigmoid gate multiplies the original expanded depthwise activation channel by channel. The graph retains no classifier pooling or linear classification layers in `TorchVision_0`.

## Feature routing

All learned Conv operations in this section have SiLU, implemented as logistic then elementwise multiplication. All external and internal spatial concats use the last channel axis. The input order in the source column is the observed concat order.

| Source tensor(s) and shape | Transformation / destination | Ops | Output tensor and shape | Next consumer(s) | Scalars |
| --- | --- | --- | --- | --- | ---: |
| IR3 t267 80×80×24 | `Conv_4`, 1×1 / 1 | 107–109 | t357 80×80×48 | `Concat_12` | 1,200 |
| IR8 t321 40×40×48 | `Conv_5`, 1×1 / 1 | 110–112 | t360 40×40×96 | `Concat_9` | 4,704 |
| IR11 t354 20×20×96 | `Conv_6`, 1×1 / 1 | 113–115 | t363 20×20×192 | `SPPF_7` | 18,624 |
| t363 20×20×192 | `SPPF_7` 1×1 192→96, three serial 5×5 / 1 max pools, concat four 96-channel paths, 1×1 384→192 | 116–125 | t373 20×20×192 | `Upsample_8`, `Concat_18` | 92,448 |
| t373 20×20×192 | `Upsample_8`, nearest 2× | 126 | t374 40×40×192 | `Concat_9` | 0 |
| t374 40×40×192, t360 40×40×96 | `Concat_9` | 127 | t375 40×40×288 | `C2f_10` | 0 |
| t375 40×40×288 | `C2f_10`, one bottleneck, split width 48 | 128–142 | t390 40×40×96 | `Upsample_11`, `Concat_15` | 83,232 |
| t390 40×40×96 | `Upsample_11`, nearest 2× | 143 | t391 80×80×96 | `Concat_12` | 0 |
| t391 80×80×96, t357 80×80×48 | `Concat_12` | 144 | t392 80×80×144 | `C2f_13` | 0 |
| t392 80×80×144 | `C2f_13`, one bottleneck, split width 24 | 145–159 | t407 80×80×48 | `Segment_20` P3 and Proto, `Conv_14` | 20,880 |
| t407 80×80×48 | `Conv_14`, 3×3 / 2 | 160–163 | t411 40×40×48 | `Concat_15` | 20,784 |
| t411 40×40×48, t390 40×40×96 | `Concat_15` | 164 | t412 40×40×144 | `C2f_16` | 0 |
| t412 40×40×144 | `C2f_16`, one bottleneck, split width 48 | 165–179 | t427 40×40×96 | `Segment_20` P4, `Conv_17` | 69,408 |
| t427 40×40×96 | `Conv_17`, 3×3 / 2 | 180–183 | t431 20×20×96 | `Concat_18` | 83,040 |
| t431 20×20×96, t373 20×20×192 | `Concat_18` | 184 | t432 20×20×288 | `C2f_19` | 0 |
| t432 20×20×288 | `C2f_19`, one bottleneck, split width 96 | 185–199 | t447 20×20×192 | `Segment_20` P5 | 277,056 |
| Adapters, SPPF and neck total | | 107–199 | | | **671,376** |

SPPF concat reads t366, t367, t368 and t369 at op 122. For each C2f, the first 1×1 convolution projects to 2c, split into `a` and `b` of width c. The bottleneck is two stride-1 3×3 convolutions on `b`, each c→c with no local addition. Concat `[a,b,bottleneck(b)]` then projects 3c to 2c using 1×1. This preserves the C2f internal routes while the outer neck joins projected and previously fused features. See ops 128–142 for the first implementation.

## Segment head

At each scale, each tower uses 3×3 + SiLU, 3×3 + SiLU and linear 1×1, all stride 1. The first two convolutions output the same width. Transpose and reshape after each tower expose channel-first candidate arrays.

| Tower | Input | Hidden width | Output on grid | Ops | Flattened output tensor and shape | Scalars |
| --- | --- | ---: | --- | --- | --- | ---: |
| Box P3 | t407 80×80×48 | 64 | 80×80×64 | 200–208 | t456 `[1,64,6400]` | 68,800 |
| Box P4 | t427 40×40×96 | 64 | 40×40×64 | 209–217 | t465 `[1,64,1600]` | 96,448 |
| Box P5 | t447 20×20×192 | 64 | 20×20×64 | 218–226 | t474 `[1,64,400]` | 151,744 |
| Class P3 | t407 80×80×48 | 48 | 80×80×3 | 228–236 | t484 `[1,3,6400]` | 41,715 |
| Class P4 | t427 40×40×96 | 48 | 40×40×3 | 237–245 | t493 `[1,3,1600]` | 62,451 |
| Class P5 | t447 20×20×192 | 48 | 20×20×3 | 246–254 | t502 `[1,3,400]` | 103,923 |
| Coeff P3 | t407 80×80×48 | 32 | 80×80×32 | 256–264 | t512 `[1,32,6400]` | 24,160 |
| Coeff P4 | t427 40×40×96 | 32 | 40×40×32 | 265–273 | t521 `[1,32,1600]` | 37,984 |
| Coeff P5 | t447 20×20×192 | 32 | 20×20×32 | 274–282 | t530 `[1,32,400]` | 65,632 |

| Source | Transform | Ops | Output | Scalars |
| --- | --- | --- | --- | ---: |
| t456, t465, t474 | Candidate-axis concat, reshape `[1,4,16,8400]`, transpose `[1,4,8400,16]`, softmax along 16 bins, fixed 1×1 expectation, reshape | 227, 284–288 | t475 `[1,64,8400]` before DFL, t536 `[1,4,8400]` after | 17 fixed |
| t536, anchor points t247, stride array t246 | Decode corners, assemble center xy and width/height, apply grid strides, normalize by 640 | 289–297, 309 | t545 pixel-space then t557 normalized `[1,4,8400]` | 0 |
| t484, t493, t502 | Candidate-axis concat, sigmoid | 255, 298 | t503 logits, t546 scores `[1,3,8400]` | 0 |
| t512, t521, t530 | Candidate-axis concat | 283 | t531 `[1,32,8400]` | 0 |
| P3 t407 80×80×48 | `Proto_proto.cv1` Conv 3×3 / 1 + SiLU | 299–301 | t549 80×80×128 | 55,424 |
| t549 80×80×128 | Proto transposed convolution, 2×2 / 2, valid, linear | 302 | t550 160×160×128 | 65,664 |
| t550 160×160×128 | `Proto_proto.cv2` Conv 3×3 / 1 + SiLU | 303–305 | t553 160×160×128 | 147,584 |
| t553 160×160×128 | `Proto_proto.cv3` Conv 1×1 / 1 + SiLU | 306–308 | t556 160×160×32 | 4,128 |
| t557 boxes, t546 class scores, t531 coefficients | Channel-axis concat | 310 | t558 `[1,39,8400]` | 0 |
| t556 160×160×32 | NHWC→NCHW | 311 | t559 `[1,32,160,160]` | 0 |
| Head total including Proto and fixed DFL | | 200–311 | | **925,674** |

## Size and computation

The 312 operators reference 560 tensor records. There are 94 dense Conv2D, 11 DepthwiseConv2D and one TransposeConv. Counting distinct embedded FP32 buffers used as convolution kernels or biases gives 212 buffers and **2,462,130 stored scalars**, including 16 fixed DFL bin weights and one fixed zero bias. The other convolution coefficients and biases account for 2,462,113 scalars. The original trainable parameter count can differ because of BatchNorm folding, fixed weights and possible unreachable source modules. Grid coordinates, strides, shape vectors and other graph constants are excluded.

At batch 1 and 640², the dense and depthwise estimate counts output positions times kernel elements. For the nonoverlapping 2×2 transpose convolution, it counts input positions times kernel elements. The resulting estimate is **6,990,468,352 MACs**, or **13.981 GFLOPs** under the convention of two arithmetic operations per MAC. This excludes bias adds, activation, softmax, pooling, interpolation, copying, and mobile postprocessing. It counts nominal work including border computations and omits runtime and delegate optimization effects. Under the same convention the V7 standalone blob at `770a88e` gives **5,949,638,400 MACs** or **11.899 GFLOPs**. [Variant comparison](HYBRID_ARCHITECTURE.md#comparison-with-the-v7-standalone-artifact).

## Operator ledger

This is the compact, machine-extracted operator listing for the audited hash. Operands use `tensor@producer:shape`. `@const` identifies embedded constants and `@input` identifies the external input. Small shape/axis constants are printed inline. Outputs use `tensor:shape:module scope` when a source scope was retained. Operator aliases include DW (DepthwiseConv2D), CONV (Conv2D), TCONV (TransposeConv), CAT (Concatenation), NEAREST (ResizeNearestNeighbor), HSWISH (Hard-Swish), and SIGMOID (Logistic). `fused=0/1/3` means none/ReLU/ReLU6. The 2× nearest options are `align_corners=0` and `half_pixel_centers=1`, observed dimensions make the upsample an integer repeat.

<details>
<summary>All 312 TFLite operators, tensor edges, and convolution scalar counts</summary>

~~~text
000 TRANSPOSE      0@input:1x3x640x640,245@const:4=[0, 2, 3, 1] -> 248:1x640x640x3:TorchVision_0
001 PAD            248@0:1x640x640x3,154@const:4x2=[0, 0, 1, 1, 1, 1, 0, 0] -> 249:1x642x642x3:TorchVision_0
002 CONV           249@1:1x642x642x3,66@const:16x3x3x3,33@const:16 -> 250:1x320x320x16:TorchVision_0 padding=valid stride=2x2 fused=0 params=448
003 HSWISH         250@2:1x320x320x16 -> 251:1x320x320x16:TorchVision_0
004 PAD            251@3:1x320x320x16,154@const:4x2=[0, 0, 1, 1, 1, 1, 0, 0] -> 252:1x322x322x16:TorchVision_0/InvertedResidual_1/Sequential_block
005 DW             252@4:1x322x322x16,65@const:1x3x3x16,32@const:16 -> 253:1x160x160x16:TorchVision_0/InvertedResidual_1/Sequential_block padding=valid stride=2x2 fused=1 params=160
006 MEAN           253@5:1x160x160x16,85@const:2=[2, 1] -> 254:1x1x1x16:TorchVision_0/InvertedResidual_1/Sequential_block opts=[(0, 1)]
007 CONV           254@6:1x1x1x16,238@const:8x1x1x16,84@const:8 -> 255:1x1x1x8:TorchVision_0/InvertedResidual_1/Sequential_block padding=valid stride=1x1 fused=1 params=136
008 CONV           255@7:1x1x1x8,237@const:16x1x1x8,83@const:16 -> 256:1x1x1x16:TorchVision_0/InvertedResidual_1/Sequential_block padding=valid stride=1x1 fused=3 params=144
009 MUL            256@8:1x1x1x16,152@const:s=[0.1666667] -> 257:1x1x1x16:TorchVision_0/InvertedResidual_1/Sequential_block
010 MUL            257@9:1x1x1x16,253@5:1x160x160x16 -> 258:1x160x160x16:TorchVision_0/InvertedResidual_1/Sequential_block
011 CONV           258@10:1x160x160x16,64@const:16x1x1x16,31@const:16 -> 259:1x160x160x16:TorchVision_0/InvertedResidual_1/Sequential_block padding=valid stride=1x1 fused=0 params=272
012 CONV           259@11:1x160x160x16,63@const:72x1x1x16,30@const:72 -> 260:1x160x160x72:TorchVision_0/InvertedResidual_2/Sequential_block padding=valid stride=1x1 fused=1 params=1224
013 PAD            260@12:1x160x160x72,154@const:4x2=[0, 0, 1, 1, 1, 1, 0, 0] -> 261:1x162x162x72:TorchVision_0/InvertedResidual_2/Sequential_block
014 DW             261@13:1x162x162x72,62@const:1x3x3x72,29@const:72 -> 262:1x80x80x72:TorchVision_0/InvertedResidual_2/Sequential_block padding=valid stride=2x2 fused=1 params=720
015 CONV           262@14:1x80x80x72,61@const:24x1x1x72,28@const:24 -> 263:1x80x80x24:TorchVision_0/InvertedResidual_2/Sequential_block padding=valid stride=1x1 fused=0 params=1752
016 CONV           263@15:1x80x80x24,60@const:88x1x1x24,27@const:88 -> 264:1x80x80x88:TorchVision_0/InvertedResidual_3/Sequential_block padding=valid stride=1x1 fused=1 params=2200
017 DW             264@16:1x80x80x88,59@const:1x3x3x88,26@const:88 -> 265:1x80x80x88:TorchVision_0/InvertedResidual_3/Sequential_block padding=same stride=1x1 fused=1 params=880
018 CONV           265@17:1x80x80x88,58@const:24x1x1x88,25@const:24 -> 266:1x80x80x24:TorchVision_0/InvertedResidual_3/Sequential_block padding=valid stride=1x1 fused=0 params=2136
019 ADD            266@18:1x80x80x24,263@15:1x80x80x24 -> 267:1x80x80x24:TorchVision_0/InvertedResidual_3
020 CONV           267@19:1x80x80x24,57@const:96x1x1x24,24@const:96 -> 268:1x80x80x96:TorchVision_0/InvertedResidual_4/Sequential_block padding=valid stride=1x1 fused=0 params=2400
021 HSWISH         268@20:1x80x80x96 -> 269:1x80x80x96:TorchVision_0/InvertedResidual_4/Sequential_block
022 PAD            269@21:1x80x80x96,153@const:4x2=[0, 0, 2, 2, 2, 2, 0, 0] -> 270:1x84x84x96:TorchVision_0/InvertedResidual_4/Sequential_block
023 DW             270@22:1x84x84x96,56@const:1x5x5x96,23@const:96 -> 271:1x40x40x96:TorchVision_0/InvertedResidual_4/Sequential_block padding=valid stride=2x2 fused=0 params=2496
024 HSWISH         271@23:1x40x40x96 -> 272:1x40x40x96:TorchVision_0/InvertedResidual_4/Sequential_block
025 MEAN           272@24:1x40x40x96,85@const:2=[2, 1] -> 273:1x1x1x96:TorchVision_0/InvertedResidual_4/Sequential_block opts=[(0, 1)]
026 CONV           273@25:1x1x1x96,236@const:24x1x1x96,82@const:24 -> 274:1x1x1x24:TorchVision_0/InvertedResidual_4/Sequential_block padding=valid stride=1x1 fused=1 params=2328
027 CONV           274@26:1x1x1x24,235@const:96x1x1x24,81@const:96 -> 275:1x1x1x96:TorchVision_0/InvertedResidual_4/Sequential_block padding=valid stride=1x1 fused=3 params=2400
028 MUL            275@27:1x1x1x96,152@const:s=[0.1666667] -> 276:1x1x1x96:TorchVision_0/InvertedResidual_4/Sequential_block
029 MUL            276@28:1x1x1x96,272@24:1x40x40x96 -> 277:1x40x40x96:TorchVision_0/InvertedResidual_4/Sequential_block
030 CONV           277@29:1x40x40x96,55@const:40x1x1x96,22@const:40 -> 278:1x40x40x40:TorchVision_0/InvertedResidual_4/Sequential_block padding=valid stride=1x1 fused=0 params=3880
031 CONV           278@30:1x40x40x40,54@const:240x1x1x40,21@const:240 -> 279:1x40x40x240:TorchVision_0/InvertedResidual_5/Sequential_block padding=valid stride=1x1 fused=0 params=9840
032 HSWISH         279@31:1x40x40x240 -> 280:1x40x40x240:TorchVision_0/InvertedResidual_5/Sequential_block
033 DW             280@32:1x40x40x240,53@const:1x5x5x240,20@const:240 -> 281:1x40x40x240:TorchVision_0/InvertedResidual_5/Sequential_block padding=same stride=1x1 fused=0 params=6240
034 HSWISH         281@33:1x40x40x240 -> 282:1x40x40x240:TorchVision_0/InvertedResidual_5/Sequential_block
035 MEAN           282@34:1x40x40x240,85@const:2=[2, 1] -> 283:1x1x1x240:TorchVision_0/InvertedResidual_5/Sequential_block opts=[(0, 1)]
036 CONV           283@35:1x1x1x240,234@const:64x1x1x240,80@const:64 -> 284:1x1x1x64:TorchVision_0/InvertedResidual_5/Sequential_block padding=valid stride=1x1 fused=1 params=15424
037 CONV           284@36:1x1x1x64,233@const:240x1x1x64,79@const:240 -> 285:1x1x1x240:TorchVision_0/InvertedResidual_5/Sequential_block padding=valid stride=1x1 fused=3 params=15600
038 MUL            285@37:1x1x1x240,152@const:s=[0.1666667] -> 286:1x1x1x240:TorchVision_0/InvertedResidual_5/Sequential_block
039 MUL            286@38:1x1x1x240,282@34:1x40x40x240 -> 287:1x40x40x240:TorchVision_0/InvertedResidual_5/Sequential_block
040 CONV           287@39:1x40x40x240,52@const:40x1x1x240,19@const:40 -> 288:1x40x40x40:TorchVision_0/InvertedResidual_5/Sequential_block padding=valid stride=1x1 fused=0 params=9640
041 ADD            288@40:1x40x40x40,278@30:1x40x40x40 -> 289:1x40x40x40:TorchVision_0/InvertedResidual_5
042 CONV           289@41:1x40x40x40,51@const:240x1x1x40,18@const:240 -> 290:1x40x40x240:TorchVision_0/InvertedResidual_6/Sequential_block padding=valid stride=1x1 fused=0 params=9840
043 HSWISH         290@42:1x40x40x240 -> 291:1x40x40x240:TorchVision_0/InvertedResidual_6/Sequential_block
044 DW             291@43:1x40x40x240,50@const:1x5x5x240,17@const:240 -> 292:1x40x40x240:TorchVision_0/InvertedResidual_6/Sequential_block padding=same stride=1x1 fused=0 params=6240
045 HSWISH         292@44:1x40x40x240 -> 293:1x40x40x240:TorchVision_0/InvertedResidual_6/Sequential_block
046 MEAN           293@45:1x40x40x240,85@const:2=[2, 1] -> 294:1x1x1x240:TorchVision_0/InvertedResidual_6/Sequential_block opts=[(0, 1)]
047 CONV           294@46:1x1x1x240,232@const:64x1x1x240,78@const:64 -> 295:1x1x1x64:TorchVision_0/InvertedResidual_6/Sequential_block padding=valid stride=1x1 fused=1 params=15424
048 CONV           295@47:1x1x1x64,231@const:240x1x1x64,77@const:240 -> 296:1x1x1x240:TorchVision_0/InvertedResidual_6/Sequential_block padding=valid stride=1x1 fused=3 params=15600
049 MUL            296@48:1x1x1x240,152@const:s=[0.1666667] -> 297:1x1x1x240:TorchVision_0/InvertedResidual_6/Sequential_block
050 MUL            297@49:1x1x1x240,293@45:1x40x40x240 -> 298:1x40x40x240:TorchVision_0/InvertedResidual_6/Sequential_block
051 CONV           298@50:1x40x40x240,49@const:40x1x1x240,16@const:40 -> 299:1x40x40x40:TorchVision_0/InvertedResidual_6/Sequential_block padding=valid stride=1x1 fused=0 params=9640
052 ADD            299@51:1x40x40x40,289@41:1x40x40x40 -> 300:1x40x40x40:TorchVision_0/InvertedResidual_6
053 CONV           300@52:1x40x40x40,48@const:120x1x1x40,15@const:120 -> 301:1x40x40x120:TorchVision_0/InvertedResidual_7/Sequential_block padding=valid stride=1x1 fused=0 params=4920
054 HSWISH         301@53:1x40x40x120 -> 302:1x40x40x120:TorchVision_0/InvertedResidual_7/Sequential_block
055 DW             302@54:1x40x40x120,47@const:1x5x5x120,14@const:120 -> 303:1x40x40x120:TorchVision_0/InvertedResidual_7/Sequential_block padding=same stride=1x1 fused=0 params=3120
056 HSWISH         303@55:1x40x40x120 -> 304:1x40x40x120:TorchVision_0/InvertedResidual_7/Sequential_block
057 MEAN           304@56:1x40x40x120,85@const:2=[2, 1] -> 305:1x1x1x120:TorchVision_0/InvertedResidual_7/Sequential_block opts=[(0, 1)]
058 CONV           305@57:1x1x1x120,230@const:32x1x1x120,76@const:32 -> 306:1x1x1x32:TorchVision_0/InvertedResidual_7/Sequential_block padding=valid stride=1x1 fused=1 params=3872
059 CONV           306@58:1x1x1x32,229@const:120x1x1x32,75@const:120 -> 307:1x1x1x120:TorchVision_0/InvertedResidual_7/Sequential_block padding=valid stride=1x1 fused=3 params=3960
060 MUL            307@59:1x1x1x120,152@const:s=[0.1666667] -> 308:1x1x1x120:TorchVision_0/InvertedResidual_7/Sequential_block
061 MUL            308@60:1x1x1x120,304@56:1x40x40x120 -> 309:1x40x40x120:TorchVision_0/InvertedResidual_7/Sequential_block
062 CONV           309@61:1x40x40x120,46@const:48x1x1x120,13@const:48 -> 310:1x40x40x48:TorchVision_0/InvertedResidual_7/Sequential_block padding=valid stride=1x1 fused=0 params=5808
063 CONV           310@62:1x40x40x48,45@const:144x1x1x48,12@const:144 -> 311:1x40x40x144:TorchVision_0/InvertedResidual_8/Sequential_block padding=valid stride=1x1 fused=0 params=7056
064 HSWISH         311@63:1x40x40x144 -> 312:1x40x40x144:TorchVision_0/InvertedResidual_8/Sequential_block
065 DW             312@64:1x40x40x144,44@const:1x5x5x144,11@const:144 -> 313:1x40x40x144:TorchVision_0/InvertedResidual_8/Sequential_block padding=same stride=1x1 fused=0 params=3744
066 HSWISH         313@65:1x40x40x144 -> 314:1x40x40x144:TorchVision_0/InvertedResidual_8/Sequential_block
067 MEAN           314@66:1x40x40x144,85@const:2=[2, 1] -> 315:1x1x1x144:TorchVision_0/InvertedResidual_8/Sequential_block opts=[(0, 1)]
068 CONV           315@67:1x1x1x144,228@const:40x1x1x144,74@const:40 -> 316:1x1x1x40:TorchVision_0/InvertedResidual_8/Sequential_block padding=valid stride=1x1 fused=1 params=5800
069 CONV           316@68:1x1x1x40,227@const:144x1x1x40,73@const:144 -> 317:1x1x1x144:TorchVision_0/InvertedResidual_8/Sequential_block padding=valid stride=1x1 fused=3 params=5904
070 MUL            317@69:1x1x1x144,152@const:s=[0.1666667] -> 318:1x1x1x144:TorchVision_0/InvertedResidual_8/Sequential_block
071 MUL            318@70:1x1x1x144,314@66:1x40x40x144 -> 319:1x40x40x144:TorchVision_0/InvertedResidual_8/Sequential_block
072 CONV           319@71:1x40x40x144,43@const:48x1x1x144,10@const:48 -> 320:1x40x40x48:TorchVision_0/InvertedResidual_8/Sequential_block padding=valid stride=1x1 fused=0 params=6960
073 ADD            320@72:1x40x40x48,310@62:1x40x40x48 -> 321:1x40x40x48:TorchVision_0/InvertedResidual_8
074 CONV           321@73:1x40x40x48,42@const:288x1x1x48,9@const:288 -> 322:1x40x40x288:TorchVision_0/InvertedResidual_9/Sequential_block padding=valid stride=1x1 fused=0 params=14112
075 HSWISH         322@74:1x40x40x288 -> 323:1x40x40x288:TorchVision_0/InvertedResidual_9/Sequential_block
076 PAD            323@75:1x40x40x288,153@const:4x2=[0, 0, 2, 2, 2, 2, 0, 0] -> 324:1x44x44x288:TorchVision_0/InvertedResidual_9/Sequential_block
077 DW             324@76:1x44x44x288,41@const:1x5x5x288,8@const:288 -> 325:1x20x20x288:TorchVision_0/InvertedResidual_9/Sequential_block padding=valid stride=2x2 fused=0 params=7488
078 HSWISH         325@77:1x20x20x288 -> 326:1x20x20x288:TorchVision_0/InvertedResidual_9/Sequential_block
079 MEAN           326@78:1x20x20x288,85@const:2=[2, 1] -> 327:1x1x1x288:TorchVision_0/InvertedResidual_9/Sequential_block opts=[(0, 1)]
080 CONV           327@79:1x1x1x288,226@const:72x1x1x288,72@const:72 -> 328:1x1x1x72:TorchVision_0/InvertedResidual_9/Sequential_block padding=valid stride=1x1 fused=1 params=20808
081 CONV           328@80:1x1x1x72,225@const:288x1x1x72,71@const:288 -> 329:1x1x1x288:TorchVision_0/InvertedResidual_9/Sequential_block padding=valid stride=1x1 fused=3 params=21024
082 MUL            329@81:1x1x1x288,152@const:s=[0.1666667] -> 330:1x1x1x288:TorchVision_0/InvertedResidual_9/Sequential_block
083 MUL            330@82:1x1x1x288,326@78:1x20x20x288 -> 331:1x20x20x288:TorchVision_0/InvertedResidual_9/Sequential_block
084 CONV           331@83:1x20x20x288,40@const:96x1x1x288,7@const:96 -> 332:1x20x20x96:TorchVision_0/InvertedResidual_9/Sequential_block padding=valid stride=1x1 fused=0 params=27744
085 CONV           332@84:1x20x20x96,39@const:576x1x1x96,6@const:576 -> 333:1x20x20x576:TorchVision_0/InvertedResidual_10/Sequential_block padding=valid stride=1x1 fused=0 params=55872
086 HSWISH         333@85:1x20x20x576 -> 334:1x20x20x576:TorchVision_0/InvertedResidual_10/Sequential_block
087 DW             334@86:1x20x20x576,38@const:1x5x5x576,5@const:576 -> 335:1x20x20x576:TorchVision_0/InvertedResidual_10/Sequential_block padding=same stride=1x1 fused=0 params=14976
088 HSWISH         335@87:1x20x20x576 -> 336:1x20x20x576:TorchVision_0/InvertedResidual_10/Sequential_block
089 MEAN           336@88:1x20x20x576,85@const:2=[2, 1] -> 337:1x1x1x576:TorchVision_0/InvertedResidual_10/Sequential_block opts=[(0, 1)]
090 CONV           337@89:1x1x1x576,224@const:144x1x1x576,70@const:144 -> 338:1x1x1x144:TorchVision_0/InvertedResidual_10/Sequential_block padding=valid stride=1x1 fused=1 params=83088
091 CONV           338@90:1x1x1x144,223@const:576x1x1x144,69@const:576 -> 339:1x1x1x576:TorchVision_0/InvertedResidual_10/Sequential_block padding=valid stride=1x1 fused=3 params=83520
092 MUL            339@91:1x1x1x576,152@const:s=[0.1666667] -> 340:1x1x1x576:TorchVision_0/InvertedResidual_10/Sequential_block
093 MUL            340@92:1x1x1x576,336@88:1x20x20x576 -> 341:1x20x20x576:TorchVision_0/InvertedResidual_10/Sequential_block
094 CONV           341@93:1x20x20x576,37@const:96x1x1x576,4@const:96 -> 342:1x20x20x96:TorchVision_0/InvertedResidual_10/Sequential_block padding=valid stride=1x1 fused=0 params=55392
095 ADD            342@94:1x20x20x96,332@84:1x20x20x96 -> 343:1x20x20x96:TorchVision_0/InvertedResidual_10
096 CONV           343@95:1x20x20x96,36@const:576x1x1x96,3@const:576 -> 344:1x20x20x576:TorchVision_0/InvertedResidual_11/Sequential_block padding=valid stride=1x1 fused=0 params=55872
097 HSWISH         344@96:1x20x20x576 -> 345:1x20x20x576:TorchVision_0/InvertedResidual_11/Sequential_block
098 DW             345@97:1x20x20x576,35@const:1x5x5x576,2@const:576 -> 346:1x20x20x576:TorchVision_0/InvertedResidual_11/Sequential_block padding=same stride=1x1 fused=0 params=14976
099 HSWISH         346@98:1x20x20x576 -> 347:1x20x20x576:TorchVision_0/InvertedResidual_11/Sequential_block
100 MEAN           347@99:1x20x20x576,85@const:2=[2, 1] -> 348:1x1x1x576:TorchVision_0/InvertedResidual_11/Sequential_block opts=[(0, 1)]
101 CONV           348@100:1x1x1x576,222@const:144x1x1x576,68@const:144 -> 349:1x1x1x144:TorchVision_0/InvertedResidual_11/Sequential_block padding=valid stride=1x1 fused=1 params=83088
102 CONV           349@101:1x1x1x144,221@const:576x1x1x144,67@const:576 -> 350:1x1x1x576:TorchVision_0/InvertedResidual_11/Sequential_block padding=valid stride=1x1 fused=3 params=83520
103 MUL            350@102:1x1x1x576,152@const:s=[0.1666667] -> 351:1x1x1x576:TorchVision_0/InvertedResidual_11/Sequential_block
104 MUL            351@103:1x1x1x576,347@99:1x20x20x576 -> 352:1x20x20x576:TorchVision_0/InvertedResidual_11/Sequential_block
105 CONV           352@104:1x20x20x576,34@const:96x1x1x576,1@const:96 -> 353:1x20x20x96:TorchVision_0/InvertedResidual_11/Sequential_block padding=valid stride=1x1 fused=0 params=55392
106 ADD            353@105:1x20x20x96,343@95:1x20x20x96 -> 354:1x20x20x96:TorchVision_0/InvertedResidual_11
107 CONV           267@19:1x80x80x24,220@const:48x1x1x24,151@const:48 -> 355:1x80x80x48:Conv_4 padding=valid stride=1x1 fused=0 params=1200
108 SIGMOID        355@107:1x80x80x48 -> 356:1x80x80x48:Conv_4
109 MUL            355@107:1x80x80x48,356@108:1x80x80x48 -> 357:1x80x80x48:Conv_4
110 CONV           321@73:1x40x40x48,219@const:96x1x1x48,150@const:96 -> 358:1x40x40x96:Conv_5 padding=valid stride=1x1 fused=0 params=4704
111 SIGMOID        358@110:1x40x40x96 -> 359:1x40x40x96:Conv_5
112 MUL            358@110:1x40x40x96,359@111:1x40x40x96 -> 360:1x40x40x96:Conv_5
113 CONV           354@106:1x20x20x96,218@const:192x1x1x96,149@const:192 -> 361:1x20x20x192:Conv_6 padding=valid stride=1x1 fused=0 params=18624
114 SIGMOID        361@113:1x20x20x192 -> 362:1x20x20x192:Conv_6
115 MUL            361@113:1x20x20x192,362@114:1x20x20x192 -> 363:1x20x20x192:Conv_6
116 CONV           363@115:1x20x20x192,217@const:96x1x1x192,148@const:96 -> 364:1x20x20x96:SPPF_7/Conv_cv1 padding=valid stride=1x1 fused=0 params=18528
117 SIGMOID        364@116:1x20x20x96 -> 365:1x20x20x96:SPPF_7/Conv_cv1
118 MUL            364@116:1x20x20x96,365@117:1x20x20x96 -> 366:1x20x20x96:SPPF_7/Conv_cv1
119 MAXPOOL        366@118:1x20x20x96 -> 367:1x20x20x96:SPPF_7 opts=[] filter=5x5 stride=1x1 padding=0
120 MAXPOOL        367@119:1x20x20x96 -> 368:1x20x20x96:SPPF_7 opts=[] filter=5x5 stride=1x1 padding=0
121 MAXPOOL        368@120:1x20x20x96 -> 369:1x20x20x96:SPPF_7 opts=[] filter=5x5 stride=1x1 padding=0
122 CAT            366@118:1x20x20x96,367@119:1x20x20x96,368@120:1x20x20x96,369@121:1x20x20x96 -> 370:1x20x20x384:SPPF_7 opts=[(0, 3)]
123 CONV           370@122:1x20x20x384,216@const:192x1x1x384,147@const:192 -> 371:1x20x20x192:SPPF_7/Conv_cv2 padding=valid stride=1x1 fused=0 params=73920
124 SIGMOID        371@123:1x20x20x192 -> 372:1x20x20x192:SPPF_7/Conv_cv2
125 MUL            371@123:1x20x20x192,372@124:1x20x20x192 -> 373:1x20x20x192:SPPF_7/Conv_cv2
126 NEAREST        373@125:1x20x20x192,244@const:2=[40, 40] -> 374:1x40x40x192:Upsample_8 opts=[(0, 0), (1, 1)]
127 CAT            374@126:1x40x40x192,360@112:1x40x40x96 -> 375:1x40x40x288:Concat_9 opts=[(0, 3)]
128 CONV           375@127:1x40x40x288,215@const:96x1x1x288,146@const:96 -> 376:1x40x40x96:C2f_10/Conv_cv1 padding=valid stride=1x1 fused=0 params=27744
129 SIGMOID        376@128:1x40x40x96 -> 377:1x40x40x96:C2f_10/Conv_cv1
130 MUL            376@128:1x40x40x96,377@129:1x40x40x96 -> 378:1x40x40x96:C2f_10/Conv_cv1
131 SLICE          378@130:1x40x40x96,145@const:4=[0, 0, 0, 48],144@const:4=[1, 40, 40, 48] -> 379:1x40x40x48:C2f_10/Bottleneck_0/Conv_cv1
132 CONV           379@131:1x40x40x48,214@const:48x3x3x48,143@const:48 -> 380:1x40x40x48:C2f_10/Bottleneck_0/Conv_cv1 padding=same stride=1x1 fused=0 params=20784
133 SIGMOID        380@132:1x40x40x48 -> 381:1x40x40x48:C2f_10/Bottleneck_0/Conv_cv1
134 MUL            380@132:1x40x40x48,381@133:1x40x40x48 -> 382:1x40x40x48:C2f_10/Bottleneck_0/Conv_cv1
135 CONV           382@134:1x40x40x48,213@const:48x3x3x48,142@const:48 -> 383:1x40x40x48:C2f_10/Bottleneck_0/Conv_cv2 padding=same stride=1x1 fused=0 params=20784
136 SIGMOID        383@135:1x40x40x48 -> 384:1x40x40x48:C2f_10/Bottleneck_0/Conv_cv2
137 MUL            383@135:1x40x40x48,384@136:1x40x40x48 -> 385:1x40x40x48:C2f_10/Bottleneck_0/Conv_cv2
138 SLICE          378@130:1x40x40x96,141@const:4=[0, 0, 0, 0],144@const:4=[1, 40, 40, 48] -> 386:1x40x40x48:C2f_10
139 CAT            386@138:1x40x40x48,379@131:1x40x40x48,385@137:1x40x40x48 -> 387:1x40x40x144:C2f_10 opts=[(0, 3)]
140 CONV           387@139:1x40x40x144,212@const:96x1x1x144,140@const:96 -> 388:1x40x40x96:C2f_10/Conv_cv2 padding=valid stride=1x1 fused=0 params=13920
141 SIGMOID        388@140:1x40x40x96 -> 389:1x40x40x96:C2f_10/Conv_cv2
142 MUL            388@140:1x40x40x96,389@141:1x40x40x96 -> 390:1x40x40x96:C2f_10/Conv_cv2
143 NEAREST        390@142:1x40x40x96,242@const:2=[80, 80] -> 391:1x80x80x96:Upsample_11 opts=[(0, 0), (1, 1)]
144 CAT            391@143:1x80x80x96,357@109:1x80x80x48 -> 392:1x80x80x144:Concat_12 opts=[(0, 3)]
145 CONV           392@144:1x80x80x144,211@const:48x1x1x144,139@const:48 -> 393:1x80x80x48:C2f_13/Conv_cv1 padding=valid stride=1x1 fused=0 params=6960
146 SIGMOID        393@145:1x80x80x48 -> 394:1x80x80x48:C2f_13/Conv_cv1
147 MUL            393@145:1x80x80x48,394@146:1x80x80x48 -> 395:1x80x80x48:C2f_13/Conv_cv1
148 SLICE          395@147:1x80x80x48,138@const:4=[0, 0, 0, 24],137@const:4=[1, 80, 80, 24] -> 396:1x80x80x24:C2f_13/Bottleneck_0/Conv_cv1
149 CONV           396@148:1x80x80x24,210@const:24x3x3x24,136@const:24 -> 397:1x80x80x24:C2f_13/Bottleneck_0/Conv_cv1 padding=same stride=1x1 fused=0 params=5208
150 SIGMOID        397@149:1x80x80x24 -> 398:1x80x80x24:C2f_13/Bottleneck_0/Conv_cv1
151 MUL            397@149:1x80x80x24,398@150:1x80x80x24 -> 399:1x80x80x24:C2f_13/Bottleneck_0/Conv_cv1
152 CONV           399@151:1x80x80x24,209@const:24x3x3x24,135@const:24 -> 400:1x80x80x24:C2f_13/Bottleneck_0/Conv_cv2 padding=same stride=1x1 fused=0 params=5208
153 SIGMOID        400@152:1x80x80x24 -> 401:1x80x80x24:C2f_13/Bottleneck_0/Conv_cv2
154 MUL            400@152:1x80x80x24,401@153:1x80x80x24 -> 402:1x80x80x24:C2f_13/Bottleneck_0/Conv_cv2
155 SLICE          395@147:1x80x80x48,141@const:4=[0, 0, 0, 0],137@const:4=[1, 80, 80, 24] -> 403:1x80x80x24:C2f_13
156 CAT            403@155:1x80x80x24,396@148:1x80x80x24,402@154:1x80x80x24 -> 404:1x80x80x72:C2f_13 opts=[(0, 3)]
157 CONV           404@156:1x80x80x72,208@const:48x1x1x72,134@const:48 -> 405:1x80x80x48:C2f_13/Conv_cv2 padding=valid stride=1x1 fused=0 params=3504
158 SIGMOID        405@157:1x80x80x48 -> 406:1x80x80x48:C2f_13/Conv_cv2
159 MUL            405@157:1x80x80x48,406@158:1x80x80x48 -> 407:1x80x80x48:C2f_13/Conv_cv2
160 PAD            407@159:1x80x80x48,154@const:4x2=[0, 0, 1, 1, 1, 1, 0, 0] -> 408:1x82x82x48:Conv_14
161 CONV           408@160:1x82x82x48,207@const:48x3x3x48,133@const:48 -> 409:1x40x40x48:Conv_14 padding=valid stride=2x2 fused=0 params=20784
162 SIGMOID        409@161:1x40x40x48 -> 410:1x40x40x48:Conv_14
163 MUL            409@161:1x40x40x48,410@162:1x40x40x48 -> 411:1x40x40x48:Conv_14
164 CAT            411@163:1x40x40x48,390@142:1x40x40x96 -> 412:1x40x40x144:Concat_15 opts=[(0, 3)]
165 CONV           412@164:1x40x40x144,206@const:96x1x1x144,132@const:96 -> 413:1x40x40x96:C2f_16/Conv_cv1 padding=valid stride=1x1 fused=0 params=13920
166 SIGMOID        413@165:1x40x40x96 -> 414:1x40x40x96:C2f_16/Conv_cv1
167 MUL            413@165:1x40x40x96,414@166:1x40x40x96 -> 415:1x40x40x96:C2f_16/Conv_cv1
168 SLICE          415@167:1x40x40x96,145@const:4=[0, 0, 0, 48],144@const:4=[1, 40, 40, 48] -> 416:1x40x40x48:C2f_16/Bottleneck_0/Conv_cv1
169 CONV           416@168:1x40x40x48,205@const:48x3x3x48,131@const:48 -> 417:1x40x40x48:C2f_16/Bottleneck_0/Conv_cv1 padding=same stride=1x1 fused=0 params=20784
170 SIGMOID        417@169:1x40x40x48 -> 418:1x40x40x48:C2f_16/Bottleneck_0/Conv_cv1
171 MUL            417@169:1x40x40x48,418@170:1x40x40x48 -> 419:1x40x40x48:C2f_16/Bottleneck_0/Conv_cv1
172 CONV           419@171:1x40x40x48,204@const:48x3x3x48,130@const:48 -> 420:1x40x40x48:C2f_16/Bottleneck_0/Conv_cv2 padding=same stride=1x1 fused=0 params=20784
173 SIGMOID        420@172:1x40x40x48 -> 421:1x40x40x48:C2f_16/Bottleneck_0/Conv_cv2
174 MUL            420@172:1x40x40x48,421@173:1x40x40x48 -> 422:1x40x40x48:C2f_16/Bottleneck_0/Conv_cv2
175 SLICE          415@167:1x40x40x96,141@const:4=[0, 0, 0, 0],144@const:4=[1, 40, 40, 48] -> 423:1x40x40x48:C2f_16
176 CAT            423@175:1x40x40x48,416@168:1x40x40x48,422@174:1x40x40x48 -> 424:1x40x40x144:C2f_16 opts=[(0, 3)]
177 CONV           424@176:1x40x40x144,203@const:96x1x1x144,129@const:96 -> 425:1x40x40x96:C2f_16/Conv_cv2 padding=valid stride=1x1 fused=0 params=13920
178 SIGMOID        425@177:1x40x40x96 -> 426:1x40x40x96:C2f_16/Conv_cv2
179 MUL            425@177:1x40x40x96,426@178:1x40x40x96 -> 427:1x40x40x96:C2f_16/Conv_cv2
180 PAD            427@179:1x40x40x96,154@const:4x2=[0, 0, 1, 1, 1, 1, 0, 0] -> 428:1x42x42x96:Conv_17
181 CONV           428@180:1x42x42x96,202@const:96x3x3x96,128@const:96 -> 429:1x20x20x96:Conv_17 padding=valid stride=2x2 fused=0 params=83040
182 SIGMOID        429@181:1x20x20x96 -> 430:1x20x20x96:Conv_17
183 MUL            429@181:1x20x20x96,430@182:1x20x20x96 -> 431:1x20x20x96:Conv_17
184 CAT            431@183:1x20x20x96,373@125:1x20x20x192 -> 432:1x20x20x288:Concat_18 opts=[(0, 3)]
185 CONV           432@184:1x20x20x288,201@const:192x1x1x288,127@const:192 -> 433:1x20x20x192:C2f_19/Conv_cv1 padding=valid stride=1x1 fused=0 params=55488
186 SIGMOID        433@185:1x20x20x192 -> 434:1x20x20x192:C2f_19/Conv_cv1
187 MUL            433@185:1x20x20x192,434@186:1x20x20x192 -> 435:1x20x20x192:C2f_19/Conv_cv1
188 SLICE          435@187:1x20x20x192,126@const:4=[0, 0, 0, 96],125@const:4=[1, 20, 20, 96] -> 436:1x20x20x96:C2f_19/Bottleneck_0/Conv_cv1
189 CONV           436@188:1x20x20x96,200@const:96x3x3x96,124@const:96 -> 437:1x20x20x96:C2f_19/Bottleneck_0/Conv_cv1 padding=same stride=1x1 fused=0 params=83040
190 SIGMOID        437@189:1x20x20x96 -> 438:1x20x20x96:C2f_19/Bottleneck_0/Conv_cv1
191 MUL            437@189:1x20x20x96,438@190:1x20x20x96 -> 439:1x20x20x96:C2f_19/Bottleneck_0/Conv_cv1
192 CONV           439@191:1x20x20x96,199@const:96x3x3x96,123@const:96 -> 440:1x20x20x96:C2f_19/Bottleneck_0/Conv_cv2 padding=same stride=1x1 fused=0 params=83040
193 SIGMOID        440@192:1x20x20x96 -> 441:1x20x20x96:C2f_19/Bottleneck_0/Conv_cv2
194 MUL            440@192:1x20x20x96,441@193:1x20x20x96 -> 442:1x20x20x96:C2f_19/Bottleneck_0/Conv_cv2
195 SLICE          435@187:1x20x20x192,141@const:4=[0, 0, 0, 0],125@const:4=[1, 20, 20, 96] -> 443:1x20x20x96:C2f_19
196 CAT            443@195:1x20x20x96,436@188:1x20x20x96,442@194:1x20x20x96 -> 444:1x20x20x288:C2f_19 opts=[(0, 3)]
197 CONV           444@196:1x20x20x288,198@const:192x1x1x288,122@const:192 -> 445:1x20x20x192:C2f_19/Conv_cv2 padding=valid stride=1x1 fused=0 params=55488
198 SIGMOID        445@197:1x20x20x192 -> 446:1x20x20x192:C2f_19/Conv_cv2
199 MUL            445@197:1x20x20x192,446@198:1x20x20x192 -> 447:1x20x20x192:C2f_19/Conv_cv2
200 CONV           407@159:1x80x80x48,197@const:64x3x3x48,121@const:64 -> 448:1x80x80x64:Segment_20/Sequential_0/Conv_0 padding=same stride=1x1 fused=0 params=27712
201 SIGMOID        448@200:1x80x80x64 -> 449:1x80x80x64:Segment_20/Sequential_0/Conv_0
202 MUL            448@200:1x80x80x64,449@201:1x80x80x64 -> 450:1x80x80x64:Segment_20/Sequential_0/Conv_0
203 CONV           450@202:1x80x80x64,196@const:64x3x3x64,120@const:64 -> 451:1x80x80x64:Segment_20/Sequential_0/Conv_1 padding=same stride=1x1 fused=0 params=36928
204 SIGMOID        451@203:1x80x80x64 -> 452:1x80x80x64:Segment_20/Sequential_0/Conv_1
205 MUL            451@203:1x80x80x64,452@204:1x80x80x64 -> 453:1x80x80x64:Segment_20/Sequential_0/Conv_1
206 CONV           453@205:1x80x80x64,195@const:64x1x1x64,119@const:64 -> 454:1x80x80x64:Segment_20/Sequential_0 padding=valid stride=1x1 fused=0 params=4160
207 TRANSPOSE      454@206:1x80x80x64,243@const:4=[0, 3, 1, 2] -> 455:1x64x80x80:Segment_20/Sequential_0
208 RESHAPE        455@207:1x64x80x80,194@const:3=[1, 64, 6400] -> 456:1x64x6400:Segment_20
209 CONV           427@179:1x40x40x96,193@const:64x3x3x96,118@const:64 -> 457:1x40x40x64:Segment_20/Sequential_1/Conv_0 padding=same stride=1x1 fused=0 params=55360
210 SIGMOID        457@209:1x40x40x64 -> 458:1x40x40x64:Segment_20/Sequential_1/Conv_0
211 MUL            457@209:1x40x40x64,458@210:1x40x40x64 -> 459:1x40x40x64:Segment_20/Sequential_1/Conv_0
212 CONV           459@211:1x40x40x64,192@const:64x3x3x64,117@const:64 -> 460:1x40x40x64:Segment_20/Sequential_1/Conv_1 padding=same stride=1x1 fused=0 params=36928
213 SIGMOID        460@212:1x40x40x64 -> 461:1x40x40x64:Segment_20/Sequential_1/Conv_1
214 MUL            460@212:1x40x40x64,461@213:1x40x40x64 -> 462:1x40x40x64:Segment_20/Sequential_1/Conv_1
215 CONV           462@214:1x40x40x64,191@const:64x1x1x64,116@const:64 -> 463:1x40x40x64:Segment_20/Sequential_1 padding=valid stride=1x1 fused=0 params=4160
216 TRANSPOSE      463@215:1x40x40x64,243@const:4=[0, 3, 1, 2] -> 464:1x64x40x40:Segment_20/Sequential_1
217 RESHAPE        464@216:1x64x40x40,190@const:3=[1, 64, 1600] -> 465:1x64x1600:Segment_20
218 CONV           447@199:1x20x20x192,189@const:64x3x3x192,115@const:64 -> 466:1x20x20x64:Segment_20/Sequential_2/Conv_0 padding=same stride=1x1 fused=0 params=110656
219 SIGMOID        466@218:1x20x20x64 -> 467:1x20x20x64:Segment_20/Sequential_2/Conv_0
220 MUL            466@218:1x20x20x64,467@219:1x20x20x64 -> 468:1x20x20x64:Segment_20/Sequential_2/Conv_0
221 CONV           468@220:1x20x20x64,188@const:64x3x3x64,114@const:64 -> 469:1x20x20x64:Segment_20/Sequential_2/Conv_1 padding=same stride=1x1 fused=0 params=36928
222 SIGMOID        469@221:1x20x20x64 -> 470:1x20x20x64:Segment_20/Sequential_2/Conv_1
223 MUL            469@221:1x20x20x64,470@222:1x20x20x64 -> 471:1x20x20x64:Segment_20/Sequential_2/Conv_1
224 CONV           471@223:1x20x20x64,187@const:64x1x1x64,113@const:64 -> 472:1x20x20x64:Segment_20/Sequential_2 padding=valid stride=1x1 fused=0 params=4160
225 TRANSPOSE      472@224:1x20x20x64,243@const:4=[0, 3, 1, 2] -> 473:1x64x20x20:Segment_20/Sequential_2
226 RESHAPE        473@225:1x64x20x20,186@const:3=[1, 64, 400] -> 474:1x64x400:Segment_20
227 CAT            456@208:1x64x6400,465@217:1x64x1600,474@226:1x64x400 -> 475:1x64x8400:Segment_20 opts=[(0, 2)]
228 CONV           407@159:1x80x80x48,185@const:48x3x3x48,112@const:48 -> 476:1x80x80x48:Segment_20/Sequential_0/Conv_0 padding=same stride=1x1 fused=0 params=20784
229 SIGMOID        476@228:1x80x80x48 -> 477:1x80x80x48:Segment_20/Sequential_0/Conv_0
230 MUL            476@228:1x80x80x48,477@229:1x80x80x48 -> 478:1x80x80x48:Segment_20/Sequential_0/Conv_0
231 CONV           478@230:1x80x80x48,184@const:48x3x3x48,111@const:48 -> 479:1x80x80x48:Segment_20/Sequential_0/Conv_1 padding=same stride=1x1 fused=0 params=20784
232 SIGMOID        479@231:1x80x80x48 -> 480:1x80x80x48:Segment_20/Sequential_0/Conv_1
233 MUL            479@231:1x80x80x48,480@232:1x80x80x48 -> 481:1x80x80x48:Segment_20/Sequential_0/Conv_1
234 CONV           481@233:1x80x80x48,183@const:3x1x1x48,110@const:3 -> 482:1x80x80x3:Segment_20/Sequential_0 padding=valid stride=1x1 fused=0 params=147
235 TRANSPOSE      482@234:1x80x80x3,243@const:4=[0, 3, 1, 2] -> 483:1x3x80x80:Segment_20/Sequential_0
236 RESHAPE        483@235:1x3x80x80,182@const:3=[1, 3, 6400] -> 484:1x3x6400:Segment_20
237 CONV           427@179:1x40x40x96,181@const:48x3x3x96,109@const:48 -> 485:1x40x40x48:Segment_20/Sequential_1/Conv_0 padding=same stride=1x1 fused=0 params=41520
238 SIGMOID        485@237:1x40x40x48 -> 486:1x40x40x48:Segment_20/Sequential_1/Conv_0
239 MUL            485@237:1x40x40x48,486@238:1x40x40x48 -> 487:1x40x40x48:Segment_20/Sequential_1/Conv_0
240 CONV           487@239:1x40x40x48,180@const:48x3x3x48,108@const:48 -> 488:1x40x40x48:Segment_20/Sequential_1/Conv_1 padding=same stride=1x1 fused=0 params=20784
241 SIGMOID        488@240:1x40x40x48 -> 489:1x40x40x48:Segment_20/Sequential_1/Conv_1
242 MUL            488@240:1x40x40x48,489@241:1x40x40x48 -> 490:1x40x40x48:Segment_20/Sequential_1/Conv_1
243 CONV           490@242:1x40x40x48,179@const:3x1x1x48,107@const:3 -> 491:1x40x40x3:Segment_20/Sequential_1 padding=valid stride=1x1 fused=0 params=147
244 TRANSPOSE      491@243:1x40x40x3,243@const:4=[0, 3, 1, 2] -> 492:1x3x40x40:Segment_20/Sequential_1
245 RESHAPE        492@244:1x3x40x40,178@const:3=[1, 3, 1600] -> 493:1x3x1600:Segment_20
246 CONV           447@199:1x20x20x192,177@const:48x3x3x192,106@const:48 -> 494:1x20x20x48:Segment_20/Sequential_2/Conv_0 padding=same stride=1x1 fused=0 params=82992
247 SIGMOID        494@246:1x20x20x48 -> 495:1x20x20x48:Segment_20/Sequential_2/Conv_0
248 MUL            494@246:1x20x20x48,495@247:1x20x20x48 -> 496:1x20x20x48:Segment_20/Sequential_2/Conv_0
249 CONV           496@248:1x20x20x48,176@const:48x3x3x48,105@const:48 -> 497:1x20x20x48:Segment_20/Sequential_2/Conv_1 padding=same stride=1x1 fused=0 params=20784
250 SIGMOID        497@249:1x20x20x48 -> 498:1x20x20x48:Segment_20/Sequential_2/Conv_1
251 MUL            497@249:1x20x20x48,498@250:1x20x20x48 -> 499:1x20x20x48:Segment_20/Sequential_2/Conv_1
252 CONV           499@251:1x20x20x48,175@const:3x1x1x48,104@const:3 -> 500:1x20x20x3:Segment_20/Sequential_2 padding=valid stride=1x1 fused=0 params=147
253 TRANSPOSE      500@252:1x20x20x3,243@const:4=[0, 3, 1, 2] -> 501:1x3x20x20:Segment_20/Sequential_2
254 RESHAPE        501@253:1x3x20x20,174@const:3=[1, 3, 400] -> 502:1x3x400:Segment_20
255 CAT            484@236:1x3x6400,493@245:1x3x1600,502@254:1x3x400 -> 503:1x3x8400:Segment_20 opts=[(0, 2)]
256 CONV           407@159:1x80x80x48,173@const:32x3x3x48,103@const:32 -> 504:1x80x80x32:Segment_20/Sequential_0/Conv_0 padding=same stride=1x1 fused=0 params=13856
257 SIGMOID        504@256:1x80x80x32 -> 505:1x80x80x32:Segment_20/Sequential_0/Conv_0
258 MUL            504@256:1x80x80x32,505@257:1x80x80x32 -> 506:1x80x80x32:Segment_20/Sequential_0/Conv_0
259 CONV           506@258:1x80x80x32,172@const:32x3x3x32,102@const:32 -> 507:1x80x80x32:Segment_20/Sequential_0/Conv_1 padding=same stride=1x1 fused=0 params=9248
260 SIGMOID        507@259:1x80x80x32 -> 508:1x80x80x32:Segment_20/Sequential_0/Conv_1
261 MUL            507@259:1x80x80x32,508@260:1x80x80x32 -> 509:1x80x80x32:Segment_20/Sequential_0/Conv_1
262 CONV           509@261:1x80x80x32,171@const:32x1x1x32,101@const:32 -> 510:1x80x80x32:Segment_20/Sequential_0 padding=valid stride=1x1 fused=0 params=1056
263 TRANSPOSE      510@262:1x80x80x32,243@const:4=[0, 3, 1, 2] -> 511:1x32x80x80:Segment_20/Sequential_0
264 RESHAPE        511@263:1x32x80x80,170@const:3=[1, 32, 6400] -> 512:1x32x6400:Segment_20
265 CONV           427@179:1x40x40x96,169@const:32x3x3x96,100@const:32 -> 513:1x40x40x32:Segment_20/Sequential_1/Conv_0 padding=same stride=1x1 fused=0 params=27680
266 SIGMOID        513@265:1x40x40x32 -> 514:1x40x40x32:Segment_20/Sequential_1/Conv_0
267 MUL            513@265:1x40x40x32,514@266:1x40x40x32 -> 515:1x40x40x32:Segment_20/Sequential_1/Conv_0
268 CONV           515@267:1x40x40x32,168@const:32x3x3x32,99@const:32 -> 516:1x40x40x32:Segment_20/Sequential_1/Conv_1 padding=same stride=1x1 fused=0 params=9248
269 SIGMOID        516@268:1x40x40x32 -> 517:1x40x40x32:Segment_20/Sequential_1/Conv_1
270 MUL            516@268:1x40x40x32,517@269:1x40x40x32 -> 518:1x40x40x32:Segment_20/Sequential_1/Conv_1
271 CONV           518@270:1x40x40x32,167@const:32x1x1x32,98@const:32 -> 519:1x40x40x32:Segment_20/Sequential_1 padding=valid stride=1x1 fused=0 params=1056
272 TRANSPOSE      519@271:1x40x40x32,243@const:4=[0, 3, 1, 2] -> 520:1x32x40x40:Segment_20/Sequential_1
273 RESHAPE        520@272:1x32x40x40,166@const:3=[1, 32, 1600] -> 521:1x32x1600:Segment_20
274 CONV           447@199:1x20x20x192,165@const:32x3x3x192,97@const:32 -> 522:1x20x20x32:Segment_20/Sequential_2/Conv_0 padding=same stride=1x1 fused=0 params=55328
275 SIGMOID        522@274:1x20x20x32 -> 523:1x20x20x32:Segment_20/Sequential_2/Conv_0
276 MUL            522@274:1x20x20x32,523@275:1x20x20x32 -> 524:1x20x20x32:Segment_20/Sequential_2/Conv_0
277 CONV           524@276:1x20x20x32,164@const:32x3x3x32,96@const:32 -> 525:1x20x20x32:Segment_20/Sequential_2/Conv_1 padding=same stride=1x1 fused=0 params=9248
278 SIGMOID        525@277:1x20x20x32 -> 526:1x20x20x32:Segment_20/Sequential_2/Conv_1
279 MUL            525@277:1x20x20x32,526@278:1x20x20x32 -> 527:1x20x20x32:Segment_20/Sequential_2/Conv_1
280 CONV           527@279:1x20x20x32,163@const:32x1x1x32,95@const:32 -> 528:1x20x20x32:Segment_20/Sequential_2 padding=valid stride=1x1 fused=0 params=1056
281 TRANSPOSE      528@280:1x20x20x32,243@const:4=[0, 3, 1, 2] -> 529:1x32x20x20:Segment_20/Sequential_2
282 RESHAPE        529@281:1x32x20x20,162@const:3=[1, 32, 400] -> 530:1x32x400:Segment_20
283 CAT            512@264:1x32x6400,521@273:1x32x1600,530@282:1x32x400 -> 531:1x32x8400:Segment_20 opts=[(0, 2)]
284 RESHAPE        475@227:1x64x8400,161@const:4=[1, 4, 16, 8400] -> 532:1x4x16x8400:Segment_20/DFL_dfl
285 TRANSPOSE      532@284:1x4x16x8400,160@const:4=[0, 1, 3, 2] -> 533:1x4x8400x16:Segment_20/DFL_dfl
286 SOFTMAX        533@285:1x4x8400x16 -> 534:1x4x8400x16:Segment_20/DFL_dfl opts=[]
287 CONV           534@286:1x4x8400x16,159@const:1x1x1x16,241@const:1 -> 535:1x4x8400x1:Segment_20/DFL_dfl padding=valid stride=1x1 fused=0 params=17
288 RESHAPE        535@287:1x4x8400x1,240@const:3=[1, 4, 8400] -> 536:1x4x8400:Segment_20/DFL_dfl
289 SLICE          536@288:1x4x8400,94@const:3=[0, 0, 0],93@const:3=[1, 2, 8400] -> 537:1x2x8400:Segment_20
290 SLICE          536@288:1x4x8400,92@const:3=[0, 2, 0],93@const:3=[1, 2, 8400] -> 538:1x2x8400:Segment_20
291 SUB            247@const:1x2x8400,537@289:1x2x8400 -> 539:1x2x8400:Segment_20
292 ADD            538@290:1x2x8400,247@const:1x2x8400 -> 540:1x2x8400:Segment_20
293 ADD            539@291:1x2x8400,540@292:1x2x8400 -> 541:1x2x8400:Segment_20
294 MUL            541@293:1x2x8400,91@const:s=[0.5] -> 542:1x2x8400:Segment_20
295 SUB            540@292:1x2x8400,539@291:1x2x8400 -> 543:1x2x8400:Segment_20
296 CAT            542@294:1x2x8400,543@295:1x2x8400 -> 544:1x4x8400:Segment_20 opts=[(0, 1)]
297 MUL            544@296:1x4x8400,246@const:1x1x8400 -> 545:1x4x8400:Segment_20
298 SIGMOID        503@255:1x3x8400 -> 546:1x3x8400:Segment_20
299 CONV           407@159:1x80x80x48,158@const:128x3x3x48,90@const:128 -> 547:1x80x80x128:Segment_20/Proto_proto/Conv_cv1 padding=same stride=1x1 fused=0 params=55424
300 SIGMOID        547@299:1x80x80x128 -> 548:1x80x80x128:Segment_20/Proto_proto/Conv_cv1
301 MUL            547@299:1x80x80x128,548@300:1x80x80x128 -> 549:1x80x80x128:Segment_20/Proto_proto/Conv_cv1
302 TCONV          239@const:4=[1, 160, 160, 128],157@const:128x2x2x128,549@301:1x80x80x128,89@const:128 -> 550:1x160x160x128:Segment_20/Proto_proto padding=valid stride=2x2 fused=0 params=65664
303 CONV           550@302:1x160x160x128,156@const:128x3x3x128,88@const:128 -> 551:1x160x160x128:Segment_20/Proto_proto/Conv_cv2 padding=same stride=1x1 fused=0 params=147584
304 SIGMOID        551@303:1x160x160x128 -> 552:1x160x160x128:Segment_20/Proto_proto/Conv_cv2
305 MUL            551@303:1x160x160x128,552@304:1x160x160x128 -> 553:1x160x160x128:Segment_20/Proto_proto/Conv_cv2
306 CONV           553@305:1x160x160x128,155@const:32x1x1x128,87@const:32 -> 554:1x160x160x32:Segment_20/Proto_proto/Conv_cv3 padding=valid stride=1x1 fused=0 params=4128
307 SIGMOID        554@306:1x160x160x32 -> 555:1x160x160x32:Segment_20/Proto_proto/Conv_cv3
308 MUL            554@306:1x160x160x32,555@307:1x160x160x32 -> 556:1x160x160x32:Segment_20/Proto_proto/Conv_cv3
309 MUL            545@297:1x4x8400,86@const:s=[0.0015625] -> 557:1x4x8400:
310 CAT            557@309:1x4x8400,546@298:1x3x8400,531@283:1x32x8400 -> 558:1x39x8400: opts=[(0, 1)]
311 TRANSPOSE      556@308:1x160x160x32,243@const:4=[0, 3, 1, 2] -> 559:1x32x160x160:
~~~

</details>
