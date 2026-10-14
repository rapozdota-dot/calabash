"""Inspect real TFLite outputs without a phone (requires numpy, Pillow, ai-edge-litert)."""
import argparse
import json
from pathlib import Path
import zipfile

import numpy as np
from PIL import Image, ImageOps
from ai_edge_litert.interpreter import Interpreter


def preprocess(image, shape):
    """Match the app's 640-square RGB letterbox and float32 /255 normalization."""
    image = ImageOps.exif_transpose(image).convert("RGB")
    w, h = image.size
    gain = min(640 / w, 640 / h)
    resized = (round(w * gain), round(h * gain))
    left = round((640 - resized[0]) / 2 - 0.1)
    top = round((640 - resized[1]) / 2 - 0.1)
    canvas = Image.new("RGB", (640, 640), (114, 114, 114))
    canvas.paste(image.resize(resized, Image.Resampling.BILINEAR), (left, top))
    array = np.asarray(canvas, dtype=np.float32) / 255
    if shape[1] == 3:
        array = array.transpose(2, 0, 1)
    return np.ascontiguousarray(array[None]), (w, h, gain, left, top)


def inspect(interpreter, image, name, out_dir):
    """Report class scores and candidate coordinates before any app threshold."""
    inp = interpreter.get_input_details()[0]
    tensor, metadata = preprocess(image, inp["shape"])
    interpreter.set_tensor(inp["index"], tensor)
    interpreter.invoke()
    outputs = [interpreter.get_tensor(t["index"]) for t in interpreter.get_output_details()]
    det = next(t for t in outputs if t.shape == (1, 39, 8400))[0]
    proto = next(t for t in outputs if t.shape != (1, 39, 8400))
    scores = det[4:7].max(axis=0)
    best = np.argsort(scores)[-5:][::-1]
    report = {"name": name, "original_size": image.size, "input_shape": tensor.shape,
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
            inspect(model, image.resize((640, 640)), "stretch", None)
            for angle in (90, 180, 270):
                inspect(model, image.rotate(angle, expand=True), f"rotation-{angle}", None)
    if args.dataset:
        with zipfile.ZipFile(args.dataset) as dataset:
            names = [n for n in dataset.namelist() if n.startswith("valid/images/")]
            for prefix in ("Ripe", "Unripe", "Overripe", "cucumber"):
                name = next(n for n in names if Path(n).name.startswith(prefix))
                with dataset.open(name) as source:
                    inspect(model, Image.open(source), prefix, args.out_dir)
    inspect(model, Image.new("RGB", (640, 480), (114, 114, 114)), "blank", args.out_dir)


if __name__ == "__main__":
    main()
