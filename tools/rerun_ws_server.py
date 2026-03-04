# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "rerun-sdk==0.29.1",
#     "websockets",
# ]
# ///

#!/usr/bin/env python3
import argparse
import asyncio
import base64
import json
import signal
import struct
import threading
import time
from collections import deque
from dataclasses import dataclass
from typing import Any, Iterable, Optional

import rerun as rr
import rerun.blueprint as rrb
import websockets

try:
    import numpy as np
except Exception:  # pragma: no cover - keep server runnable without numpy.
    np = None


POINTS_BINARY_MAGIC = b"RRB1"
POINTS_BINARY_TYPE_POINTS = 1
POINTS_BINARY_FLAG_COLORS = 1
POINTS_BINARY_HEADER_SIZE = 20
POINTS_MESSAGE_TYPES = {"points3d", "points3d_bin"}


@dataclass
class PointsMessage:
    timestamp: float
    points: Any
    colors: Optional[Any]


class PipelinePerfWindow:
    def __init__(self, report_interval_s: float = 2.0):
        self.report_interval_s = max(0.5, report_interval_s)
        self.window_start_s = time.perf_counter()

        self.decode_count = 0
        self.decode_total_s = 0.0

        self.route_count = 0
        self.route_total_s = 0.0

        self.points_overwritten = 0
        self.control_dropped = 0

    def observe_decode(self, elapsed_s: float) -> None:
        self.decode_count += 1
        self.decode_total_s += elapsed_s

    def observe_route(self, elapsed_s: float) -> None:
        self.route_count += 1
        self.route_total_s += elapsed_s

    def mark_points_overwritten(self) -> None:
        self.points_overwritten += 1

    def mark_control_dropped(self) -> None:
        self.control_dropped += 1

    def maybe_report(self, control_queue_size: int, has_pending_points: bool) -> None:
        now_s = time.perf_counter()
        elapsed_s = now_s - self.window_start_s
        if elapsed_s < self.report_interval_s:
            return

        decode_avg_ms = (
            (self.decode_total_s / self.decode_count) * 1000.0 if self.decode_count > 0 else 0.0
        )
        route_avg_ms = (
            (self.route_total_s / self.route_count) * 1000.0 if self.route_count > 0 else 0.0
        )
        ingress_rate = self.decode_count / max(elapsed_s, 1e-6)
        route_rate = self.route_count / max(elapsed_s, 1e-6)

        print(
            "[rerun][perf] "
            f"ingress={ingress_rate:.1f}/s "
            f"route={route_rate:.1f}/s "
            f"decode={decode_avg_ms:.3f}ms "
            f"route_log={route_avg_ms:.3f}ms "
            f"q={control_queue_size} "
            f"pending_points={1 if has_pending_points else 0} "
            f"drop_points={self.points_overwritten} "
            f"drop_control={self.control_dropped}"
        )

        self.window_start_s = now_s
        self.decode_count = 0
        self.decode_total_s = 0.0
        self.route_count = 0
        self.route_total_s = 0.0
        self.points_overwritten = 0
        self.control_dropped = 0


def decode_message(message) -> Optional[dict]:
    """Parse JSON payloads from websocket messages.

    Returns None on decode errors so callers can cheaply `continue`.
    """

    if isinstance(message, bytes):
        binary_payload = decode_points_binary_message(message)
        if binary_payload is not None:
            return binary_payload
        try:
            message = message.decode("utf-8")
        except UnicodeDecodeError:
            return None
    try:
        return json.loads(message)
    except json.JSONDecodeError:
        return None


