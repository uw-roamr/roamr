//
//  WasmDebugView.swift
//  roamr
//
//  Debug screen showing map preview, planner overlays, WASM console output, and recording settings.
//

import SwiftUI
import UniformTypeIdentifiers

struct WasmDebugView: View {
    @ObservedObject private var wasmManager = WasmManager.shared
    @ObservedObject private var websocketManager = WebSocketManager.shared
    @State private var isMapExpanded = true
    @State private var isConsoleExpanded = true
    @State private var isRecordingExpanded = false

    @State private var recordingEnabled: Bool = WasmManager.shared.recordingEnabled
    @State private var recordingPath: String = WasmManager.shared.recordingPath
    @State private var selectedRecordingFolderPath: String? = WasmManager.shared.selectedRecordingFolderPath
    @State private var isShowingRecordingFolderPicker = false

    private var currentMapPreviewImage: UIImage? {
        if let data = wasmManager.latestBaseMapPNGData,
           let image = UIImage(data: data) {
            return image
        }
        if let data = wasmManager.latestMapJPEGData,
           let image = UIImage(data: data) {
            return image
        }
        return nil
    }

    private var displayedPlannerSnapshot: PlannerTelemetrySnapshot? {
        websocketManager.latestPlannerTelemetry
    }

    private var plannerStatusText: String {
        if let snapshot = displayedPlannerSnapshot {
            let modeText: String
            switch snapshot.plannerMode {
            case .directGoalDStar:
                modeText = "D* Lite"
            case .frontier:
                modeText = "Frontier"
            case .none:
                modeText = "Idle"
            }
            return "\(modeText) • live • seq \(snapshot.sequence) • path \(snapshot.pathGrid.count)"
        }
        return "No planner telemetry received yet."
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DisclosureGroup(isExpanded: $isMapExpanded) {
                        VStack(alignment: .leading, spacing: 10) {
                            if let image = currentMapPreviewImage {
                                PlannerDebugPreview(
                                    image: image,
                                    metadata: websocketManager.latestMapMetadata,
                                    snapshot: displayedPlannerSnapshot
                                )
                            } else {
                                Text("No map frame received yet.")
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 160)
                            }

                            Text(plannerStatusText)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)

                            if let snapshot = displayedPlannerSnapshot {
                                Text(plannerDetailText(for: snapshot))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Text(
                                "Frames: \(wasmManager.latestMapFrameCount)  Timestamp: " +
                                (wasmManager.latestMapTimestamp > 0
                                    ? String(format: "%.3f", wasmManager.latestMapTimestamp)
                                    : "n/a")
                            )
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.black.opacity(0.06))
                        )
                    } label: {
                        Text("Map Preview")
                            .font(.headline)
                    }

                    DisclosureGroup(isExpanded: $isConsoleExpanded) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                if wasmManager.logLines.isEmpty {
                                    Text("Run a WASM module to see host-side logs from the module here.")
                                        .foregroundColor(.secondary)
                                } else {
                                    ForEach(Array(wasmManager.logLines.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 400)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.black.opacity(0.06))
                        )
                    } label: {
                        Text("WASM Console")
                            .font(.headline)
                    }

                    DisclosureGroup(isExpanded: $isRecordingExpanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            Toggle("Enable sensor recording", isOn: $recordingEnabled)
                                .onChange(of: recordingEnabled) { _, isEnabled in
                                    WasmManager.shared.setRecordingEnabled(isEnabled)
                                }

                            TextField("Recording path", text: $recordingPath)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled(true)
                                .textFieldStyle(.roundedBorder)

                            HStack(spacing: 12) {
                                Button("Apply Path") {
                                    WasmManager.shared.setRecordingPath(recordingPath)
                                    recordingPath = WasmManager.shared.recordingPath
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Reset Path") {
                                    WasmManager.shared.resetRecordingPath()
                                    recordingPath = WasmManager.shared.recordingPath
                                }
                                .buttonStyle(.bordered)
                            }

                            HStack(spacing: 12) {
                                Button("Choose Folder") {
                                    isShowingRecordingFolderPicker = true
                                }
                                .buttonStyle(.borderedProminent)

                                Button("Clear Folder") {
                                    WasmManager.shared.clearRecordingFolderSelection()
                                    selectedRecordingFolderPath = WasmManager.shared.selectedRecordingFolderPath
                                }
                                .buttonStyle(.bordered)
                                .disabled(selectedRecordingFolderPath == nil)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Selected folder: \(selectedRecordingFolderPath ?? "None")")
                                Text("Guest path: \(WasmManager.shared.recordingGuestDirectoryPath())")
                                Text("Host path: \(WasmManager.shared.recordingsDirectoryURL()?.path ?? "Unavailable")")
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)

                            Text("Writes IMU, pose, RGB, and point-cloud logs from inside the WASM runtime. Changes apply on next module start.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.black.opacity(0.06))
                        )
                    } label: {
                        Text("Recording")
                            .font(.headline)
                    }
                }
                .padding()
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            recordingEnabled = WasmManager.shared.recordingEnabled
            recordingPath = WasmManager.shared.recordingPath
            selectedRecordingFolderPath = WasmManager.shared.selectedRecordingFolderPath
        }
        .fileImporter(
            isPresented: $isShowingRecordingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            do {
                let urls = try result.get()
                guard let url = urls.first else { return }
                try WasmManager.shared.setRecordingFolderURL(url)
                selectedRecordingFolderPath = WasmManager.shared.selectedRecordingFolderPath
            } catch {
                // silently ignore
            }
        }
    }

    private func plannerDetailText(for snapshot: PlannerTelemetrySnapshot) -> String {
        if snapshot.plannerMode == .frontier {
            let detail = snapshot.message.isEmpty ? "Incremental D* Lite internals are unavailable in frontier mode." : snapshot.message
            return "Frontier mode. \(detail)"
        }
        if !snapshot.message.isEmpty {
            return snapshot.message
        }
        return snapshot.success ? "Planner snapshot captured." : "Planner reported failure."
    }
}

