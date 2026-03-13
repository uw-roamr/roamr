//
//  JoystickView.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-23.
//

import SwiftUI

struct JoystickView: View {
    let size: CGFloat
    let onUpdate: (Int, Int, Int) -> Void // (leftMotor, rightMotor, duration)

    @State private var leftValue: Double = 0
    @State private var rightValue: Double = 0
    @State private var leftIsActive = false
    @State private var rightIsActive = false
    @State private var timer: Timer?

    private let sendInterval: TimeInterval = 0.05 // 50ms
    private let holdDuration: Int = 100 // 100ms duration for ESP32
    private let maxCommand: Double = 50

    init(size: CGFloat = 250, onUpdate: @escaping (Int, Int, Int) -> Void) {
        self.size = size
        self.onUpdate = onUpdate
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 36) {
                WheelSlider(
                    title: "Left",
                    value: $leftValue,
                    tint: .blue,
                    height: size,
                    maxCommand: maxCommand,
                    onInteractionChanged: { isActive in
                        updateInteraction(for: .left, isActive: isActive)
                    }
                )

                WheelSlider(
                    title: "Right",
                    value: $rightValue,
                    tint: .green,
                    height: size,
                    maxCommand: maxCommand,
                    onInteractionChanged: { isActive in
                        updateInteraction(for: .right, isActive: isActive)
                    }
                )
            }
            .frame(width: max(size, 220))

            Text("L: \(currentLeftValue)% R: \(currentRightValue)%")
                .font(.caption)
                .padding(8)
                .background(Color.black.opacity(0.7))
                .foregroundColor(.white)
                .cornerRadius(8)
        }
        .onDisappear {
            stopSendingUpdates()
            leftValue = 0
            rightValue = 0
            onUpdate(0, 0, holdDuration)
        }
    }

    private var currentLeftValue: Int {
        Int(leftValue.rounded())
    }

    private var currentRightValue: Int {
        Int(rightValue.rounded())
    }

    private func updateInteraction(for side: WheelSide, isActive: Bool) {
        switch side {
        case .left:
            leftIsActive = isActive
        case .right:
            rightIsActive = isActive
        }

        if isActive {
            startSendingUpdates()
        } else if !leftIsActive && !rightIsActive {
            stopSendingUpdates()
        }

        sendCurrentValues()
    }

    private func sendCurrentValues() {
        onUpdate(currentLeftValue, currentRightValue, holdDuration)
    }

    private func startSendingUpdates() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: sendInterval, repeats: true) { _ in
            sendCurrentValues()
        }
    }

    private func stopSendingUpdates() {
        timer?.invalidate()
        timer = nil
    }
}

private extension JoystickView {
    enum WheelSide {
        case left
        case right
    }
}

private struct WheelSlider: View {
    let title: String
    @Binding var value: Double
    let tint: Color
    let height: CGFloat
    let maxCommand: Double
    let onInteractionChanged: (Bool) -> Void

    private let width: CGFloat = 84
    private let thumbDiameter: CGFloat = 54

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)

            GeometryReader { geometry in
                let trackHeight = max(geometry.size.height - thumbDiameter, 1)

                ZStack {
                    RoundedRectangle(cornerRadius: width / 2)
                        .fill(Color.gray.opacity(0.12))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 4)

                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(height: 2)

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.8), tint],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .shadow(color: .black.opacity(0.2), radius: 5, x: 0, y: 2)
                        .offset(y: thumbOffset(trackHeight: trackHeight))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            value = valueFrom(locationY: gesture.location.y, sliderHeight: geometry.size.height)
                            onInteractionChanged(true)
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.72)) {
                                value = 0
                            }
                            onInteractionChanged(false)
                        }
                )
            }
            .frame(width: width, height: height)

            Text("\(Int(value.rounded()))%")
                .font(.subheadline.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    private func thumbOffset(trackHeight: CGFloat) -> CGFloat {
        let normalized = CGFloat(value / 100)
        return -normalized * (trackHeight / 2)
    }

    private func valueFrom(locationY: CGFloat, sliderHeight: CGFloat) -> Double {
        let usableHeight = max(sliderHeight - thumbDiameter, 1)
        let clampedY = min(max(locationY - (thumbDiameter / 2), 0), usableHeight)
        let normalized = 1 - (clampedY / usableHeight)
        return (normalized * (maxCommand * 2)) - maxCommand
    }
}
