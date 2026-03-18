//
//  LocalWasmBundleRow.swift
//  roamr
//
//  Imported WASM ML bundle row with select/delete actions.
//

import SwiftUI

struct LocalWasmBundleRow: View {
    let bundle: LocalWasmBundle
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? .green : .secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(bundle.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(bundle.entryWasmFileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Label(bundle.formattedFileSize, systemImage: "shippingbox.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Text(bundle.formattedImportDate)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .background(isSelected ? Color.green.opacity(0.1) : Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
}
