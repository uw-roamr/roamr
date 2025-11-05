//
//  LiDARManager.swift
//  Capstone MVP
//
//  Created by Anders Tai on 2025-09-22.
//


import Foundation
import ARKit
import Combine
import RealityFoundation
import RealityKit

final class LiDARManager: NSObject, ObservableObject, ARSessionDelegate {
	@Published var isActive = false

	var serverURL: String = "ws://192.168.1.2:8080"
		
	let session = ARSession()
	
	override init() {
		super.init()
		session.delegate = self
	}
	
	func startSession() {
		guard ARWorldTrackingConfiguration.isSupported else {
			print("ARWorldTrackingConfiguration not supported on this device.")
			return
		}
		
		let config = ARWorldTrackingConfiguration()
		// Enable scene reconstruction or frame semantics for devices with LiDAR
		if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
			config.frameSemantics.insert(.sceneDepth)
		}
		// Enable plane detection / scene reconstruction if desired:
		if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
			config.sceneReconstruction = .mesh
		}
		config.environmentTexturing = .automatic
		
		session.run(config)
		isActive = true
		print("ARSession started")
	}
	
	func stopSession() {
		session.pause()
		isActive = false
		print("ARSession paused")
	}
	
	func toggleSession() {
		if isActive {
			stopSession()
		} else {
			startSession()
		}
	}
	
	// MARK: - ARSessionDelegate
	func session(_ session: ARSession, didUpdate frame: ARFrame) {
		// Use rawFeaturePoints (fast, already computed by ARKit)
		if let pointCloud = frame.rawFeaturePoints {
			let points = pointCloud.points // [SIMD3<Float>]
			handle(points: points, cameraTransform: frame.camera.transform)
		} else {
			// If rawFeaturePoints not available, optionally handle sceneDepth; omitted here for brevity
		}
	}
	
	private func handle(points: [SIMD3<Float>], cameraTransform: simd_float4x4) {
		guard !points.isEmpty else { return }
		
		let maxPointsToSend = 1000
		let count = min(points.count, maxPointsToSend)
		var out: [[Float]] = []
		out.reserveCapacity(count)
		for i in 0..<count {
			let p = points[i]
			out.append([p.x, p.y, p.z])
		}
		
		print("LiDAR points: \(points.count)")
	}
}
