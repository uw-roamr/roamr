//
//  LiDARARView.swift
//  Capstone MVP
//
//  Created by Anders Tai on 2025-09-22.
//

import SwiftUI
import RealityKit
import ARKit
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
				HStack {
					Button {
						saveCurrentPoseAndPoints()
					} label: {
						Text("Save Pose")
							.font(.headline)
							.padding(.horizontal, 14)
							.padding(.vertical, 10)
							.background(Color.AppColor.accent.color)
							.foregroundColor(.white)
							.cornerRadius(20)
					}
					Spacer()
					Button {
						lidarManager.toggleSession()
					} label: {
						Icon(color: color, iconName: iconName)
					}
					.frame(maxWidth: .infinity, alignment: .trailing)
				}

				Spacer()
			}
			.padding(.top, safeAreaInsets.top)
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
}
