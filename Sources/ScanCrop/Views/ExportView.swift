import AppKit
import SwiftUI

struct ExportView: View {
    @Environment(ScanStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @AppStorage("exportFormat") private var format: ExportFormat = .original
    @AppStorage("exportQuality") private var quality = 0.92
    @AppStorage("exportExtraTrim") private var extraTrim = 0.0
    @AppStorage("exportFolder") private var folderPath = ""

    private var folder: URL? { folderPath.isEmpty ? nil : URL(fileURLWithPath: folderPath) }
    private var scansWithPhotos: Int { store.items.filter { !$0.photos.isEmpty }.count }
    private var scansWithout: Int { store.items.filter { $0.status == .ready && $0.photos.isEmpty }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
                    }
                    if format.isLossy {
                        LabeledContent("Quality") {
                            HStack {
                                Slider(value: $quality, in: 0.6...1)
                                Text(verbatim: "\(Int((quality * 100).rounded())) %")
                                    .monospacedDigit()
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                    LabeledContent("Extra trim") {
                        HStack {
                            Slider(value: $extraTrim, in: 0...3, step: 0.25)
                            Text(verbatim: String(format: "%.2f %%", extraTrim))
                                .monospacedDigit()
                                .frame(width: 54, alignment: .trailing)
                        }
                    }
                    Text("Cuts a little more off every side if thin white lines remain at the edges.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Save to") {
                        HStack {
                            Text(folder?.path(percentEncoded: false) ?? String(localized: "No folder chosen"))
                                .lineLimit(1)
                                .truncationMode(.head)
                                .foregroundStyle(folder == nil ? .secondary : .primary)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                    Text("Files are named after the scan; several photos on one scan get _1, _2, … Existing files are never replaced. Resolution (DPI), colour profile and metadata are kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let progress = store.exportProgress {
                    Section {
                        ProgressView(value: progress) { Text("Saving photos…") }
                    }
                } else if let message = store.exportMessage {
                    Section {
                        Text(message)
                            .textSelection(.enabled)
                        if let f = store.lastExportFolder {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.photoCount) photos from \(scansWithPhotos) scans")
                    if scansWithout > 0 {
                        Text("\(scansWithout) scans without a photo are skipped.")
                            .foregroundStyle(.orange)
                    }
                    if store.isAnalyzing {
                        Text("Some scans are still being analysed.")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                Spacer()
                Button(store.exportMessage == nil ? LocalizedStringKey("Cancel") : LocalizedStringKey("Close")) {
                    store.exportMessage = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(store.exportProgress != nil)
                Button("Export") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(folder == nil || store.photoCount == 0 || store.exportProgress != nil)
            }
            .padding()
        }
        .frame(width: 520)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose the folder for the finished photos")
        if let folder { panel.directoryURL = folder }
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }

    private func export() {
        guard let folder else { return }
        store.export(options: ExportOptions(format: format, quality: quality, extraTrimPercent: extraTrim, folder: folder))
    }
}
