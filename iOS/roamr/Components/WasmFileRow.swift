//
//  WasmFileRow.swift
//  roamr
//
//  Remote WASM file card with download/run button
//

import SwiftUI

struct WasmFileRow: View {
    let file: WasmFile
    let isDownloaded: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let onDownload: () -> Void
    let onRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name)
                        .font(.headline)
                        .lineLimit(1)

                    Text(file.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                actionButton
            }

            if !file.description.isEmpty {
                Text(file.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 16) {
                Label(file.formattedFileSize, systemImage: "doc.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label("\(file.downloadCount)", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("by \(file.uploaderName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !file.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(file.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .cornerRadius(4)
                        }
                    }
                }
            }

            if isDownloading {
                ProgressView(value: downloadProgress)
                    .progressViewStyle(.linear)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }

    @ViewBuilder
    private var actionButton: some View {
        if isDownloading {
            ProgressView()
                .frame(width: 32, height: 32)
        } else if isDownloaded {
            Button(action: onRun) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.green)
            }
        } else {
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
            }
        }
    }
}
