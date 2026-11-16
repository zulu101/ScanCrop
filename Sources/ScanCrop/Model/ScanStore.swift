import AppKit
import Foundation
import Observation
import ScanCropCore

/// One photo found on a scan, as the user sees and edits it.
struct FoundPhoto: Identifiable, Equatable {
    let id = UUID()
    /// In the scan's full-resolution pixels.
    var rect: PhotoRect
    /// Extra clockwise quarter turns, e.g. for a photo that lies on its side.
    var turns: Int = 0
}

@Observable
final class ScanItem: Identifiable {
    enum Status: Equatable {
        case waiting, analyzing, ready, failed(String)
    }

    let id = UUID()
    let url: URL
    var status: Status = .waiting
    var width = 0
    var height = 0
    var thumbnail: CGImage?
    var photos: [FoundPhoto] = []
    /// The user changed the photos by hand: a new detection must not overwrite them.
    var edited = false
    /// Sensitivity for this scan only; `nil` uses the global setting.
    var sensitivity: Double?

    init(url: URL) { self.url = url }

    var name: String { url.lastPathComponent }
}

@MainActor
@Observable
final class ScanStore {
    var items: [ScanItem] = []
    var selection: ScanItem.ID?
    var selectedPhoto: FoundPhoto.ID?

    var settings: DetectionSettings {
        didSet { saveSettings(); redetectAll() }
    }

    var showingExport = false
    var exportProgress: Double?
    var exportMessage: String?
    var lastExportFolder: URL?

    private var queue: [ScanItem] = []
    private var running = 0
    private let maxParallel = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount - 2))

    /// Large previews of the most recently viewed scans.
    private var previews: [URL: CGImage] = [:]
    private var previewOrder: [URL] = []

    init() {
        let d = UserDefaults.standard
        settings = DetectionSettings(
            sensitivity: d.object(forKey: "sensitivity") as? Double ?? 1,
            straighten: d.object(forKey: "straighten") as? Bool ?? true,
            removePrintBorder: d.bool(forKey: "removePrintBorder"))
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        d.set(settings.sensitivity, forKey: "sensitivity")
        d.set(settings.straighten, forKey: "straighten")
        d.set(settings.removePrintBorder, forKey: "removePrintBorder")
    }

    var selectedItem: ScanItem? { items.first { $0.id == selection } }

    var photoCount: Int { items.reduce(0) { $0 + $1.photos.count } }
    var isAnalyzing: Bool { running > 0 || !queue.isEmpty }
    var analyzedCount: Int { items.filter { $0.status != .waiting && $0.status != .analyzing }.count }

    // MARK: - Adding and removing

    func add(_ urls: [URL]) {
        let known = Set(items.map(\.url.standardizedFileURL))
        let new = ScanLoader.imageURLs(from: urls)
            .filter { !known.contains($0.standardizedFileURL) }
            .map(ScanItem.init(url:))
        guard !new.isEmpty else { return }
        items += new
        if selection == nil { selection = new.first?.id }
        queue += new
        pump()
    }

    func remove(_ ids: Set<ScanItem.ID>) {
        items.removeAll { ids.contains($0.id) }
        queue.removeAll { ids.contains($0.id) }
        if let s = selection, ids.contains(s) { selection = items.first?.id }
    }

    func removeAll() {
        items = []
        queue = []
        selection = nil
        previews = [:]
        previewOrder = []
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .folder]
        panel.message = String(localized: "Choose scans or a folder of scans")
        if panel.runModal() == .OK { add(panel.urls) }
    }

    // MARK: - Detection

    func detectionSettings(for item: ScanItem) -> DetectionSettings {
        var s = settings
        if let own = item.sensitivity { s.sensitivity = own }
        return s
    }

    /// Detects the photos again, e.g. after a settings change. Hand-edited scans are kept
    /// unless `force` is set.
    func redetect(_ item: ScanItem, force: Bool = false) {
        guard force || !item.edited else { return }
        if force { item.edited = false }
        if !queue.contains(where: { $0 === item }) { queue.append(item) }
        item.status = .waiting
        pump()
    }

    func redetectAll() {
        for item in items where !item.edited { redetect(item) }
    }

    private func pump() {
        while running < maxParallel, !queue.isEmpty {
            let item = queue.removeFirst()
            running += 1
            item.status = .analyzing
            let url = item.url
            let s = detectionSettings(for: item)
            Task.detached(priority: .userInitiated) {
                let result = Result { try ScanLoader.analyze(url, settings: s) }
                await MainActor.run {
                    self.running -= 1
                    switch result {
                    case .success(let a):
                        item.width = a.info.width
                        item.height = a.info.height
                        item.thumbnail = a.thumbnail
                        if !item.edited { item.photos = a.photos.map { FoundPhoto(rect: $0) } }
                        item.status = .ready
                    case .failure(let error):
                        item.status = .failed(error.localizedDescription)
                    }
                    self.pump()
                }
            }
        }
    }

    // MARK: - Editing

    func update(_ item: ScanItem, photo id: FoundPhoto.ID, _ change: (inout FoundPhoto) -> Void) {
        guard let i = item.photos.firstIndex(where: { $0.id == id }) else { return }
        change(&item.photos[i])
        item.edited = true
    }

    func addPhoto(_ rect: PhotoRect, to item: ScanItem) {
        let photo = FoundPhoto(rect: rect)
        item.photos.append(photo)
        item.edited = true
        selectedPhoto = photo.id
    }

    func deleteSelectedPhoto() {
        guard let item = selectedItem, let id = selectedPhoto else { return }
        item.photos.removeAll { $0.id == id }
        item.edited = true
        selectedPhoto = nil
    }

    func select(offset: Int) {
        guard let current = items.firstIndex(where: { $0.id == selection }) else {
            selection = items.first?.id
            return
        }
        let next = current + offset
        if items.indices.contains(next) {
            selection = items[next].id
            selectedPhoto = nil
        }
    }

    // MARK: - Previews

    func preview(for item: ScanItem) -> CGImage? { previews[item.url] }

    func loadPreview(for item: ScanItem) async {
        if previews[item.url] != nil { return }
        let url = item.url
        let image = await Task.detached(priority: .userInitiated) { try? ScanLoader.preview(of: url) }.value
        guard let image else { return }
        previews[url] = image
        previewOrder.removeAll { $0 == url }
        previewOrder.append(url)
        while previewOrder.count > 6 {
            previews.removeValue(forKey: previewOrder.removeFirst())
        }
    }

    // MARK: - Export

    func export(options: ExportOptions) {
        let jobs = items.filter { !$0.photos.isEmpty }
            .map { item in
                ExportJob(url: item.url, photos: item.photos.map { photo in (rect: photo.rect, turns: photo.turns) })
            }
        guard !jobs.isEmpty else { return }
        exportProgress = 0
        exportMessage = nil
        lastExportFolder = options.folder
        Task.detached(priority: .userInitiated) {
            var written = 0
            var failures: [String] = []
            for (i, job) in jobs.enumerated() {
                do {
                    written += try Exporter.export(job, options: options).count
                } catch {
                    failures.append("\(job.url.lastPathComponent): \(error.localizedDescription)")
                }
                let progress = Double(i + 1) / Double(jobs.count)
                await MainActor.run { self.exportProgress = progress }
            }
            let summary = failures.isEmpty
                ? String(localized: "\(written) photos saved.")
                : String(localized: "\(written) photos saved, \(failures.count) scans failed:") + "\n" + failures.joined(separator: "\n")
            await MainActor.run {
                self.exportProgress = nil
                self.exportMessage = summary
            }
        }
    }
}
