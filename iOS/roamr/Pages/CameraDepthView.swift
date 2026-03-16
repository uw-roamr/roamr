//
//  CameraDepthView.swift
//  roamr
//
//  Created by Claude on 2026-01-13.
//

import SwiftUI

// MARK: - Constants

struct PointCloudConfig {
    static let maxPoints: Int = 12000  // Higher density while remaining real-time on recent iPhones
}

enum CameraViewMode: String, CaseIterable {
    case video
    case depth
    case point

    var iconName: String {
        switch self {
        case .video: return "video.fill"
        case .depth: return "square.3.layers.3d"
        case .point: return "circle.grid.3x3.fill"
        }
    }
}

struct CameraDepthView: View {
    @Environment(\.safeAreaInsets) private var safeAreaInsets
    @ObservedObject private var avManager = AVManager.shared
    @State private var viewMode: CameraViewMode = .video

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                // Main content based on view mode
                Group {
                    switch viewMode {
                    case .video:
                        videoView(geometry: geometry)
                    case .depth:
                        depthView(geometry: geometry)
                    case .point:
                        pointCloudView(geometry: geometry)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }

            // Vertical view switcher on the right
            HStack {
                Spacer()
                VerticalViewSwitcher(currentMode: $viewMode)
                    .padding(.trailing, 16)
            }

            PageHeader(
                title: "Camera",
                statusText: avManager.isActive ? "Running" : "Stopped",
                statusColor: avManager.isActive ? .green : .gray,
                titleColor: .white,
                statusTextColor: .white.opacity(0.7)
            ) {
                Button {
                    avManager.toggleSession()
                } label: {
                    PlayButton(isActive: avManager.isActive)
                }
            }
            .padding(.top, safeAreaInsets.top)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            syncPreviewMode()
        }
        .onChange(of: viewMode) { _ in
            syncPreviewMode()
        }
        .onDisappear {
            avManager.setPreviewMode(.none)
        }
    }

    private func syncPreviewMode() {
        switch viewMode {
        case .video:
            avManager.setPreviewMode(.video)
        case .depth:
            avManager.setPreviewMode(.depth)
        case .point:
            avManager.setPreviewMode(.point)
        }
    }

    @ViewBuilder
    private func videoView(geometry: GeometryProxy) -> some View {
        if let cameraImage = avManager.cameraImage {
            Image(uiImage: cameraImage)
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        } else {
            Rectangle()
                .fill(Color.black)
                .overlay {
                    Text("No Video")
                        .foregroundColor(.white.opacity(0.5))
                }
        }
    }

    @ViewBuilder
    private func depthView(geometry: GeometryProxy) -> some View {
        if let depthImage = avManager.depthMapImage {
            Image(uiImage: depthImage)
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        } else {
            Rectangle()
                .fill(Color.black)
                .overlay {
                    Text("No Depth Data")
                        .foregroundColor(.white.opacity(0.5))
                }
        }
    }

    @ViewBuilder
    private func pointCloudView(geometry: GeometryProxy) -> some View {
        ZStack {
            // Video feed as background
//            if let cameraImage = avManager.cameraImage {
//                Image(uiImage: cameraImage)
//                    .resizable()
//                    .scaledToFill()
//                    .frame(width: geometry.size.width, height: geometry.size.height)
//                    .clipped()
//            } else {
                Rectangle()
                    .fill(Color.black)
//            }

            // Depth pixels overlay (using pixel coordinates for proper alignment)
            if let depthPixels = avManager.depthPixels, depthPixels.count > 0 {
                DepthPixelCanvasView(data: depthPixels, size: geometry.size)
            } else {
                Text("No Point Cloud")
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }
}

// MARK: - Point Cloud Canvas View

struct PointCloudCanvasView: View {
    let points: [SIMD3<Float>]
    let size: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            let centerX = canvasSize.width / 2
            let centerY = canvasSize.height / 2

            // Scale factor to map meters to pixels
            let scale: CGFloat = 300

            // Sample points for performance (draw every Nth point)
            let stride = max(1, points.count / 50000)

            for i in Swift.stride(from: 0, to: points.count, by: stride) {
                let point = points[i]

            // Project FLU (forward/left) into a top-down view.
            let screenX = centerX - CGFloat(point.y) * scale
            let screenY = centerY - CGFloat(point.x) * scale

            // Forward (X) as color gradient: close = warm (red/yellow), far = cool (blue)
            let forward = point.x
            let normalizedDepth = min(max(Double(forward) / 5.0, 0), 1) // 0-5m range

                // Gradient from red (close) -> yellow -> green -> cyan -> blue (far)
                let hue = normalizedDepth * 0.7 // 0 = red, 0.7 = blue
                let color = Color(hue: hue, saturation: 1.0, brightness: 1.0)

                let rect = CGRect(x: screenX - 1, y: screenY - 1, width: 2, height: 2)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text("\(points.count) points")
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.5))
                .cornerRadius(4)
                .padding(16)
				.padding(.bottom, AppConstants.shared.tabBarHeight)
        }
    }
}

