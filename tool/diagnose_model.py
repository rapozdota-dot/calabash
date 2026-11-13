"""Inspect and time the bundled V8 export with a desktop TFLite interpreter."""
import argparse
import json
from pathlib import Path
from time import perf_counter
import zipfile

import cv2
import numpy as np
from PIL import Image, ImageOps

try:
    from ai_edge_litert.interpreter import Interpreter
except ImportError:
    import tensorflow as tf

    Interpreter = tf.lite.Interpreter


INPUT_SIZE = 224
INPUT_SHAPE = (1, 3, INPUT_SIZE, INPUT_SIZE)
DETECTION_SHAPE = (1, 39, 1029)
PROTOTYPE_SHAPE = (1, 32, 56, 56)


def preprocess(image):
    """Use the Ultralytics RGB letterbox and float32 /255 normalization."""
    image = ImageOps.exif_transpose(image).convert("RGB")
    w, h = image.size
    gain = min(INPUT_SIZE / w, INPUT_SIZE / h)
    width, height = (max(1, round(side * gain)) for side in (w, h))
    left = (INPUT_SIZE - width) // 2
    top = (INPUT_SIZE - height) // 2
    canvas = np.full((INPUT_SIZE, INPUT_SIZE, 3), 114, dtype=np.uint8)
    canvas[top:top+height, left:left+width] = cv2.resize(
        np.asarray(image), (width, height), interpolation=cv2.INTER_LINEAR
    )
    tensor = np.ascontiguousarray(canvas.transpose(2, 0, 1)[None], dtype=np.float32)
    return tensor / 255, (w, h, width, height, left, top)


def inspect(interpreter, image, name, out_dir):
    """Report class scores and candidate coordinates before any app threshold."""
    start = perf_counter()
    inp = interpreter.get_input_details()[0]
    tensor, metadata = preprocess(image)
    interpreter.set_tensor(inp["index"], tensor)
    before_invoke = perf_counter()
    interpreter.invoke()
    invoke_ms = (perf_counter() - before_invoke) * 1000
    outputs = {tuple(t["shape"]): interpreter.get_tensor(t["index"])
               for t in interpreter.get_output_details()}
    det = outputs[DETECTION_SHAPE][0]
    proto = outputs[PROTOTYPE_SHAPE]
    if not np.isfinite(det).all() or not np.isfinite(proto).all():
        raise ValueError("Non-finite model output")
    if det[4:7].min() < 0 or det[4:7].max() > 1:
        raise ValueError("Expected probabilities in detection channels 4-6")
    scores = det[4:7].max(axis=0)
    best = np.argsort(scores)[-5:][::-1]
    report = {"name": name, "oriented_size": metadata[:2], "input_shape": tensor.shape,
              "prototype_shape": proto.shape, "invoke_ms": round(invoke_ms, 3),
              "preprocess_invoke_read_ms": round((perf_counter() - start) * 1000, 3),
              "input_range": [float(tensor.min()), float(tensor.max())],
              "above_045": int((scores > .45).sum()), "above_025": int((scores > .25).sum()),
              "top": [{"anchor": int(a), "class": int(det[4:7, a].argmax()),
                       "score": float(scores[a]), "xywh": det[:4, a].tolist(),
                       "coeff_range": [float(det[7:, a].min()), float(det[7:, a].max())]}
                      for a in best]}
    print(json.dumps(report), flush=True)
    if out_dir:
        target = Path(out_dir) / name
        target.mkdir(parents=True, exist_ok=True)
        image.save(target / "image.png")
        tensor.tofile(target / "input.bin")
        det.tofile(target / "detections.bin")
        proto.tofile(target / "prototypes.bin")
        (target / "metadata.json").write_text(json.dumps({"image": metadata, "proto_shape": proto.shape}))


def main():
    """Run user photos or a small validation sample, plus a neutral negative image."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="assets/model/model.tflite")
    parser.add_argument("--dataset")
    parser.add_argument("--image", action="append", default=[])
    parser.add_argument("--out-dir")
    parser.add_argument("--tiles", action="store_true")
    args = parser.parse_args()
    model = Interpreter(model_path=args.model, num_threads=2)
    model.allocate_tensors()
    inputs = model.get_input_details()
    outputs = model.get_output_details()
    if (len(inputs) != 1 or tuple(inputs[0]["shape"]) != INPUT_SHAPE
            or len(outputs) != 2
            or {tuple(t["shape"]) for t in outputs} != {DETECTION_SHAPE, PROTOTYPE_SHAPE}
            or any(t["dtype"] != np.float32 for t in inputs + outputs)):
        raise ValueError(f"Unexpected FP32 V8 signature: {inputs}, {outputs}")
    for name in args.image:
        image = Image.open(name)
        inspect(model, image, Path(name).stem, args.out_dir)
        if args.tiles:
            w, h = image.size
            for scale in (.75, .5, .35):
                side = round(min(w, h) * scale)
                for row in range(3):
                    for col in range(3):
                        left = round((w-side) * col / 2)
                        top = round((h-side) * row / 2)
                        inspect(model, image.crop((left, top, left+side, top+side)),
                                f"tile-{scale}-{row}-{col}", None)
            inspect(model, image.resize((INPUT_SIZE, INPUT_SIZE)), "stretch", None)
            for angle in (90, 180, 270):
                inspect(model, image.rotate(angle, expand=True), f"rotation-{angle}", None)
    if args.dataset:
        with zipfile.ZipFile(args.dataset) as dataset:
            names = [n for n in dataset.namelist() if n.startswith("test/images/")]
            for prefix in ("Ripe", "Unripe", "Overripe", "cucumber"):
                name = next((n for n in names if Path(n).name.lower().startswith(prefix.lower())), None)
                if name is None:
                    continue
                with dataset.open(name) as source:
                    inspect(model, Image.open(source), prefix, args.out_dir)
    inspect(model, Image.new("RGB", (224, 168), (114, 114, 114)), "blank", args.out_dir)


if __name__ == "__main__":
    main()
