//
//  LiDARARView.swift
//  Capstone MVP
//
//  Created by Anders Tai on 2025-09-22.
//

import SwiftUI
import RealityKit
import ARKit
import WasmKit
import Foundation

struct UILiDARView: UIViewRepresentable {
	@EnvironmentObject var lidarManager: LiDARManager

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
		arView.session = lidarManager.session
        arView.automaticallyConfigureSession = false
		arView.debugOptions = [.showSceneUnderstanding, .showWorldOrigin]

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct LiDARView: View {
	@Environment(\.safeAreaInsets) private var safeAreaInsets
	@EnvironmentObject var lidarManager: LiDARManager
	@State private var mapImage: UIImage?

	var iconName: String {
		lidarManager.isActive ? "stop.fill" : "play.fill"
	}

	var color: Color {
		lidarManager.isActive ? Color.AppColor.background.color.opacity(0.8) : Color.AppColor.accent.color
	}

	var body: some View {
		ZStack {
			UILiDARView()

			VStack {
				Button {
					lidarManager.toggleSession()
				} label: {
					Icon(color: color, iconName: iconName)
				}
				.frame(maxWidth: .infinity, alignment: .trailing)

				Spacer()
			}
			.padding(.top, safeAreaInsets.top)
			.padding(.horizontal, 16)

			VStack {
				Spacer()
				HStack {
					Spacer()
					Button {
						showMap()
					} label: {
						Text("Show Map")
							.font(.headline)
							.padding(.horizontal, 14)
							.padding(.vertical, 10)
							.background(Color.green.opacity(0.9))
							.foregroundColor(.white)
							.cornerRadius(10)
					}
				}
				.padding(.bottom, 8)
				HStack {
					Spacer()
					Button {
						saveCurrentPoseAndPoints()
					} label: {
						Text("Save Current Pose & Points")
							.font(.headline)
							.padding(.horizontal, 14)
							.padding(.vertical, 10)
							.background(Color.blue.opacity(0.9))
							.foregroundColor(.white)
							.cornerRadius(10)
					}
				}
			}
			.padding(.bottom, safeAreaInsets.bottom + 80)
			.padding(.horizontal, 16)

			if let img = mapImage {
				VStack {
					HStack {
						Spacer()
						Button {
							withAnimation { mapImage = nil }
						} label: {
							Text("Close")
								.font(.subheadline)
								.padding(.horizontal, 10)
								.padding(.vertical, 6)
								.background(Color.black.opacity(0.6))
								.foregroundColor(.white)
								.cornerRadius(8)
						}
					}
					Image(uiImage: img)
						.resizable()
						.scaledToFit()
						.frame(maxWidth: 300, maxHeight: 300)
						.background(.ultraThinMaterial)
						.cornerRadius(12)
					Spacer()
				}
				.padding()
				.transition(.opacity.combined(with: .scale))
			}
		}
		.onDisappear {
			lidarManager.stopSession()
			withAnimation {
				lidarManager.showDataSheet = false
			}
		}
	}

	private func currentPoseXZYaw() -> (Float, Float, Float)? {
		guard let frame = lidarManager.session.currentFrame else { return nil }
		let transform = frame.camera.transform
		let x_pos = transform.columns.3.x
		let z_pos = transform.columns.3.z
		let quat = simd_quatf(transform)
		let siny_cosp = 2.0 * (quat.real * quat.imag.y + quat.imag.z * quat.imag.x)
		let cosy_cosp = 1.0 - 2.0 * (quat.imag.y * quat.imag.y + quat.imag.z * quat.imag.z)
		let yaw = atan2f(Float(siny_cosp), Float(cosy_cosp))
		return (x_pos, z_pos, yaw)
	}

	private func saveCurrentPoseAndPoints() {
		guard let (x_pos, y_pos, yaw) = currentPoseXZYaw() else { return }
		// Save pose
		lidarManager.savedPoses.append((x_pos, y_pos, yaw))
		// Capture latest LiDAR points (project to XZ plane)
		let latest = lidarManager.latestPoints
		let maxPts = min(latest.count, 5_000)
		var projected: [(Float, Float)] = []
		projected.reserveCapacity(maxPts)
		for i in 0..<maxPts {
			let point = latest[i]
			projected.append((point.x, point.z))
		}
		lidarManager.savedPointsSets.append(projected)
		print(String(format: "Saved pose & %d points (#%d)", projected.count, lidarManager.savedPoses.count))
	}

	private func showMap() {
		let poses = lidarManager.savedPoses
		guard !poses.isEmpty else {
			print("No saved poses yet.")
			return
		}
		// Flatten all saved point sets
		let allPointSets = lidarManager.savedPointsSets
		let flatPoints: [(Float, Float)] = allPointSets.flatMap { $0 }
		do {
			guard let wasmURL = Bundle.main.url(forResource: "map", withExtension: "wasm") else {
				print("map.wasm not found in bundle (skipping wasm call).")
				return
			}
			let wasmBytes = try Data(contentsOf: wasmURL)
			let engine = Engine()
			let module: Module = try parseWasm(bytes: [UInt8](wasmBytes))
			let store = Store(engine: engine)
			let instance = try module.instantiate(store: store)

			// Reset poses
			if let reset = instance.exports[function: "reset_poses"] {
				_ = try reset([])
			}

			// Send poses
			if let setPose = instance.exports[function: "set_pose"] {
				for (idx, p) in poses.enumerated() {
					_ = try setPose([.i32(UInt32(idx)), .f32(p.0.bitPattern), .f32(p.1.bitPattern), .f32(p.2.bitPattern)])
				}
			}

			// Draw
			let width: Int32 = 256
			let height: Int32 = 256
			// Send points
			if let resetPts = instance.exports[function: "reset_points"] {
				_ = try resetPts([])
			}
			if let setPoint = instance.exports[function: "set_point"] {
				for (idx, pt) in flatPoints.enumerated() {
					_ = try setPoint([.i32(UInt32(idx)), .f32(pt.0.bitPattern), .f32(pt.1.bitPattern)])
				}
			}
			// Draw combined map (poses + points)
			if let drawCombined = instance.exports[function: "draw_map"] {
				_ = try drawCombined([.i32(UInt32(poses.count)), .i32(UInt32(flatPoints.count)), .i32(UInt32(width)), .i32(UInt32(height))])
			}

			// Read dimensions
			var w = Int(width)
			var h = Int(height)
			if let getW = instance.exports[function: "get_image_width"],
			   let getH = instance.exports[function: "get_image_height"] {
				if let rvW = try getW([]).first?.i32 { w = Int(rvW) }
				if let rvH = try getH([]).first?.i32 { h = Int(rvH) }
			}

			// Read pixels through function accessor to avoid direct memory binding
			guard let getPixel = instance.exports[function: "get_image_pixel_u32"] else {
				print("get_image_pixel_u32 not found")
				return
			}
			var bytes = [UInt8](repeating: 0, count: w * h * 4)
			for i in 0..<(w * h) {
				if let rv = try getPixel([.i32(UInt32(i))]).first?.i32 {
					let v: UInt32 = rv
					let o = i * 4
					bytes[o + 0] = UInt8(truncatingIfNeeded: v & 0xFF)         // R
					bytes[o + 1] = UInt8(truncatingIfNeeded: (v >> 8) & 0xFF)  // G
					bytes[o + 2] = UInt8(truncatingIfNeeded: (v >> 16) & 0xFF) // B
					bytes[o + 3] = UInt8(truncatingIfNeeded: (v >> 24) & 0xFF) // A
				}
			}

			if let image = makeUIImageRGBA(bytes: bytes, width: w, height: h) {
				withAnimation { self.mapImage = image }
			}
		} catch {
			print("WASM error: \(error.localizedDescription)")
		}
	}

	private func makeUIImageRGBA(bytes: [UInt8], width: Int, height: Int) -> UIImage? {
		return bytes.withUnsafeBytes { rawPtr -> UIImage? in
			guard let base = rawPtr.baseAddress else { return nil }
			guard let cfData = CFDataCreate(kCFAllocatorDefault, base.assumingMemoryBound(to: UInt8.self), rawPtr.count) else { return nil }
			guard let provider = CGDataProvider(data: cfData) else { return nil }
			let colorSpace = CGColorSpaceCreateDeviceRGB()
			// RGBA8888, premultiplied last
			let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
			guard let cg = CGImage(
				width: width,
				height: height,
				bitsPerComponent: 8,
				bitsPerPixel: 32,
				bytesPerRow: width * 4,
				space: colorSpace,
				bitmapInfo: bitmapInfo,
				provider: provider,
				decode: nil,
				shouldInterpolate: false,
				intent: .defaultIntent
			) else { return nil }
			return UIImage(cgImage: cg)
		}
	}
}
