# ROAMR Video Streaming

This directory contains the web interface for viewing the live video stream from your ROAMR robot.

## Quick Start

### 1. Start the WebSocket Server on iPhone

1. Open the ROAMR app on your iPhone
2. Navigate to the **WebSocket** tab (bottom navigation)
3. Tap the **Play** button to start the server
4. Note the IP address displayed (e.g., `192.168.1.5`)

### 2. Start Video Streaming

1. Navigate to the **AR View** tab
2. Tap the **Play** button to start the AR session
3. Tap the **Start Stream** button to begin video streaming
   - Button will turn red and say "Stop Stream" when active
   - Video frames are automatically encoded and sent via WebSocket

### 3. View the Stream

1. Open `video-stream.html` in any web browser (Chrome, Safari, Firefox, etc.)
2. Enter the WebSocket URL: `ws://[YOUR_IP]:8080` (e.g., `ws://192.168.1.5:8080`)
3. Click **Connect**
4. You should see the live video stream from your iPhone camera!

## Features

### Video Stream Viewer

- **Real-time video streaming** at 720p, 30 FPS
- **Live statistics**: FPS counter, frame count, and frame size
- **Connection log**: View connection events and debugging info
- **Responsive design**: Works on desktop and mobile browsers
- **Keyboard shortcut**: Press Enter in the URL field to connect

### iOS App Controls

- **Start/Stop Streaming**: Toggle video streaming on/off
- **Quality**: Currently set to 720p at 60% JPEG quality
  - Adjust in `LiDARManager.swift:30` if needed
- **Frame Rate**: 30 FPS (configurable)

## Technical Details

### Architecture

```
iPhone Camera (ARKit)
    ↓
VideoStreamManager (captures & encodes to JPEG)
    ↓
WebSocketServerManager (broadcasts binary data)
    ↓
WebSocket (port 8080)
    ↓
Web Browser (video-stream.html)
```

### Performance

- **Resolution**: 1280x720 (720p)
- **Frame Rate**: ~30 FPS
- **Compression**: JPEG at 60% quality
- **Bandwidth**: ~1-2 Mbps (depends on scene complexity)
- **Latency**: ~100-300ms end-to-end

### Customization

To adjust video quality, edit `iOS/roamr/Managers/LiDARManager.swift`:

```swift
videoStreamManager.configure(
    arSession: session,
    targetFPS: 30,      // Frames per second
    quality: 0.6        // JPEG quality (0.0 - 1.0)
)
```

To change resolution, edit `iOS/roamr/Managers/VideoStreamManager.swift`:

```swift
private var targetWidth: Int = 1280   // Width in pixels
private var targetHeight: Int = 720   // Height in pixels
```

## Troubleshooting

### Connection Issues

- **Can't connect**: Ensure both devices are on the same WiFi network
- **Firewall**: Some networks block WebSocket connections
- **IP address**: Double-check the IP address from the iOS app

### Performance Issues

- **Low FPS**: Reduce quality or resolution in settings
- **High latency**: Check network quality, reduce bandwidth usage
- **Choppy video**: Ensure iPhone isn't overheating or low on battery

### No Video Stream

1. Ensure WebSocket server is running (green indicator)
2. Check that AR session is active (LiDAR tab)
3. Verify "Start Stream" button is pressed (should be red)
4. Check browser console for errors (F12)

## Requirements

- **iOS Device**: iPhone with ARKit support (iPhone 6s or later)
- **Network**: Both devices on same WiFi network
- **Browser**: Any modern browser (Chrome, Safari, Firefox, Edge)

## Advanced Usage

### URL Parameters

You can pre-populate the WebSocket URL using query parameters:

```
video-stream.html?ip=192.168.1.5
```

This will automatically set the URL to `ws://192.168.1.5:8080`.

### Integration with Robot Control

The video stream runs alongside the existing WebSocket functionality for robot control. You can:
- Send control commands via WebSocket (text messages)
- Receive video stream (binary frames)
- Forward commands to Bluetooth peripheral (ESP32)

All on the same WebSocket connection!

## Future Enhancements

Potential improvements:
- H.264 encoding for better compression
- WebRTC for lower latency
- Multiple video quality presets
- Recording capability
- Multi-client streaming with individual quality settings

---

**Built for ROAMR** - Really Opensource Autonomous Mobile Robot