// MARK: - Depth Pixel Canvas View (for video overlay)

struct DepthPixelCanvasView: View {
	@Environment(\.safeAreaInsets) private var safeAreaInsets

    let data: DepthPixelData
    let size: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            // Depth pixels are already in portrait orientation to match the video feed.

            let depthWidth = CGFloat(data.width)
            let depthHeight = CGFloat(data.height)

            // Calculate scaledToFill transform (same as video)
            let imageAspect = depthWidth / depthHeight
            let screenAspect = canvasSize.width / canvasSize.height

            let scale: CGFloat
            let offsetX: CGFloat
            let offsetY: CGFloat

            if imageAspect > screenAspect {
                // Image is wider - scale by height, crop width
                scale = canvasSize.height / depthHeight
                offsetX = (canvasSize.width - depthWidth * scale) / 2
                offsetY = 0
            } else {
                // Image is taller - scale by width, crop height
                scale = canvasSize.width / depthWidth
                offsetX = 0
                offsetY = (canvasSize.height - depthHeight * scale) / 2
            }

            // Sample points for performance
            let stride = max(1, data.count / PointCloudConfig.maxPoints)

            for i in Swift.stride(from: 0, to: data.count, by: stride) {
                let pixel = data.pixels[i]

                // Apply scaledToFill transform
                let screenX = CGFloat(pixel.x) * scale + offsetX
                let screenY = CGFloat(pixel.y) * scale + offsetY

                // Depth as color gradient: close = red, far = blue
                let normalizedDepth = min(max(Double(pixel.depth) / 5.0, 0), 1)
                let hue = normalizedDepth * 0.7
                let color = Color(hue: hue, saturation: 1.0, brightness: 1.0)

                let rect = CGRect(x: screenX - 1.5, y: screenY - 1.5, width: 3, height: 3)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text("\(data.count) points")
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.5))
                .cornerRadius(4)
                .padding(16)
				.padding(.bottom, AppConstants.shared.tabBarHeight + safeAreaInsets.bottom)
        }
    }
}

// MARK: - Vertical View Switcher

struct VerticalViewSwitcher: View {
    @Binding var currentMode: CameraViewMode

    var body: some View {
        VStack(spacing: 16) {
            ForEach(CameraViewMode.allCases, id: \.self) { mode in
                ViewSwitcherButton(mode: mode, currentMode: $currentMode)
            }
        }
        .padding(10)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: currentMode)
    }
}

struct ViewSwitcherButton: View {
    let mode: CameraViewMode
    @Binding var currentMode: CameraViewMode

    var isActive: Bool { currentMode == mode }

    var circleSize: CGFloat {
        isActive ? 44 : 36
    }

    var fontSize: CGFloat {
        isActive ? 18 : 16
    }

    var body: some View {
        Button {
            currentMode = mode
        } label: {
            ZStack {
                Circle()
                    .fill(isActive ? Color("AccentColor") : Color.gray.opacity(0.2))
                    .frame(width: circleSize, height: circleSize)

                Image(systemName: mode.iconName)
                    .foregroundColor(.white)
                    .font(.system(size: fontSize, weight: .semibold))
            }
            .shadow(color: isActive ? Color("AccentColor").opacity(0.4) : .clear, radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .scaleEffect(isActive ? 1.1 : 1.0)
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isActive)
    }
}
