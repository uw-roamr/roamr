#!/usr/bin/env python3
import argparse
import asyncio
import json

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


async def handle_client(websocket):
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

        if payload.get("type") != "points3d":
            continue

        flat_points = payload.get("points") or []
        if not flat_points:
            continue

        timestamp = float(payload.get("timestamp") or 0.0)
        points = points_from_flat(flat_points)
        # set_rerun_time(timestamp)
        print(points)
        rr.log("lidar/points", rr.Points3D(points))


def main():
    parser = argparse.ArgumentParser(description="Rerun websocket bridge for roamr point clouds.")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=9877)
    parser.add_argument("--spawn", action="store_true", help="Spawn the Rerun viewer.")
    parser.add_argument(
        "--spawn-if-possible",
        action="store_true",
        help="Try to spawn the Rerun viewer; fall back if already running.",
    )

    args = parser.parse_args()

    rr.init("roamr")
    server_uri = None
    if args.spawn or args.spawn_if_possible:
        try:
            server_uri = rr.serve_grpc()
        except Exception as exc:
            if args.spawn_if_possible and not args.spawn:
                print(f"[rerun] gRPC server already running, continuing without: {exc}")
            else:
                raise
        if server_uri is not None:
            try:
                rr.serve_web_viewer(connect_to=server_uri)
            except Exception as exc:
                if args.spawn_if_possible and not args.spawn:
                    print(f"[rerun] viewer spawn failed, continuing without viewer: {exc}")
                else:
                    raise

    async def runner():
        print(f"[rerun] listening on {args.host}:{args.port}")
        async with websockets.serve(
            handle_client,
            args.host,
            args.port,
            max_size=20 * 1024 * 1024,
            process_request=log_handshake,
        ):
            await asyncio.Future()

    asyncio.run(runner())


if __name__ == "__main__":
    main()