private struct PlannerDebugPreview: View {
    let image: UIImage
    let metadata: MapMetadataSnapshot?
    let snapshot: PlannerTelemetrySnapshot?

    private var aspectRatio: CGFloat {
        let width = CGFloat(metadata?.width ?? max(Int(image.size.width), 1))
        let height = CGFloat(metadata?.height ?? max(Int(image.size.height), 1))
        return width / max(height, 1)
    }

    var body: some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()

            Canvas { context, size in
                guard let snapshot else { return }
                var mutableContext = context
                drawPlannerSnapshot(snapshot, in: size, using: &mutableContext)
            }
            .allowsHitTesting(false)
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func drawPlannerSnapshot(
        _ snapshot: PlannerTelemetrySnapshot,
        in size: CGSize,
        using context: inout GraphicsContext
    ) {
        let gridWidth = CGFloat(metadata?.width ?? max(Int(image.size.width), 1))
        let gridHeight = CGFloat(metadata?.height ?? max(Int(image.size.height), 1))
        guard gridWidth > 0, gridHeight > 0 else { return }

        let cellWidth = size.width / gridWidth
        let cellHeight = size.height / gridHeight

        func point(for cell: PlannerGridCell) -> CGPoint {
            CGPoint(
                x: (CGFloat(cell.x) + 0.5) * cellWidth,
                y: (gridHeight - CGFloat(cell.y) - 0.5) * cellHeight
            )
        }

        func rect(for cell: PlannerGridCell) -> CGRect {
            CGRect(
                x: CGFloat(cell.x) * cellWidth,
                y: (gridHeight - CGFloat(cell.y) - 1) * cellHeight,
                width: max(cellWidth, 1),
                height: max(cellHeight, 1)
            )
        }

        if snapshot.pathGrid.count >= 2 {
            var path = Path()
            path.move(to: point(for: snapshot.pathGrid[0]))
            for cell in snapshot.pathGrid.dropFirst() {
                path.addLine(to: point(for: cell))
            }
            context.stroke(
                path,
                with: .color(Color(red: 0.95, green: 0.2, blue: 0.52)),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            )
        }

        if let startCell = snapshot.startCell {
            let p = point(for: startCell)
            let marker = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: marker), with: .color(.white))
        }

        if let goalCell = snapshot.goalCell {
            let p = point(for: goalCell)
            let marker = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            context.stroke(
                Path(ellipseIn: marker),
                with: .color(.green),
                style: StrokeStyle(lineWidth: 2)
            )
        }

    }
}
