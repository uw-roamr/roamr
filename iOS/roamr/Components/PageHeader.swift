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
	@ViewBuilder var trailingContent: () -> TrailingContent

	var body: some View {
		HStack {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.largeTitle)
					.fontWeight(.bold)
					.foregroundColor(titleColor)

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
	}
}

extension PageHeader where TrailingContent == EmptyView {
	init(
		title: String,
		statusText: String,
		statusColor: Color,
		titleColor: Color = .primary,
		statusTextColor: Color = .gray
	) {
		self.title = title
		self.statusText = statusText
		self.statusColor = statusColor
		self.titleColor = titleColor
		self.statusTextColor = statusTextColor
		self.trailingContent = { EmptyView() }
	}
}
