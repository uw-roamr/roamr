//
//  PageHeader.swift
//  roamr
//
//  Created by Anders Tai on 2025-11-05.
//

import SwiftUI

struct PageHeader<TrailingContent: View>: View {
	let title: String
	let statusText: String
	let statusColor: Color
	var titleColor: Color = .primary
	var statusTextColor: Color = .gray
	var infoText: String? = nil
	@ViewBuilder var trailingContent: () -> TrailingContent

	@State private var showingInfo = false

	var body: some View {
		HStack {
			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 8) {
					Text(title)
						.font(.largeTitle)
						.fontWeight(.bold)
						.foregroundColor(titleColor)

					if infoText != nil {
						Button {
							showingInfo = true
						} label: {
							Image(systemName: "info.circle")
								.font(.title3)
								.foregroundStyle(.secondary)
						}
					}
				}

				HStack(spacing: 6) {
					Circle()
						.fill(statusColor)
						.frame(width: 8, height: 8)
					Text(statusText)
						.font(.caption)
						.foregroundColor(statusTextColor)
				}
			}
			.padding()

			Spacer()

			trailingContent()
				.padding(.horizontal)
		}
		.overlay {
			if showingInfo, let info = infoText {
				InfoModal(text: info, isPresented: $showingInfo)
			}
		}
	}
}

extension PageHeader where TrailingContent == EmptyView {
	init(
		title: String,
		statusText: String,
		statusColor: Color,
		titleColor: Color = .primary,
		statusTextColor: Color = .gray,
		infoText: String? = nil
	) {
		self.title = title
		self.statusText = statusText
		self.statusColor = statusColor
		self.titleColor = titleColor
		self.statusTextColor = statusTextColor
		self.infoText = infoText
		self.trailingContent = { EmptyView() }
	}
}

struct InfoModal: View {
	let text: String
	@Binding var isPresented: Bool

	var body: some View {
		ZStack {
			// Dimmed background
			Color.black.opacity(0.5)
				.ignoresSafeArea()
				.onTapGesture {
					withAnimation(.easeOut(duration: 0.2)) {
						isPresented = false
					}
				}

			// Modal content
			VStack(spacing: 16) {
				HStack {
					Image(systemName: "info.circle.fill")
						.font(.title2)
						.foregroundStyle(.blue)
					Text("Info")
						.font(.headline)
					Spacer()
					Button {
						withAnimation(.easeOut(duration: 0.2)) {
							isPresented = false
						}
					} label: {
						Image(systemName: "xmark.circle.fill")
							.font(.title2)
							.foregroundStyle(.secondary)
					}
				}

				Text(text)
					.font(.body)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.leading)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
			.padding(20)
			.background(
				RoundedRectangle(cornerRadius: 16)
					.fill(.ultraThinMaterial)
			)
			.padding(.horizontal, 32)
		}
		.transition(.opacity)
	}
}
