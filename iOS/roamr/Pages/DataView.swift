//
//  DataView.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-04.
//

import SwiftUI
import MapKit
import CoreMotion

struct DataView: View {
	@EnvironmentObject var lidarManager: LiDARManager
	@StateObject private var motionManager = MotionManager()
	@State private var region = MKCoordinateRegion(
		center: CLLocationCoordinate2D(latitude: 43.6532, longitude: -79.3832), // hardcoded to Toronto
		span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
	)

	private let cardSpacing: CGFloat = 12

	var body: some View {
		VStack(spacing: cardSpacing) {
			HStack(spacing: cardSpacing) {
				SensorCard {
					AccelerometerView(data: motionManager.acceleration)
				}

				SensorCard {
					NumberStreamView(numbers: lidarManager.pointsLog)
				}
			}

			HStack(spacing: cardSpacing) {
				SensorCard {
					GyroscopeView(rotation: motionManager.currentRotation)
				}

				SensorCard {
					MapView()
						.cornerRadius(20)
				}
			}
		}
		.padding(cardSpacing)
	}
}

struct SensorCard<Content: View>: View {
	let content: Content

	init(@ViewBuilder content: () -> Content) {
		self.content = content()
	}

	var body: some View {
		RoundedRectangle(cornerRadius: 20)
			.fill(.ultraThinMaterial)
			.shadow(radius: 6)
			.overlay {
				content
					.aspectRatio(1, contentMode: .fit)
			}
			.aspectRatio(1, contentMode: .fit)
	}
}

final class MotionManager: ObservableObject {
	private var motion = CMMotionManager()
	private var timer: Timer?

	@Published var acceleration: CMAcceleration = .init(x: 0, y: 0, z: 0)
	@Published var rotation: CMRotationRate = .init(x: 0, y: 0, z: 0)
	@Published var currentRotation: CMRotationRate = .init(x: 0, y: 0, z: 0)

	init() {
		startMotionUpdates()
	}

	func startMotionUpdates() {
		motion.startAccelerometerUpdates()
		motion.startGyroUpdates()

		timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
			if let data = self.motion.accelerometerData {
				self.acceleration = data.acceleration
			}

			let deltaTime = 0.1

			if let gyro = self.motion.gyroData {
				self.rotation = gyro.rotationRate

				self.currentRotation.x += gyro.rotationRate.x * deltaTime
				self.currentRotation.y += gyro.rotationRate.y * deltaTime
				self.currentRotation.z += gyro.rotationRate.z * deltaTime
			}
		}
	}
}

struct AccelerometerView: View {
	let data: CMAcceleration
	@State private var xData: [Double] = []
	@State private var yData: [Double] = []
	@State private var zData: [Double] = []

	private let maxSamples = 50

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			AxisGraph(values: xData, color: .red, label: "X")
			AxisGraph(values: yData, color: .green, label: "Y")
			AxisGraph(values: zData, color: .blue, label: "Z")
		}
		.padding()
		.onChange(of: data.x) { newData in
			xData.append(newData)
			if xData.count > maxSamples {
				xData.removeFirst()
			}
		}
		.onChange(of: data.y) { newData in
			yData.append(newData)
			if yData.count > maxSamples {
				yData.removeFirst()
			}
		}
		.onChange(of: data.z) { newData in
			zData.append(newData)
			if zData.count > maxSamples {
				zData.removeFirst()
			}
		}
	}

	private func appendData(_ newData: CMAcceleration) {

		yData.append(newData.y)
		zData.append(newData.z)

		if xData.count > maxSamples {
			xData.removeFirst()
			yData.removeFirst()
			zData.removeFirst()
		}
	}
}

struct AxisGraph: View {
	let values: [Double]
	let color: Color
	let label: String

	var body: some View {
		HStack(alignment: .center, spacing: 4) {
			Text(label)
				.font(.caption)
				.foregroundColor(color)
			GeometryReader { geometry in
				let w = geometry.size.width
				let h = geometry.size.height
				let maxY = (values.max() ?? 1)
				let minY = (values.min() ?? -1)
				let range = maxY - minY == 0 ? 1 : maxY - minY

				Path { path in
					for (i, val) in values.enumerated() {
						let x = Double(i) / Double(max(values.count - 1, 1)) * w
						let y = h - ((val - minY) / range * h)
						if i == 0 {
							path.move(to: CGPoint(x: x, y: y))
						} else {
							path.addLine(to: CGPoint(x: x, y: y))
						}
					}
				}
				.stroke(color, lineWidth: 2)
				.animation(.easeOut(duration: 0.2), value: values)
			}
			.frame(height: 40)
			.clipShape(RoundedRectangle(cornerRadius: 6))
		}
	}
}

struct NumberStreamView: View {
	let numbers: [Int]
	var body: some View {
		VStack(alignment: .trailing) {
			ForEach(numbers, id: \.self) { num in
				Text(String(num))
			}
		}
		.padding()
	}
}

struct GyroscopeView: View {
	let rotation: CMRotationRate
	var body: some View {
		VStack {
			RoundedRectangle(cornerRadius: 20)
				.fill(Color.blue.gradient)
				.frame(width: 100, height: 100)
				.rotation3DEffect(
					.radians(-rotation.x),
					axis: (x: 1, y: 0, z: 0)
				)
				.rotation3DEffect(
					.radians(rotation.y),
					axis: (x: 0, y: 1, z: 0)
				)
				.rotation3DEffect(
					.radians(rotation.z),
					axis: (x: 0, y: 0, z: 1)
				)
//				.shadow(radius: 10, x: rotation.y * 10, y: rotation.x * 10)
		}
		.padding()
	}
}

struct UserLocation: Identifiable {
	let id = UUID()
	let coordinate: CLLocationCoordinate2D
}

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
	private let manager = CLLocationManager()

	@Published var region = MKCoordinateRegion(
		center: CLLocationCoordinate2D(latitude: 43.6532, longitude: -79.3832),
		span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
	)

	@Published var userLocation: UserLocation?

	override init() {
		super.init()
		manager.delegate = self
		manager.requestWhenInUseAuthorization()
		manager.startUpdatingLocation()
	}

	func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
		guard let location = locations.first else { return }
		let coord = location.coordinate
		region = MKCoordinateRegion(
			center: coord,
			span: MKCoordinateSpan(latitudeDelta: 0.001, longitudeDelta: 0.001)
		)
		userLocation = UserLocation(coordinate: coord)
		manager.stopUpdatingLocation()
	}
}

struct MapView: View {
	@StateObject private var locationManager = LocationManager()

	var body: some View {
		Map(
			coordinateRegion: $locationManager.region,
			annotationItems: locationManager.userLocation != nil ? [locationManager.userLocation!] : []
		) { location in
			MapMarker(coordinate: location.coordinate, tint: .red)
		}
		.edgesIgnoringSafeArea(.all)
	}
}
