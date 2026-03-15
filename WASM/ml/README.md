## ExecuTorch Export

`executorch_export.py` exports a PyTorch detection model to:

- `model.pte`
- `manifest.json`

The exported model contract matches the current ROAMR ML bridge:

- input: fixed `[1, 3, H, W]` RGB tensor
- output: fixed `[max_detections, 6]` tensor
- row layout: `class_id, score, x_min, y_min, x_max, y_max`
- box coordinates normalized to `[0, 1]`

### Prereqs

The local virtualenv already has `torch`, `torchvision`, and `executorch`.
You still need the FlatBuffers compiler to serialize `.pte` files:

```sh
brew install flatbuffers
```

If `flatc` is not on `PATH`, set:

```sh
export FLATC_EXECUTABLE=/absolute/path/to/flatc
```

### Custom Model Factory

If you already have a Python module that builds your model:

```sh
cd WASM/ml
.venv/bin/python executorch_export.py \
  --factory my_model:build_model \
  --checkpoint /path/to/checkpoint.pt \
  --adapter identity \
  --image-size 640 \
  --output-dir ../stop_sign_bundle
```

Use `--adapter identity` when your model already returns `[N, 6]` or `[1, N, 6]`.

### Torchvision Detector

If your checkpoint is based on a torchvision detector:

```sh
cd WASM/ml
.venv/bin/python executorch_export.py \
  --torchvision-model ssdlite320_mobilenet_v3_large \
  --checkpoint /path/to/checkpoint.pt \
  --num-classes 12 \
  --adapter ssd-export-friendly \
  --image-size 320 \
  --output-dir ../stop_sign_bundle
```

The exporter wraps the detector output into the fixed ROAMR detection tensor and
writes a matching manifest.

For `ssdlite320_mobilenet_v3_large`, `ssd-export-friendly` replaces torchvision's
dynamic postprocess with fixed-shape top-k selection and greedy class-aware NMS
so the model can export cleanly through `torch.export`/ExecuTorch. You can tune
the candidate count before NMS with `--pre-nms-topk` if needed.

To export the stock COCO-pretrained detector without a checkpoint:

```sh
cd WASM/ml
.venv/bin/python executorch_export.py \
  --torchvision-model ssdlite320_mobilenet_v3_large \
  --torchvision-weights default \
  --image-size 320 \
  --output-dir ../stop_sign_bundle
```

If you are exporting a custom-class checkpoint and want pretrained backbone
initialization before loading your checkpoint, use:

```sh
cd WASM/ml
.venv/bin/python executorch_export.py \
  --torchvision-model ssdlite320_mobilenet_v3_large \
  --torchvision-backbone-weights default \
  --checkpoint /path/to/checkpoint.pt \
  --num-classes 12 \
  --image-size 320 \
  --output-dir ../stop_sign_bundle
```