def decode_points_binary_message(message: bytes) -> Optional[dict]:
    if len(message) < POINTS_BINARY_HEADER_SIZE:
        return None
    if message[:4] != POINTS_BINARY_MAGIC:
        return None

    try:
        msg_type, flags, _reserved, timestamp, point_count = struct.unpack_from(
            "<BBHdI", message, 4
        )
    except struct.error:
        return None

    if msg_type != POINTS_BINARY_TYPE_POINTS or point_count <= 0:
        return None

    points_float_count = point_count * 3
    points_byte_count = points_float_count * 4
    has_colors = (flags & POINTS_BINARY_FLAG_COLORS) != 0
    colors_byte_count = point_count * 3 if has_colors else 0
    total_byte_count = POINTS_BINARY_HEADER_SIZE + points_byte_count + colors_byte_count
    if len(message) < total_byte_count:
        return None

    points_offset = POINTS_BINARY_HEADER_SIZE
    colors_offset = points_offset + points_byte_count

    if np is not None:
        points = np.frombuffer(
            message,
            dtype="<f4",
            count=points_float_count,
            offset=points_offset,
        ).reshape((-1, 3))
        colors = None
        if has_colors:
            colors = np.frombuffer(
                message,
                dtype=np.uint8,
                count=point_count * 3,
                offset=colors_offset,
            ).reshape((-1, 3))
    else:
        flat_points = struct.unpack_from(f"<{points_float_count}f", message, points_offset)
        points = points_from_flat(flat_points)
        colors = None
        if has_colors:
            color_bytes = message[colors_offset : colors_offset + point_count * 3]
            colors = [
                [color_bytes[i], color_bytes[i + 1], color_bytes[i + 2]]
                for i in range(0, len(color_bytes) - 2, 3)
            ]

    return {
        "type": "points3d_bin",
        "timestamp": float(timestamp),
        "points_bin": points,
        "colors_bin": colors,
    }


def points_from_flat(flat_points: Iterable[float]) -> list[list[float]]:
    """Convert [x0, y0, z0, x1, y1, z1, ...] into [[x, y, z], ...]."""
    return [
        [flat_points[i], flat_points[i + 1], flat_points[i + 2]]
        for i in range(0, len(flat_points) - 2, 3)
    ]


def colors_from_z(points: list[list[float]]) -> Optional[list[list[int]]]:
    """Map z-coordinate to RGB colors (blue=low z, red=high z)."""
    if np is not None and isinstance(points, np.ndarray):
        if points.size == 0:
            return None
        z_vals = points[:, 2]
        min_z = float(z_vals.min())
        max_z = float(z_vals.max())
        span = (max_z - min_z) or 1.0
        t = (z_vals - min_z) / span
        r = (255.0 * t).astype(np.uint8)
        g = (128.0 + 127.0 * (1.0 - np.abs(2.0 * t - 1.0))).astype(np.uint8)
        b = (255.0 * (1.0 - t)).astype(np.uint8)
        return np.stack([r, g, b], axis=1)

    if not points:
        return None

    z_vals = [p[2] for p in points]
    min_z, max_z = min(z_vals), max(z_vals)
    span = max_z - min_z or 1.0

    colors = []
    for p in points:
        t = (p[2] - min_z) / span
        r = int(255 * t)
        g = int(128 + 127 * (1 - abs(2 * t - 1)))
        b = int(255 * (1 - t))
        colors.append([r, g, b])
    return colors


def log_handshake(*args, **kwargs):
    try:
        if len(args) >= 2 and hasattr(args[1], "items"):
            path = args[0]
            headers = args[1]
            print(f"[rerun] handshake path: {path}")
            for key, value in headers.items():
                print(f"[rerun]   {key}: {value}")
        elif len(args) >= 2 and hasattr(args[1], "headers"):
            request = args[1]
            path = getattr(request, "path", "/")
            print(f"[rerun] handshake path: {path}")
            for key, value in request.headers.items():
                print(f"[rerun]   {key}: {value}")
        else:
            print(f"[rerun] handshake args: {args} {kwargs}")
    except Exception as exc:
        print(f"[rerun] handshake log error: {exc}")
    return None


def set_rerun_time(timestamp: float) -> None:
    """Support multiple Rerun time APIs across versions."""
    if hasattr(rr, "set_time_seconds"):
        rr.set_time_seconds("timestamp", timestamp)
    elif hasattr(rr, "set_time_nanos"):
        rr.set_time_nanos("timestamp", int(timestamp * 1e9))
    elif hasattr(rr, "set_time_sequence"):
        rr.set_time_sequence("timestamp", int(timestamp * 1e6))


def log_scalar(path: str, value: float) -> None:
    """Log a single scalar using the current Rerun SDK API."""
    rr.log(path, rr.Scalars([value]))


