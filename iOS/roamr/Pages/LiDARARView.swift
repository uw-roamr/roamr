//
//  LiDARARView.swift
//  Capstone MVP
//
//  Created by Anders Tai on 2025-09-22.
//


import SwiftUI
import RealityKit
import ARKit

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
		}
		.onDisappear() {
			lidarManager.stopSession()
			withAnimation {
				lidarManager.showDataSheet = false
			}
		}
	}
}
