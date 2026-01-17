//
//  CameraDepthView.swift
//  roamr
//
//  Created by Claude on 2026-01-13.
//

import SwiftUI

struct CameraDepthView: View {
    @Environment(\.safeAreaInsets) private var safeAreaInsets
    @ObservedObject private var avManager = AVManager.shared

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    // Camera Feed (top half)
                    Group {
                        if let cameraImage = avManager.cameraImage {
                            Image(uiImage: cameraImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height / 2)
                                .clipped()
                        } else {
                            Rectangle()
								.fill(.clear)
                        }
                    }
                    .frame(height: geometry.size.height / 2)
					.overlay {
						Text("VIDEO")
							.font(.caption.bold())
							.foregroundColor(.white)
							.padding(.horizontal, 8)
							.padding(.vertical, 4)
							.background(Color.black.opacity(0.5))
							.cornerRadius(4)
							.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
							.padding(16)
					}
					
					Divider()
						.frame(height: 2)

                    // Depth Map (bottom half)
                    Group {
                        if let depthImage = avManager.depthMapImage {
                            Image(uiImage: depthImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height / 2)
                                .clipped()
                        } else {
                            Rectangle()
								.fill(.clear)
                        }
                    }
                    .frame(height: geometry.size.height / 2)
					.overlay {
						Text("DEPTH")
							.font(.caption.bold())
							.foregroundColor(.white)
							.padding(.horizontal, 8)
							.padding(.vertical, 4)
							.background(Color.black.opacity(0.5))
							.cornerRadius(4)
							.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
							.padding(16)
					}
					
                }
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
//        .onDisappear {
//            avManager.stop()
//        }
    }
}
