import AppKit
import SwiftUI

struct ScanListView: View {
    @Environment(ScanStore.self) private var store
    @State private var listSelection: Set<ScanItem.ID> = []

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $listSelection) {
                ForEach(store.items) { item in
                    ScanRow(item: item)
                        .tag(item.id)
                        .contextMenu {
                            Button("Detect Photos Again") { store.redetect(item, force: true) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            Divider()
                            Button("Remove from List") { store.remove(selectionOrItem(item)) }
                        }
                }
            }
            .onDeleteCommand { store.remove(listSelection) }
            Divider()
            footer
        }
        .onChange(of: listSelection) { _, new in
            // The editor shows one scan: the one clicked last.
            if new.count == 1, let id = new.first, id != store.selection {
                store.selection = id
                store.selectedPhoto = nil
            }
        }
        .onChange(of: store.selection, initial: true) { _, new in
            if let new, !listSelection.contains(new) { listSelection = [new] }
        }
    }

    private func selectionOrItem(_ item: ScanItem) -> Set<ScanItem.ID> {
        listSelection.contains(item.id) ? listSelection : [item.id]
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 6) {
            if store.isAnalyzing {
                ProgressView(value: Double(store.analyzedCount), total: Double(max(store.items.count, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 60)
            }
            Text("\(store.items.count) scans · \(store.photoCount) photos")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct ScanRow: View {
    let item: ScanItem

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumb = item.thumbnail {
                    Image(decorative: thumb, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                }
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
                    .font(.caption)
            }
            Spacer(minLength: 0)
            if item.edited {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                    .help("Corrected by hand")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .waiting:
            Text("Waiting…").foregroundStyle(.secondary)
        case .analyzing:
            Text("Looking for photos…").foregroundStyle(.secondary)
        case .ready:
            switch item.photos.count {
            case 0: Label("No photo found", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            case 1: Text("1 photo").foregroundStyle(.secondary)
            default: Text("\(item.photos.count) photos").foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }
}
