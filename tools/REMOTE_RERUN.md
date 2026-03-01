# Connecting the app to Rerun when not on the same LAN

The iOS app sends telemetry to `rerun_ws_server.py` over WebSocket. By default you need the phone and the computer on the same network (e.g. a hotspot). These options let you connect over the internet.

## Option 1: Tailscale (recommended)

[Tailscale](https://tailscale.com) puts both devices on a private mesh network over the internet (WireGuard-based). No hotspot, no port forwarding.

1. **Install Tailscale**
   - On your Mac (or whatever runs the server): [tailscale.com/download](https://tailscale.com/download)
   - On your iPhone: Tailscale app from the App Store. Sign in with the same account.

2. **Run the Rerun server as usual**
   ```bash
   cd tools && uv run python rerun_ws_server.py
   ```
   The server already listens on `0.0.0.0:9877`, so it will accept connections on the Tailscale interface too.

3. **Find your computer's Tailscale address**
   - Mac: click the Tailscale menu bar icon → copy the machine's Tailscale IP (e.g. `100.x.x.x`), or use its MagicDNS name (e.g. `your-mac.your-tailnet.ts.net`).

4. **In the roamr app**
   - Settings → Rerun WebSocket URL → set to:
     - `ws://100.x.x.x:9877` (your computer's Tailscale IP), or
     - `ws://your-mac.your-tailnet.ts.net:9877` (MagicDNS name).

Traffic is encrypted end-to-end; no data goes through a third-party relay (except optional DERP for NAT traversal).

---

## Troubleshooting Tailscale

If the app shows no data in Rerun and the URL is correct (e.g. `ws://100.117.178.92:9877`):

### 1. Tailscale must be **Connected** on the iPhone

In the Tailscale app on the phone, the status must be **Connected** (the VPN is on). If it says "Disconnected" or "Connecting", the phone cannot reach Tailscale IPs.

### 2. macOS Firewall may be blocking port 9877

- **System Settings → Network → Firewall**
- If the firewall is on, either:
  - **Turn off** (for testing), or
  - Add a rule: **Options… → +** and allow **Python** (or your terminal app) **Incoming**, or allow **port 9877** for incoming TCP.

Then try again from the app.

### 3. Confirm the server is reachable

**On the Mac** (with the Rerun server running in another terminal):

```bash
# See if something is listening on 9877
lsof -i :9877
```

You should see the Python process. Then from **another machine on Tailscale** (or the same Mac):

```bash
# Test TCP to your Mac's Tailscale IP (replace with your mb-pro IP)
nc -zv 100.117.178.92 9877
```

- If `nc` succeeds: the server is reachable; the problem may be the WebSocket handshake or the app. Run the app from Xcode and watch the console for `Rerun websocket send error:` or `receive error:`.
- If `nc` times out or "Connection refused": firewall or Tailscale routing. Ensure firewall allows 9877 and that Tailscale is connected on both devices.

### 4. Check the server log

When the app connects, the server should print:

```text
[rerun] client connected: ('100.93.147.28', 12345)
```

(IP will be your iPhone's Tailscale IP.) If you never see this, the connection is not reaching the server (firewall or Tailscale).

---

## Option 2: Tunnels (ngrok, Cloudflare Tunnel, etc.)

If you don't want to install Tailscale on the phone, you can expose the WebSocket server with a public URL and use a `wss://` URL in the app. Tailscale is usually simpler and more private.
