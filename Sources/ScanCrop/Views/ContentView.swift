import SwiftUI

struct ContentView: View {
    @Environment(ScanStore.self) private var store
    @State private var showingDetection = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            ScanListView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            if let item = store.selectedItem {
                ScanEditorView(item: item)
                    .id(item.id)
            } else {
                ContentUnavailableView {
                    Label("Drop Scans Here", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Drag scans or a whole folder into this window. ScanCrop finds the photos on each scan, straightens them and cuts away the white background.")
                } actions: {
                    Button("Add Scans…") { store.showOpenPanel() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("ScanCrop")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.showOpenPanel()
                } label: {
                    Label("Add Scans…", systemImage: "plus")
                }
                .help("Add scans or a folder of scans")

                Button {
                    showingDetection.toggle()
                } label: {
                    Label("Detection", systemImage: "slider.horizontal.3")
                }
                .help("How photos are found")
                .popover(isPresented: $showingDetection, arrowEdge: .bottom) {
                    DetectionSettingsView()
                }

                Button {
                    store.showingExport = true
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .help("Save all photos into a folder")
                .disabled(store.photoCount == 0)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.add(urls)
            return true
        }
        .sheet(isPresented: $store.showingExport) {
            ExportView()
        }
    }
}

struct DetectionSettingsView: View {
    @Environment(ScanStore.self) private var store
    @State private var sensitivity = 1.0

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                LabeledContent("Sensitivity") {
                    Slider(value: $sensitivity, in: 0.5...2, onEditingChanged: { editing in
                        if !editing { store.settings.sensitivity = sensitivity }
                    })
                    .frame(width: 180)
                }
                Text("Higher finds pale photo edges such as a bright sky. Lower ignores dust and shadows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Straighten tilted photos", isOn: $store.settings.straighten)
                Toggle("Remove white print borders", isOn: $store.settings.removePrintBorder)
                Text("Removes the white border that many old prints have, when it runs around at least three sides.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text("Changes are applied to all scans right away. Scans you have corrected by hand are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear { sensitivity = store.settings.sensitivity }
    }
}
