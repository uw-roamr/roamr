#!/usr/bin/env python3
"""Export a PyTorch detection model to ExecuTorch .pte plus manifest.json.

The runtime bridge in ROAMR expects a fixed output tensor of shape [N, 6]:

    [class_id, score, x_min, y_min, x_max, y_max]

Coordinates are normalized to [0, 1] in image space.

Typical usage for a custom model factory:

    .venv/bin/python executorch_export.py \
      --factory my_model:build_model \
      --checkpoint /path/to/checkpoint.pt \
      --adapter identity \
      --image-size 640 \
      --output-dir ../stop_sign_bundle

Typical usage for a torchvision detector checkpoint:

    .venv/bin/python executorch_export.py \
      --torchvision-model ssdlite320_mobilenet_v3_large \
      --checkpoint /path/to/checkpoint.pt \
      --num-classes 12 \
      --adapter ssd-export-friendly \
      --image-size 320 \
      --output-dir ../stop_sign_bundle
"""

from __future__ import annotations

import argparse
import importlib
import inspect
import json
import os
import shutil
from collections import OrderedDict
from pathlib import Path
from typing import Any, Callable

import torch
import torch.nn as nn
import torch.nn.functional as F
import torchvision
from executorch.backends.xnnpack.partition.xnnpack_partitioner import XnnpackPartitioner
from executorch.extension.export_util.utils import export_to_edge, save_pte_program
from torchvision.ops import boxes as box_ops


SUPPORTED_TORCHVISION_MODELS: dict[str, Callable[..., nn.Module]] = {
    "ssdlite320_mobilenet_v3_large": torchvision.models.detection.ssdlite320_mobilenet_v3_large,
    "fasterrcnn_resnet50_fpn_v2": torchvision.models.detection.fasterrcnn_resnet50_fpn_v2,
}

SUPPORTED_TORCHVISION_WEIGHT_ENUMS: dict[str, type] = {
    "ssdlite320_mobilenet_v3_large": torchvision.models.detection.SSDLite320_MobileNet_V3_Large_Weights,
    "fasterrcnn_resnet50_fpn_v2": torchvision.models.detection.FasterRCNN_ResNet50_FPN_V2_Weights,
}

SUPPORTED_TORCHVISION_BACKBONE_WEIGHT_ENUMS: dict[str, type] = {
    "ssdlite320_mobilenet_v3_large": torchvision.models.MobileNet_V3_Large_Weights,
    "fasterrcnn_resnet50_fpn_v2": torchvision.models.ResNet50_Weights,
}


class ExportError(RuntimeError):
    pass


class TorchvisionDetectionAdapter(nn.Module):
    """Convert torchvision detection outputs to a fixed [max_detections, 6] tensor."""

    def __init__(self, detector: nn.Module, max_detections: int) -> None:
        super().__init__()
        self.detector = detector
        self.max_detections = max_detections

    def forward(self, batched_rgb: torch.Tensor) -> torch.Tensor:
        if batched_rgb.dim() != 4 or batched_rgb.shape[0] != 1:
            raise RuntimeError("expected input shape [1, 3, H, W]")

        _, _, height, width = batched_rgb.shape
        detections = self.detector([batched_rgb[0]])[0]

        scores = detections["scores"][: self.max_detections].to(dtype=torch.float32)
        labels = detections["labels"][: self.max_detections].to(dtype=torch.float32)
        boxes = detections["boxes"][: self.max_detections].to(dtype=torch.float32)

        scale = torch.tensor(
            [float(width), float(height), float(width), float(height)],
            dtype=boxes.dtype,
            device=boxes.device,
        )
        normalized_boxes = boxes / scale

        rows = torch.cat(
            (labels.unsqueeze(1), scores.unsqueeze(1), normalized_boxes),
            dim=1,
        )

        output = batched_rgb.new_zeros((self.max_detections, 6), dtype=torch.float32)
        output[: rows.shape[0], :] = rows
        return output


class IdentityDetectionAdapter(nn.Module):
    """Pass through a model that already returns [N, 6] or [1, N, 6]."""

    def __init__(self, model: nn.Module, max_detections: int) -> None:
        super().__init__()
        self.model = model
        self.max_detections = max_detections

    def forward(self, batched_rgb: torch.Tensor) -> torch.Tensor:
        raw = self.model(batched_rgb)
        if isinstance(raw, (list, tuple)):
            raw = raw[0]
        if not isinstance(raw, torch.Tensor):
            raise RuntimeError("identity adapter requires tensor output")
        if raw.dim() == 3 and raw.shape[0] == 1:
            raw = raw[0]
        if raw.dim() != 2 or raw.shape[1] != 6:
            raise RuntimeError("identity adapter requires output shape [N, 6] or [1, N, 6]")

        raw = raw.to(dtype=torch.float32)
        output = batched_rgb.new_zeros((self.max_detections, 6), dtype=torch.float32)
        row_count = min(int(raw.shape[0]), self.max_detections)
        output[:row_count, :] = raw[:row_count, :]
        return output


