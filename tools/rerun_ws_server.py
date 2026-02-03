#!/usr/bin/env python3
import argparse
import asyncio
import json
from collections import deque

import rerun as rr
import websockets


def decode_message(message):
    if isinstance(message, bytes):
        try:
            message = message.decode("utf-8")
        except UnicodeDecodeError:
            return None
    try:
        return json.loads(message)
    except json.JSONDecodeError:
        return None


def points_from_flat(flat_points):
    points = []
    for i in range(0, len(flat_points) - 2, 3):
        points.append([flat_points[i], flat_points[i + 1], flat_points[i + 2]])
    return points


def colors_from_z(points):
    """Map z-coordinate to RGB colors (blue=low z, red=high z)."""
    if not points:
        return None
    z_vals = [p[2] for p in points]
    min_z, max_z = min(z_vals), max(z_vals)
    span = max_z - min_z
    if span == 0:
        span = 1.0
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


def set_rerun_time(timestamp):
    if hasattr(rr, "set_time_seconds"):
        rr.set_time_seconds("timestamp", timestamp)
        return
    if hasattr(rr, "set_time_nanos"):
        rr.set_time_nanos("timestamp", int(timestamp * 1e9))
        return
    if hasattr(rr, "set_time_sequence"):
        rr.set_time_sequence("timestamp", int(timestamp * 1e6))


async def handle_client(websocket, history):
    peer = websocket.remote_address
    print(f"[rerun] client connected: {peer}")
    async for message in websocket:
        if isinstance(message, bytes):
            print(f"[rerun] received {len(message)} bytes")
        else:
            print(f"[rerun] received message: {message[:200]}")
        payload = decode_message(message)
        if not payload:
            continue

        msg_type = payload.get("type")

        timestamp = float(payload.get("timestamp") or 0.0)
        set_rerun_time(timestamp)

        if msg_type == "pose":
            quat = payload.get("quaternion") or []
            if len(quat) == 4:
                rr.log(
                    "phone/pose",
                    rr.Transform3D(
                        translation=[0, 0, 0],
                        rotation=rr.Quaternion(xyzw=quat),
                    ),
                )
            continue

        if msg_type != "points3d":
            continue

        flat_points = payload.get("points") or []
        if not flat_points:
            continue
        flat_colors = payload.get("colors") or []

        points = points_from_flat(flat_points)
        # Align colors to points if present (expect RGB triplets)
        colors = None
        if flat_colors:
            colors = []
            for i in range(0, min(len(flat_colors), len(points) * 3) - 2, 3):
                colors.append([flat_colors[i], flat_colors[i + 1], flat_colors[i + 2]])

        history.append((timestamp, points, colors))
        merged_points = []
        merged_colors = [] if any(c is not None for _, _, c in history) else None
        for _, pts, cols in history:
            merged_points.extend(pts)
            if merged_colors is not None:
                if cols is not None:
                    merged_colors.extend(cols)
                else:
                    merged_colors.extend(colors_from_z(pts))
        set_rerun_time(timestamp)
        final_colors = merged_colors if merged_colors else colors_from_z(merged_points)
        rr.log("lidar/points", rr.Points3D(merged_points, colors=final_colors))


def main():
    parser = argparse.ArgumentParser(description="Rerun websocket bridge for roamr point clouds.")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=9877)
    parser.add_argument("--spawn", action="store_true", help="Spawn the Rerun viewer.", default=True)
    parser.add_argument(
        "--history",
        type=int,
        default=5,
        help="Number of recent scans to retain and replay each update. Set >1 only if points are pose-compensated.",
    )

    args = parser.parse_args()

    rr.init("roamr")
    server_uri = None
    if args.spawn:
        
        server_uri = rr.serve_grpc()
        if server_uri is not None:
            try:
                rr.serve_web_viewer(connect_to=server_uri)
            except Exception as exc:
                if args.spawn_if_possible and not args.spawn:
                    print(f"[rerun] viewer spawn failed, continuing without viewer: {exc}")
                else:
                    raise

    async def runner():
        history = deque(maxlen=max(1, args.history))
        print(f"[rerun] listening on {args.host}:{args.port}")
        async with websockets.serve(
            lambda ws: handle_client(ws, history),
            args.host,
            args.port,
            max_size=20 * 1024 * 1024,
            process_request=log_handshake,
        ):
            await asyncio.Future()

    asyncio.run(runner())


if __name__ == "__main__":
    main()