class RerunBridge:
    """Routes incoming websocket payloads into Rerun logs.

    The class holds the history buffer so new message types can be added without
    threading state through the websocket handler.
    """

    def __init__(self, history_size: int = 1):
        self.history: deque[PointsMessage] = deque(maxlen=max(1, history_size))
        self._extrinsics_logged = False
        self._active_pose_source = "imu"
        self._control_queue: asyncio.Queue[dict] = asyncio.Queue(maxsize=128)
        self._latest_points_payload: Optional[dict] = None
        self._prefer_points_next = True
        self._work_event = asyncio.Event()
        self._consumer_task: Optional[asyncio.Task] = None
        self._perf = PipelinePerfWindow(report_interval_s=2.0)

    async def handle_ws(self, websocket):
        await self._ensure_consumer()
        peer = websocket.remote_address
        print(f"[rerun] client connected: {peer}")
        try:
            async for message in websocket:
                decode_start = time.perf_counter()
                payload = decode_message(message)
                self._perf.observe_decode(time.perf_counter() - decode_start)
                if not payload:
                    self._perf.maybe_report(
                        control_queue_size=self._control_queue.qsize(),
                        has_pending_points=self._latest_points_payload is not None,
                    )
                    continue
                self._enqueue_payload(payload)
                self._perf.maybe_report(
                    control_queue_size=self._control_queue.qsize(),
                    has_pending_points=self._latest_points_payload is not None,
                )
        except websockets.ConnectionClosed as exc:
            print(f"[rerun] client disconnected: {peer} ({exc.code})")

    async def _ensure_consumer(self) -> None:
        if self._consumer_task is not None and not self._consumer_task.done():
            return
        self._consumer_task = asyncio.create_task(
            self._consume_payloads(),
            name="rerun-payload-consumer",
        )

    def _enqueue_payload(self, payload: dict) -> None:
        msg_type = payload.get("type")
        if msg_type in POINTS_MESSAGE_TYPES:
            if self._latest_points_payload is not None:
                self._perf.mark_points_overwritten()
            self._latest_points_payload = payload
            self._work_event.set()
            return

        try:
            self._control_queue.put_nowait(payload)
        except asyncio.QueueFull:
            self._perf.mark_control_dropped()
            return
        self._work_event.set()

    async def _consume_payloads(self) -> None:
        while True:
            await self._work_event.wait()
            while True:
                payload = self._next_payload()
                if payload is None:
                    self._work_event.clear()
                    if self._control_queue.empty() and self._latest_points_payload is None:
                        break
                    self._work_event.set()
                    continue

                route_start = time.perf_counter()
                try:
                    await self.route(payload)
                except Exception as exc:
                    print(f"[rerun] message handling error: {exc}")
                self._perf.observe_route(time.perf_counter() - route_start)
                self._perf.maybe_report(
                    control_queue_size=self._control_queue.qsize(),
                    has_pending_points=self._latest_points_payload is not None,
                )

    def _next_payload(self) -> Optional[dict]:
        has_points = self._latest_points_payload is not None
        has_control = not self._control_queue.empty()

        if has_points and (self._prefer_points_next or not has_control):
            payload = self._latest_points_payload
            self._latest_points_payload = None
            self._prefer_points_next = False
            return payload

        if has_control:
            self._prefer_points_next = True
            try:
                return self._control_queue.get_nowait()
            except asyncio.QueueEmpty:
                return None

        if has_points:
            payload = self._latest_points_payload
            self._latest_points_payload = None
            self._prefer_points_next = False
            return payload
        return None

    async def route(self, payload: dict):
        msg_type = payload.get("type")
        timestamp = float(payload.get("timestamp") or 0.0)
        set_rerun_time(timestamp)

        self._log_extrinsics_once()

        if msg_type == "imu":
            self._log_imu(payload, timestamp)
            return

        if msg_type == "pose":
            self._log_pose(payload)
            return

        if msg_type == "motors":
            self._log_motors(payload, timestamp)
            return

        if msg_type in POINTS_MESSAGE_TYPES:
            points_msg = self._build_points_message(payload, timestamp)
            if points_msg:
                self._log_points(points_msg)
            return

        if msg_type == "video_frame":
            self._log_video_frame(payload, timestamp)
            return

        if msg_type == "map_frame":
            self._log_map_frame(payload, timestamp)
            return

    def _pose_paths(self, pose_source: str) -> tuple[str, str]:
        source = (pose_source or "").strip().lower()
        if source == "wheel_odometry":
            base = "world/base_link_wheel_odometry"
        elif source == "imu":
            base = "world/base_link_imu"
        else:
            base = "world/base_link"
        return base, f"{base}/axes"

    def _points_path(self) -> str:
        base_path, _ = self._pose_paths(self._active_pose_source)
        return f"{base_path}/lidar/points"

    def _log_pose(self, payload: dict) -> None:
        quat = payload.get("quaternion") or []
        translation = payload.get("translation") or payload.get("position") or []
        pose_source = payload.get("pose_source", "imu")
        if len(quat) != 4:
            return
        if len(translation) != 3:
            translation = [0, 0, 0]
        self._active_pose_source = (pose_source or "imu").strip().lower()
        base_path, axes_path = self._pose_paths(pose_source)
        # Draw explicit axes as arrows (RGB = XYZ) so orientation is always visible.
        axis_len = 0.1
        axes = [
            [axis_len, 0.0, 0.0],
            [0.0, axis_len, 0.0],
            [0.0, 0.0, axis_len],
        ]
        origins = [[0.0, 0.0, 0.0]] * 3
        colors = [[255, 0, 0], [0, 255, 0], [0, 0, 255]]

        try:
            rr.log(
                base_path,
                rr.Transform3D(
                    translation=translation,
                    rotation=rr.Quaternion(xyzw=quat),
                ),
            )
            rr.log(
                axes_path,
                rr.Arrows3D(origins=origins, vectors=axes, colors=colors),
            )
        except Exception:
            rr.log(
                base_path,
                rr.Transform3D(
                    translation=[0, 0, 0],
                    rotation=rr.Quaternion(xyzw=quat),
                ),
            )

    def _log_imu(self, payload: dict, timestamp: float) -> None:
        accel = payload.get("accel") or []
        gyro = payload.get("gyro") or []
        frame_id = payload.get("frame_id")
        if len(accel) != 3 or len(gyro) != 3:
            return

        rr.log("world/base_link/imu/accel", rr.Scalars(accel))
        rr.log("world/base_link/imu/gyro", rr.Scalars(gyro))
        if frame_id is not None:
            log_scalar("world/base_link/imu/frame_id", float(frame_id))

    def _log_motors(self, payload: dict, timestamp: float) -> None:
        left = float(payload.get("left", 0))
        right = float(payload.get("right", 0))
        hold_ms = int(payload.get("hold_ms", 0))

        print(f"[rerun] motors: L={left}% R={right}% hold={hold_ms}ms t={timestamp}")

        rr.log("motors/percent", rr.BarChart(values=[left, right]))

    def _build_points_message(
        self, payload: dict, timestamp: float
    ) -> Optional[PointsMessage]:
        if "points_bin" in payload:
            points = payload.get("points_bin")
            if points is None:
                return None
            colors = payload.get("colors_bin")
            return PointsMessage(timestamp=timestamp, points=points, colors=colors)

        flat_points = payload.get("points") or []
        if not flat_points:
            return None

        raw_colors = payload.get("colors") or []

        if np is not None:
            point_array = np.asarray(flat_points, dtype=np.float32)
            usable_floats = (point_array.size // 3) * 3
            if usable_floats <= 0:
                return None
            points = point_array[:usable_floats].reshape((-1, 3))
            colors = None
            if raw_colors:
                color_array = np.asarray(raw_colors, dtype=np.uint8)
                usable_colors = min(color_array.size, points.shape[0] * 3)
                usable_colors = (usable_colors // 3) * 3
                if usable_colors > 0:
                    colors = color_array[:usable_colors].reshape((-1, 3))
            return PointsMessage(timestamp=timestamp, points=points, colors=colors)

        points = points_from_flat(flat_points)
        colors = None
        if raw_colors:
            colors = [
                [raw_colors[i], raw_colors[i + 1], raw_colors[i + 2]]
                for i in range(0, min(len(raw_colors), len(points) * 3) - 2, 3)
            ]

        return PointsMessage(timestamp=timestamp, points=points, colors=colors)

    def _log_points(self, msg: PointsMessage) -> None:
        points_path = self._points_path()
        if self.history.maxlen == 1:
            self.history.clear()
            self.history.append(msg)
            set_rerun_time(msg.timestamp)
            final_colors = msg.colors if msg.colors is not None else colors_from_z(msg.points)
            rr.log(
                points_path,
                rr.Points3D(msg.points, colors=final_colors),
            )
            return

        self.history.append(msg)

        if np is not None and all(
            isinstance(item.points, np.ndarray) for item in self.history
        ):
            merged_points = np.concatenate([item.points for item in self.history], axis=0)
            if any(item.colors is not None for item in self.history):
                color_parts = []
                for item in self.history:
                    item_colors = item.colors
                    if item_colors is None:
                        item_colors = colors_from_z(item.points)
                    color_parts.append(item_colors)
                merged_colors = np.concatenate(color_parts, axis=0)
            else:
                merged_colors = colors_from_z(merged_points)

            set_rerun_time(msg.timestamp)
            rr.log(
                points_path,
                rr.Points3D(merged_points, colors=merged_colors),
            )
            return

        merged_points: list[list[float]] = []
        merged_colors: Optional[list[list[int]]] = (
            [] if any(m.colors is not None for m in self.history) else None
        )

        for item in self.history:
            points = item.points
            if np is not None and isinstance(points, np.ndarray):
                points = points.tolist()
            merged_points.extend(points)
            if merged_colors is not None:
                colors = item.colors
                if np is not None and isinstance(colors, np.ndarray):
                    colors = colors.tolist()
                if colors is None:
                    colors = colors_from_z(item.points)
                    if np is not None and isinstance(colors, np.ndarray):
                        colors = colors.tolist()
                merged_colors.extend(colors or [])

        set_rerun_time(msg.timestamp)
        final_colors = merged_colors if merged_colors else colors_from_z(merged_points)
        rr.log(
            points_path,
            rr.Points3D(merged_points, colors=final_colors),
        )

    def _log_video_frame(self, payload: dict, timestamp: float) -> None:
        jpeg_b64 = payload.get("jpeg_b64")
        if not jpeg_b64:
            return
        try:
            jpeg_bytes = base64.b64decode(jpeg_b64, validate=True)
        except Exception:
            return
        set_rerun_time(timestamp)
        if self._log_encoded_image("world/base_link/camera/image", jpeg_bytes):
            return

    def _log_map_frame(self, payload: dict, timestamp: float) -> None:
        jpeg_b64 = payload.get("jpeg_b64")
        if not jpeg_b64:
            return
        try:
            jpeg_bytes = base64.b64decode(jpeg_b64, validate=True)
        except Exception:
            return
        set_rerun_time(timestamp)
        self._log_encoded_image("map/image", jpeg_bytes)

    def _log_extrinsics_once(self) -> None:
        if self._extrinsics_logged:
            return
        self._extrinsics_logged = True
        rr.log("world", rr.ViewCoordinates.FLU, static=True)
        rr.log(
            "world",
            rr.Transform3D(
                translation=[0, 0, 0],
                rotation=rr.Quaternion(xyzw=[0, 0, 0, 1]),
            ),
            static=True,
        )
        coord_frame = getattr(rr, "CoordinateFrame", None)
        if coord_frame is not None:
            rr.log("world", coord_frame("world"), static=True)
            rr.log("world/base_link", coord_frame("base_link"), static=True)
            rr.log("world/base_link_imu", coord_frame("base_link_imu"), static=True)
            rr.log(
                "world/base_link_wheel_odometry",
                coord_frame("base_link_wheel_odometry"),
                static=True,
            )
        rr.log("world/base_link", rr.ViewCoordinates.FLU, static=True)
        rr.log("world/base_link_imu", rr.ViewCoordinates.FLU, static=True)
        rr.log("world/base_link_wheel_odometry", rr.ViewCoordinates.FLU, static=True)
        rr.log(
            "world/base_link/imu/accel",
            rr.SeriesLines(names=["imu_acc_x", "imu_acc_y", "imu_acc_z"]),
            static=True,
        )
        rr.log(
            "world/base_link/imu/gyro",
            rr.SeriesLines(names=["imu_gyro_x", "imu_gyro_y", "imu_gyro_z"]),
            static=True,
        )
        identity = rr.Transform3D(
            translation=[0, 0, 0],
            rotation=rr.Quaternion(xyzw=[0, 0, 0, 1]),
        )
        rr.log("world/base_link/lidar", identity)
        rr.log("world/base_link_imu/lidar", identity)
        rr.log("world/base_link_wheel_odometry/lidar", identity)
        rr.log("world/base_link/camera", identity)

    def _log_encoded_image(self, path: str, jpeg_bytes: bytes) -> bool:
        encoded_cls = getattr(rr, "EncodedImage", None)
        if encoded_cls is None:
            return False

        # Handle constructor differences between rerun versions.
        constructor_variants = (
            lambda: encoded_cls(contents=jpeg_bytes, media_type="image/jpeg"),
            lambda: encoded_cls(contents=jpeg_bytes),
            lambda: encoded_cls(data=jpeg_bytes, media_type="image/jpeg"),
            lambda: encoded_cls(data=jpeg_bytes),
            lambda: encoded_cls(jpeg_bytes),
        )
        for build in constructor_variants:
            rr.log(path, build())
            return True
        return False


def _call_with_timeout(name: str, fn, timeout_s: float = 2.0) -> None:
    done = threading.Event()
    error_holder: list[Exception] = []

    def runner() -> None:
        try:
            fn()
        except Exception as exc:  # pragma: no cover - defensive guard for SDK calls.
            error_holder.append(exc)
        finally:
            done.set()

    thread = threading.Thread(target=runner, name=f"rr-{name}-shutdown", daemon=True)
    thread.start()
    if not done.wait(timeout_s):
        print(
            f"[rerun] shutdown step '{name}' timed out after {timeout_s:.1f}s; continuing exit"
        )
        return
    if error_holder:
        print(f"[rerun] shutdown step '{name}' failed: {error_holder[0]}")


def _safe_rr_shutdown() -> None:
    for name in ("flush", "disconnect", "shutdown"):
        fn = getattr(rr, name, None)
        if callable(fn):
            _call_with_timeout(name, fn)


def main():
    parser = argparse.ArgumentParser(
        description="Rerun websocket bridge for roamr point clouds."
    )
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=9877)
    parser.add_argument(
        "--spawn-viewer",
        dest="spawn",
        action="store_true",
        help="Spawn the Rerun viewer (default).",
    )
    parser.add_argument(
        "--no-spawn-viewer",
        dest="spawn",
        action="store_false",
        help="Run headless without launching a viewer.",
    )
    parser.set_defaults(spawn=True)
    parser.add_argument(
        "--history",
        type=int,
        default=1,
        help="Number of recent scans to retain and replay each update. Set >1 only if points are pose-compensated.",
    )

    args = parser.parse_args()

    rr.init("roamr")
    try:
        blueprint = rrb.Blueprint(
            rrb.Horizontal(
                rrb.Spatial3DView(
                    origin="world",
                    name="3D",
                    contents="world/**",
                    spatial_information=rrb.SpatialInformation(
                        target_frame="tf#/world",
                        show_axes=True,
                    ),
                ),
                rrb.Spatial2DView(
                    origin="map",
                    name="Map",
                    contents="map/**",
                ),
                column_shares=[2.0, 1.0],
            ),
            collapse_panels=True,
        )
        rr.send_blueprint(blueprint)
    except Exception as exc:
        print(f"[rerun] blueprint setup failed: {exc}")
    if args.spawn:
        server_uri = rr.serve_grpc()
        if server_uri is not None:
            try:
                rr.serve_web_viewer(connect_to=server_uri)
            except Exception as exc:
                print(f"[rerun] viewer spawn failed, continuing headless: {exc}")

    async def runner():
        bridge = RerunBridge(history_size=args.history)
        stop_event = asyncio.Event()

        loop = asyncio.get_running_loop()

        def request_shutdown(signame: str):
            print(f"[rerun] received {signame}, shutting down...")
            stop_event.set()

        for signame in ("SIGINT", "SIGTERM"):
            signum = getattr(signal, signame, None)
            if signum is None:
                continue
            try:
                loop.add_signal_handler(signum, request_shutdown, signame)
            except (NotImplementedError, RuntimeError):
                pass

        print(f"[rerun] listening on {args.host}:{args.port}")
        print("[rerun] waiting for websocket clients (Ctrl+C to stop)")
        try:
            async with websockets.serve(
                bridge.handle_ws,
                args.host,
                args.port,
                max_size=20 * 1024 * 1024,
                process_request=log_handshake,
            ):
                await stop_event.wait()
        except OSError as exc:
            print(
                f"[rerun] failed to bind websocket server on {args.host}:{args.port}: {exc}"
            )
            if getattr(exc, "errno", None) in (48, 98):
                print("[rerun] another process may still be using this port")
            raise
        finally:
            _safe_rr_shutdown()

    try:
        asyncio.run(runner())
    except KeyboardInterrupt:
        print("[rerun] shutdown requested (KeyboardInterrupt)")
        _safe_rr_shutdown()


if __name__ == "__main__":
    main()