class SSDTorchvisionExportAdapter(nn.Module):
    """Export-friendly SSD postprocess with fixed-shape top-k and greedy class-aware NMS."""

    def __init__(
        self,
        detector: nn.Module,
        max_detections: int,
        pre_nms_topk: int | None = None,
    ) -> None:
        super().__init__()
        self.detector = detector
        self.max_detections = max_detections
        detector_topk = int(getattr(detector, "topk_candidates", max_detections))
        self.pre_nms_topk = min(
            detector_topk,
            pre_nms_topk if pre_nms_topk is not None else max(max_detections * 2, 64),
        )
        self.score_threshold = float(getattr(detector, "score_thresh", 0.01))
        self.nms_threshold = float(getattr(detector, "nms_thresh", 0.45))

    def _greedy_class_aware_nms(
        self,
        boxes: torch.Tensor,
        scores: torch.Tensor,
        labels: torch.Tensor,
    ) -> torch.Tensor:
        count = scores.shape[0]
        suppressed = torch.zeros_like(scores, dtype=torch.bool)
        selected = torch.zeros_like(scores, dtype=torch.bool)

        x1 = boxes[:, 0]
        y1 = boxes[:, 1]
        x2 = boxes[:, 2]
        y2 = boxes[:, 3]
        areas = (x2 - x1).clamp(min=0) * (y2 - y1).clamp(min=0)

        for i in range(count):
            keep_current = (~suppressed[i]) & (scores[i] > 0)
            selected = selected.clone()
            selected[i] = keep_current
            if i + 1 >= count:
                continue

            xx1 = torch.maximum(x1[i], x1[i + 1 :])
            yy1 = torch.maximum(y1[i], y1[i + 1 :])
            xx2 = torch.minimum(x2[i], x2[i + 1 :])
            yy2 = torch.minimum(y2[i], y2[i + 1 :])

            inter_w = (xx2 - xx1).clamp(min=0)
            inter_h = (yy2 - yy1).clamp(min=0)
            inter = inter_w * inter_h
            union = areas[i] + areas[i + 1 :] - inter
            iou = torch.where(union > 0, inter / union, torch.zeros_like(inter))
            same_label = labels[i + 1 :] == labels[i]
            should_suppress = keep_current & same_label & (iou > self.nms_threshold)
            suppressed = torch.cat((suppressed[: i + 1], suppressed[i + 1 :] | should_suppress), dim=0)

        return selected

    def forward(self, batched_rgb: torch.Tensor) -> torch.Tensor:
        if batched_rgb.dim() != 4 or batched_rgb.shape[0] != 1:
            raise RuntimeError("expected input shape [1, 3, H, W]")

        images, _ = self.detector.transform([batched_rgb[0]], None)
        features = self.detector.backbone(images.tensors)
        if isinstance(features, torch.Tensor):
            features = OrderedDict([("0", features)])
        feature_list = list(features.values())

        head_outputs = self.detector.head(feature_list)
        anchors = self.detector.anchor_generator(images, feature_list)

        boxes = self.detector.box_coder.decode_single(head_outputs["bbox_regression"][0], anchors[0])
        boxes = box_ops.clip_boxes_to_image(boxes, images.image_sizes[0])

        scores = F.softmax(head_outputs["cls_logits"][0], dim=-1)[:, 1:]
        scores = torch.where(scores >= self.score_threshold, scores, torch.zeros_like(scores))

        flat_scores = scores.reshape(-1)
        top_scores, top_indices = torch.topk(
            flat_scores,
            k=self.pre_nms_topk,
            largest=True,
            sorted=True,
        )

        num_foreground_classes = scores.shape[1]
        anchor_indices = torch.div(top_indices, num_foreground_classes, rounding_mode="floor")
        label_indices = torch.remainder(top_indices, num_foreground_classes) + 1

        top_boxes = boxes.index_select(0, anchor_indices)
        keep = self._greedy_class_aware_nms(top_boxes, top_scores, label_indices)
        selected_scores = torch.where(keep, top_scores, torch.zeros_like(top_scores))

        final_scores, final_order = torch.topk(
            selected_scores,
            k=self.max_detections,
            largest=True,
            sorted=True,
        )
        final_boxes = top_boxes.index_select(0, final_order)
        final_labels = label_indices.index_select(0, final_order).to(dtype=torch.float32)

        valid = final_scores > 0
        final_scores = final_scores * valid.to(dtype=final_scores.dtype)
        final_labels = final_labels * valid.to(dtype=torch.float32)

        _, _, height, width = batched_rgb.shape
        scale = torch.tensor(
            [float(width), float(height), float(width), float(height)],
            dtype=final_boxes.dtype,
            device=final_boxes.device,
        )
        final_boxes = (final_boxes / scale) * valid.unsqueeze(1).to(dtype=final_boxes.dtype)

        return torch.cat(
            (final_labels.unsqueeze(1), final_scores.unsqueeze(1), final_boxes),
            dim=1,
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument(
        "--factory",
        help="Python factory in module:callable form that returns an nn.Module.",
    )
    source.add_argument(
        "--torchvision-model",
        choices=sorted(SUPPORTED_TORCHVISION_MODELS.keys()),
        help="Built-in torchvision detection model constructor.",
    )
    parser.add_argument("--checkpoint", help="Optional checkpoint to load into the model.")
    parser.add_argument(
        "--checkpoint-key",
        default="state_dict",
        help="Key to read from checkpoint dictionaries. Use '' to disable keyed lookup.",
    )
    parser.add_argument(
        "--adapter",
        choices=("identity", "torchvision-detection", "ssd-export-friendly"),
        help="Output adapter. Defaults to ssd-export-friendly for ssdlite, torchvision-detection for other torchvision detectors, identity otherwise.",
    )
    parser.add_argument(
        "--torchvision-weights",
        choices=("none", "default"),
        default="none",
        help="Official torchvision detector weights. Use 'default' for COCO-pretrained detector weights.",
    )
    parser.add_argument(
        "--torchvision-backbone-weights",
        choices=("none", "default"),
        default="none",
        help="Official torchvision backbone weights. Use 'default' for ImageNet-pretrained backbone weights.",
    )
    parser.add_argument("--num-classes", type=int, help="Class count for torchvision model construction.")
    parser.add_argument("--image-size", type=int, default=640, help="Square RGB input size.")
    parser.add_argument("--max-detections", type=int, default=32, help="Rows in exported detection tensor.")
    parser.add_argument(
        "--backend",
        choices=("xnnpack", "portable"),
        default="xnnpack",
        help="ExecuTorch lowering backend. portable skips XNNPACK lowering.",
    )
    parser.add_argument(
        "--output-dir",
        default="../stop_sign_bundle",
        help="Directory where model.pte and manifest.json will be written.",
    )
    parser.add_argument(
        "--model-name",
        default="model",
        help="Base filename for the .pte output. 'model' produces model.pte.",
    )
    parser.add_argument("--manifest-name", default="manifest.json")
    parser.add_argument("--score-threshold", type=float, default=0.8)
    parser.add_argument(
        "--pre-nms-topk",
        type=int,
        help="Export-friendly SSD adapter candidate count before greedy NMS.",
    )
    parser.add_argument("--method", default="forward")
    parser.add_argument("--strict", action="store_true", help="Use strict torch.export mode.")
    parser.add_argument("--verbose", action="store_true", help="Print ExecuTorch export verbosity.")
    return parser.parse_args()


def load_factory(spec: str) -> Callable[..., Any]:
    if ":" not in spec:
        raise ExportError("--factory must be in module:callable form")
    module_name, attr_name = spec.split(":", 1)
    module = importlib.import_module(module_name)
    factory = getattr(module, attr_name, None)
    if factory is None or not callable(factory):
        raise ExportError(f"factory {spec!r} not found or not callable")
    return factory


def build_model(args: argparse.Namespace) -> nn.Module:
    if args.torchvision_model:
        model_name = args.torchvision_model
        weights = None
        if args.torchvision_weights == "default":
            weights = SUPPORTED_TORCHVISION_WEIGHT_ENUMS[model_name].DEFAULT
        weights_backbone = None
        if args.torchvision_backbone_weights == "default":
            weights_backbone = SUPPORTED_TORCHVISION_BACKBONE_WEIGHT_ENUMS[model_name].DEFAULT

        if weights is not None and args.num_classes is not None:
            category_count = len(weights.meta.get("categories", []))
            if category_count and args.num_classes != category_count:
                raise ExportError(
                    "--torchvision-weights default uses the pretrained detector head. "
                    f"Omit --num-classes or set it to {category_count}. "
                    "For custom class counts, use --torchvision-backbone-weights default with your checkpoint."
                )

        kwargs: dict[str, Any] = {"weights": weights, "weights_backbone": weights_backbone}
        if args.num_classes is not None:
            kwargs["num_classes"] = args.num_classes
        model = SUPPORTED_TORCHVISION_MODELS[model_name](**kwargs)
        return model.eval()

    factory = load_factory(args.factory)
    signature = inspect.signature(factory)
    kwargs = {}
    if "num_classes" in signature.parameters and args.num_classes is not None:
        kwargs["num_classes"] = args.num_classes
    model = factory(**kwargs)
    if not isinstance(model, nn.Module):
        raise ExportError("factory must return an nn.Module")
    return model.eval()


def load_checkpoint(model: nn.Module, args: argparse.Namespace) -> None:
    if not args.checkpoint:
        return

    checkpoint = torch.load(args.checkpoint, map_location="cpu")
    state_dict = checkpoint
    if isinstance(checkpoint, dict) and args.checkpoint_key:
        state_dict = checkpoint.get(args.checkpoint_key, checkpoint)
    if not isinstance(state_dict, dict):
        raise ExportError("checkpoint did not resolve to a state_dict dictionary")

    normalized_state_dict = {}
    for key, value in state_dict.items():
        normalized_key = str(key)
        if normalized_key.startswith("model."):
            normalized_key = normalized_key[len("model.") :]
        normalized_state_dict[normalized_key] = value

    missing, unexpected = model.load_state_dict(normalized_state_dict, strict=False)
    if missing:
        print(f"warning: missing checkpoint keys ({len(missing)}): {missing[:8]}")
    if unexpected:
        print(f"warning: unexpected checkpoint keys ({len(unexpected)}): {unexpected[:8]}")


def wrap_model(model: nn.Module, args: argparse.Namespace) -> nn.Module:
    adapter = args.adapter
    if adapter is None:
        if args.torchvision_model == "ssdlite320_mobilenet_v3_large":
            adapter = "ssd-export-friendly"
        else:
            adapter = "torchvision-detection" if args.torchvision_model else "identity"

    if adapter == "torchvision-detection":
        return TorchvisionDetectionAdapter(model, max_detections=args.max_detections).eval()
    if adapter == "ssd-export-friendly":
        return SSDTorchvisionExportAdapter(
            model,
            max_detections=args.max_detections,
            pre_nms_topk=args.pre_nms_topk,
        ).eval()
    if adapter == "identity":
        return IdentityDetectionAdapter(model, max_detections=args.max_detections).eval()
    raise ExportError(f"unsupported adapter {adapter}")


def ensure_flatc_available() -> None:
    flatc = os.getenv("FLATC_EXECUTABLE") or shutil.which("flatc")
    if flatc:
        return
    raise ExportError(
        "flatc is required to serialize ExecuTorch .pte files. "
        "Install FlatBuffers (for example `brew install flatbuffers`) and ensure `flatc` "
        "is on PATH, or set FLATC_EXECUTABLE=/absolute/path/to/flatc."
    )


def export_pte(model: nn.Module, args: argparse.Namespace, output_dir: Path) -> Path:
    ensure_flatc_available()

    example_input = torch.rand(1, 3, args.image_size, args.image_size, dtype=torch.float32)
    edge_program = export_to_edge(
        model,
        (example_input,),
        strict=args.strict,
        verbose=args.verbose,
    )

    if args.backend == "xnnpack":
        edge_program = edge_program.to_backend(XnnpackPartitioner())

    executorch_program = edge_program.to_executorch()
    pte_path = Path(save_pte_program(executorch_program, args.model_name, output_dir=str(output_dir)))
    return pte_path


def write_manifest(args: argparse.Namespace, output_dir: Path, pte_path: Path) -> Path:
    manifest = {
        "name": args.model_name,
        "task": "object_detection",
        "backend": "executorch",
        "delegate": None if args.backend == "portable" else args.backend,
        "method": args.method,
        "model_file": pte_path.name,
        "score_threshold": float(args.score_threshold),
        "input": {
            "width": int(args.image_size),
            "height": int(args.image_size),
            "channels": 3,
            "resize_mode": "stretch",
            "value_scale": 1.0 / 255.0,
            "mean": [0.0, 0.0, 0.0],
            "std": [1.0, 1.0, 1.0],
        },
        "output": {
            "elements_per_detection": 6,
            "max_detections": int(args.max_detections),
            "normalized_boxes": True,
        },
    }
    manifest_path = output_dir / args.manifest_name
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest_path


def main() -> int:
    args = parse_args()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    model = build_model(args)
    load_checkpoint(model, args)
    export_model = wrap_model(model, args)

    pte_path = export_pte(export_model, args, output_dir)
    manifest_path = write_manifest(args, output_dir, pte_path)

    print(f"wrote {pte_path}")
    print(f"wrote {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
