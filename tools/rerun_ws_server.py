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
import threading
from collections import deque
from dataclasses import dataclass
from typing import Iterable, Optional

import rerun as rr
import rerun.blueprint as rrb
import websockets


@dataclass
class PointsMessage:
    timestamp: float
    points: list[list[float]]
    colors: Optional[list[list[int]]]


def decode_message(message) -> Optional[dict]:
    """Parse JSON payloads from websocket messages.

    Returns None on decode errors so callers can cheaply `continue`.
    """

    if isinstance(message, bytes):
        try:
            message = message.decode("utf-8")
        except UnicodeDecodeError:
            return None
    try:
        return json.loads(message)
    except json.JSONDecodeError:
        return None


def points_from_flat(flat_points: Iterable[float]) -> list[list[float]]:
    """Convert [x0, y0, z0, x1, y1, z1, ...] into [[x, y, z], ...]."""
    return [
        [flat_points[i], flat_points[i + 1], flat_points[i + 2]]
        for i in range(0, len(flat_points) - 2, 3)
    ]


def colors_from_z(points: list[list[float]]) -> Optional[list[list[int]]]:
    """Map z-coordinate to RGB colors (blue=low z, red=high z)."""
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

    async def handle_ws(self, websocket):
        peer = websocket.remote_address
        print(f"[rerun] client connected: {peer}")
        try:
            async for message in websocket:
                payload = decode_message(message)
                if not payload:
                    continue
                try:
                    await self.route(payload)
                except Exception as exc:
                    print(f"[rerun] message handling error: {exc}")
        except websockets.ConnectionClosed as exc:
            print(f"[rerun] client disconnected: {peer} ({exc.code})")

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

        if msg_type == "points3d":
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

    def _log_pose(self, payload: dict) -> None:
        quat = payload.get("quaternion") or []
        translation = payload.get("translation") or payload.get("position") or []
        pose_source = payload.get("pose_source", "imu")
        if len(quat) != 4:
            return
        if len(translation) != 3:
            translation = [0, 0, 0]
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
        flat_points = payload.get("points") or []
        if not flat_points:
            return None

        points = points_from_flat(flat_points)
        raw_colors = payload.get("colors") or []

        colors = None
        if raw_colors:
            colors = [
                [raw_colors[i], raw_colors[i + 1], raw_colors[i + 2]]
                for i in range(0, min(len(raw_colors), len(points) * 3) - 2, 3)
            ]

        return PointsMessage(timestamp=timestamp, points=points, colors=colors)

    def _log_points(self, msg: PointsMessage) -> None:
        self.history.append(msg)

        merged_points: list[list[float]] = []
        merged_colors: Optional[list[list[int]]] = (
            [] if any(m.colors is not None for m in self.history) else None
        )

        for item in self.history:
            merged_points.extend(item.points)
            if merged_colors is not None:
                merged_colors.extend(item.colors or colors_from_z(item.points) or [])

        set_rerun_time(msg.timestamp)
        final_colors = merged_colors if merged_colors else colors_from_z(merged_points)
        rr.log(
            "world/base_link/lidar/points",
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
