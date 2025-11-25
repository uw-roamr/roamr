//
//  VideoStreamManager.swift
//  roamr
//
//  Video streaming manager for capturing and encoding ARKit camera frames
//

import Foundation
import ARKit
import AVFoundation
import UIKit

final class VideoStreamManager: NSObject, ObservableObject {
	@Published var isStreaming = false
	@Published var frameCount: Int = 0
	@Published var currentFPS: Double = 0.0

	private var targetWidth: Int = 1280  // 720p width
	private var targetHeight: Int = 720  // 720p height
	private var jpegQuality: CGFloat = 0.6  // Balance between quality and bandwidth
	private var targetFPS: Int = 30
	private var frameInterval: TimeInterval = 0.0
	private var lastFrameTime: TimeInterval = 0.0
	private var fpsCounter: Int = 0
	private var lastFPSUpdateTime: TimeInterval = 0.0

	weak var arSession: ARSession?
	var onFrameEncoded: ((Data) -> Void)?

	override init() {
		super.init()
		frameInterval = 1.0 / Double(targetFPS)
	}

	func configure(arSession: ARSession, targetFPS: Int = 30, quality: CGFloat = 0.6) {
		self.arSession = arSession
		self.targetFPS = targetFPS
		self.jpegQuality = quality
		self.frameInterval = 1.0 / Double(targetFPS)
	}

	func startStreaming() {
		guard !isStreaming else { return }
		isStreaming = true
		frameCount = 0
		fpsCounter = 0
		lastFrameTime = 0.0
		lastFPSUpdateTime = CACurrentMediaTime()
		print("Video streaming started")
	}

	func stopStreaming() {
		guard isStreaming else { return }
		isStreaming = false
		print("Video streaming stopped. Total frames: \(frameCount)")
	}

	// Process ARFrame and encode to JPEG
	func processFrame(_ frame: ARFrame) {
		guard isStreaming else { return }

		let currentTime = CACurrentMediaTime()

		// Throttle frame rate
		if currentTime - lastFrameTime < frameInterval {
			return
		}
		lastFrameTime = currentTime

		// Update FPS counter
		fpsCounter += 1
		if currentTime - lastFPSUpdateTime >= 1.0 {
			currentFPS = Double(fpsCounter)
			fpsCounter = 0
			lastFPSUpdateTime = currentTime
		}

		// Get the captured image from ARFrame
		let pixelBuffer = frame.capturedImage

		// Convert to UIImage and resize/encode
		if let jpegData = encodeFrameToJPEG(pixelBuffer: pixelBuffer) {
			frameCount += 1
			onFrameEncoded?(jpegData)
		}
	}

	private func encodeFrameToJPEG(pixelBuffer: CVPixelBuffer) -> Data? {
		// Convert CVPixelBuffer to CIImage
		let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

		// Create context for rendering
		let context = CIContext(options: [.useSoftwareRenderer: false])

		// Calculate scale to maintain aspect ratio
		let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
		let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)

		let scaleX = CGFloat(targetWidth) / CGFloat(bufferWidth)
		let scaleY = CGFloat(targetHeight) / CGFloat(bufferHeight)
		let scale = min(scaleX, scaleY)

		// Apply scaling transform
		let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

		// Render to CGImage
		guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
			return nil
		}

		// Convert to UIImage and then to JPEG data
		let uiImage = UIImage(cgImage: cgImage)
		return uiImage.jpegData(compressionQuality: jpegQuality)
	}

	// Alternative: Get stats for debugging
	func getStats() -> String {
		return """
		Streaming: \(isStreaming)
		Frames: \(frameCount)
		FPS: \(String(format: "%.1f", currentFPS))
		Resolution: \(targetWidth)x\(targetHeight)
		Quality: \(Int(jpegQuality * 100))%
		"""
	}
}
