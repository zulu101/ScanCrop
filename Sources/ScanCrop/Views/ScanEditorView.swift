import ScanCropCore
import SwiftUI

/// The selected scan with its photos: click to select, drag to move, drag an edge to resize,
/// drag on empty space to mark a photo by hand.
struct ScanEditorView: View {
    @Environment(ScanStore.self) private var store
    let item: ScanItem

    var body: some View {
        VStack(spacing: 0) {
            ScanCanvas(item: item)
                .task(id: item.id) { await store.loadPreview(for: item) }
            Divider()
            PhotoBar(item: item)
            Divider()
            ResultStrip(item: item)
        }
    }
}

// MARK: - Canvas

private struct Edges: OptionSet {
    let rawValue: Int
    static let left = Edges(rawValue: 1), right = Edges(rawValue: 2), top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
}

private enum DragMode {
    case create(start: CGPoint)
    case move(id: FoundPhoto.ID, original: PhotoRect, start: CGPoint)
    case resize(id: FoundPhoto.ID, original: PhotoRect, edges: Edges, start: CGPoint)
}

private struct ScanCanvas: View {
    @Environment(ScanStore.self) private var store
    let item: ScanItem
    @State private var mode: DragMode?
    @State private var current: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            let preview = store.preview(for: item)
            let size = scanSize(preview)
            let fit = fitRect(size, in: geo.size)
            let scale = size.width > 0 ? fit.width / size.width : 1
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .position(x: fit.midX, y: fit.midY)
                        .shadow(radius: 2)
                } else {
                    ProgressView()
                }
                Canvas { ctx, _ in
                    draw(in: &ctx, fit: fit, scale: scale)
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(fit: fit, scale: scale, size: size))
        }
        .clipped()
    }

    // MARK: Geometry

    /// The scan's size in full-resolution pixels (or the preview's while that is all we know).
    private func scanSize(_ preview: CGImage?) -> CGSize {
        if item.width > 0 { return CGSize(width: item.width, height: item.height) }
        if let preview { return CGSize(width: preview.width, height: preview.height) }
        return .zero
    }

    private func fitRect(_ size: CGSize, in area: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let pad: CGFloat = 16
        let avail = CGSize(width: max(1, area.width - 2 * pad), height: max(1, area.height - 2 * pad))
        let s = min(avail.width / size.width, avail.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (area.width - w) / 2, y: (area.height - h) / 2, width: w, height: h)
    }

    private func toView(_ x: Double, _ y: Double, fit: CGRect, scale: CGFloat) -> CGPoint {
        CGPoint(x: fit.minX + CGFloat(x) * scale, y: fit.minY + CGFloat(y) * scale)
    }

    private func toScan(_ p: CGPoint, fit: CGRect, scale: CGFloat) -> CGPoint {
        CGPoint(x: (p.x - fit.minX) / scale, y: (p.y - fit.minY) / scale)
    }

    // MARK: Drawing

    /// The rectangle as it looks right now, including a drag in progress.
    private func displayed(_ photo: FoundPhoto) -> PhotoRect {
        switch mode {
        case .move(let id, let original, let start)? where id == photo.id:
            var r = original
            r.centerX += current.x - start.x
            r.centerY += current.y - start.y
            return r
        case .resize(let id, let original, let edges, let start)? where id == photo.id:
            return resized(original, edges: edges, dx: current.x - start.x, dy: current.y - start.y)
        default:
            return photo.rect
        }
    }

    private func draw(in ctx: inout GraphicsContext, fit: CGRect, scale: CGFloat) {
        guard fit.width > 0 else { return }
        for (index, photo) in item.photos.enumerated() {
            let rect = displayed(photo)
            let pts = rect.corners.map { toView($0.x, $0.y, fit: fit, scale: scale) }
            var path = Path()
            path.addLines(pts)
            path.closeSubpath()
            let selected = photo.id == store.selectedPhoto
            ctx.fill(path, with: .color(.accentColor.opacity(selected ? 0.22 : 0.08)))
            ctx.stroke(path, with: .color(.accentColor), lineWidth: selected ? 3 : 2)
            if selected {
                for p in pts {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.accentColor))
                }
            }
            // The photo's number; an arrow marks its top edge after the quarter turns.
            let center = toView(rect.centerX, rect.centerY, fit: fit, scale: scale)
            let badge = CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28)
            ctx.fill(Path(ellipseIn: badge), with: .color(.accentColor))
            ctx.draw(Text("\(index + 1)").font(.headline).foregroundColor(.white), at: center)
            if photo.turns % 4 != 0 {
                ctx.draw(Text(Image(systemName: "arrow.clockwise")).font(.caption).foregroundColor(.accentColor),
                         at: CGPoint(x: center.x, y: center.y + 26))
            }
        }
        if case .create(let start)? = mode {
            let a = toView(start.x, start.y, fit: fit, scale: scale)
            let b = toView(current.x, current.y, fit: fit, scale: scale)
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            ctx.stroke(Path(r), with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
    }

    // MARK: Interaction

    private func edges(of rect: PhotoRect, at p: CGPoint, tolerance: Double) -> Edges {
        let a = rect.angle * .pi / 180
        let (s, c) = (sin(a), cos(a))
        let dx = Double(p.x) - rect.centerX, dy = Double(p.y) - rect.centerY
        let u = c * dx + s * dy, v = -s * dx + c * dy
        let (hw, hh) = (rect.width / 2, rect.height / 2)
        guard abs(u) <= hw + tolerance, abs(v) <= hh + tolerance else { return [] }
        var e: Edges = []
        if abs(u + hw) < tolerance { e.insert(.left) }
        if abs(u - hw) < tolerance { e.insert(.right) }
        if abs(v + hh) < tolerance { e.insert(.top) }
        if abs(v - hh) < tolerance { e.insert(.bottom) }
        return e
    }

    private func resized(_ r: PhotoRect, edges: Edges, dx: Double, dy: Double) -> PhotoRect {
        let a = r.angle * .pi / 180
        let (s, c) = (sin(a), cos(a))
        let du = c * dx + s * dy, dv = -s * dx + c * dy
        return r.trimmed(left: edges.contains(.left) ? du : 0,
                         top: edges.contains(.top) ? dv : 0,
                         right: edges.contains(.right) ? -du : 0,
                         bottom: edges.contains(.bottom) ? -dv : 0)
    }

    private func dragGesture(fit: CGRect, scale: CGFloat, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard fit.width > 0, item.width > 0 else { return }
                current = toScan(value.location, fit: fit, scale: scale)
                guard mode == nil else { return }
                let start = toScan(value.startLocation, fit: fit, scale: scale)
                let tolerance = 8 / Double(scale)
                if let sel = item.photos.first(where: { $0.id == store.selectedPhoto }) {
                    let e = edges(of: sel.rect, at: start, tolerance: tolerance)
                    if !e.isEmpty {
                        mode = .resize(id: sel.id, original: sel.rect, edges: e, start: start)
                        return
                    }
                }
                // The smallest photo under the pointer wins (photos may overlap after editing).
                if let hit = item.photos.filter({ $0.rect.contains(x: start.x, y: start.y) })
                    .min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) {
                    store.selectedPhoto = hit.id
                    mode = .move(id: hit.id, original: hit.rect, start: start)
                } else {
                    mode = .create(start: start)
                }
            }
            .onEnded { value in
                defer { mode = nil }
                guard let active = mode, item.width > 0 else { return }
                let moved = hypot(value.translation.width, value.translation.height) >= 3
                switch active {
                case .create(let start):
                    guard moved else {
                        store.selectedPhoto = nil
                        return
                    }
                    let x0 = max(0, min(start.x, current.x)), x1 = min(size.width, max(start.x, current.x))
                    let y0 = max(0, min(start.y, current.y)), y1 = min(size.height, max(start.y, current.y))
                    guard x1 - x0 > 20, y1 - y0 > 20 else { return }
                    store.addPhoto(PhotoRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), to: item)
                case .move(let id, let original, let start):
                    guard moved else { return }
                    store.update(item, photo: id) {
                        $0.rect = original
                        $0.rect.centerX += current.x - start.x
                        $0.rect.centerY += current.y - start.y
                    }
                case .resize(let id, let original, let edges, let start):
                    guard moved else { return }
                    let r = resized(original, edges: edges, dx: current.x - start.x, dy: current.y - start.y)
                    store.update(item, photo: id) { $0.rect = r }
                }
            }
    }
}

// MARK: - Bar below the scan

private struct PhotoBar: View {
    @Environment(ScanStore.self) private var store
    let item: ScanItem
    @State private var sensitivity = 1.0

    var body: some View {
        HStack(spacing: 12) {
            if let index = item.photos.firstIndex(where: { $0.id == store.selectedPhoto }) {
                let photo = item.photos[index]
                Text("Photo \(index + 1)")
                    .font(.headline)
                ControlGroup {
                    Button { store.update(item, photo: photo.id) { $0.turns -= 1 } } label: {
                        Label("Rotate Left", systemImage: "rotate.left")
                    }
                    Button { store.update(item, photo: photo.id) { $0.turns += 1 } } label: {
                        Label("Rotate Right", systemImage: "rotate.right")
                    }
                }
                .labelStyle(.iconOnly)
                .fixedSize()
                .help("Turn the saved photo by 90°")

                Stepper {
                    Text("Tilt \(photo.rect.angle, specifier: "%.1f")°")
                        .monospacedDigit()
                } onIncrement: {
                    store.update(item, photo: photo.id) { $0.rect.angle = tilt($0.rect.angle + 0.1) }
                } onDecrement: {
                    store.update(item, photo: photo.id) { $0.rect.angle = tilt($0.rect.angle - 0.1) }
                }
                .help("Fine-tune the straightening")

                Button(role: .destructive) {
                    store.deleteSelectedPhoto()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: [])
                .help("Not a photo: remove it (⌫)")
            } else if item.status == .ready || item.status == .waiting || item.status == .analyzing {
                Text("Click a photo to adjust it. Drag on empty space to mark a photo by hand.")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Text("Sensitivity")
                    .foregroundStyle(.secondary)
                Slider(value: $sensitivity, in: 0.5...2, onEditingChanged: { editing in
                    if !editing {
                        item.sensitivity = sensitivity
                        store.redetect(item, force: true)
                    }
                })
                .frame(width: 110)
                .help("For this scan only. Detects the photos again and discards changes made by hand.")
                Button("Detect Again") { store.redetect(item, force: true) }
                    .help("Discard changes made by hand and detect the photos again")
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { sensitivity = item.sensitivity ?? store.settings.sensitivity }
    }

    /// One decimal place, within ±45°; tiny values become exactly 0 (no resampling).
    private func tilt(_ v: Double) -> Double {
        let r = (min(max(v, -45), 45) * 10).rounded() / 10
        return abs(r) < 0.05 ? 0 : r
    }
}

// MARK: - The photos as they will be saved

private struct ResultStrip: View {
    @Environment(ScanStore.self) private var store
    let item: ScanItem

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(Array(item.photos.enumerated()), id: \.element.id) { index, photo in
                    ResultThumb(item: item, photo: photo, number: index + 1)
                }
                if item.photos.isEmpty, item.status == .ready {
                    Text("No photo found on this scan. Raise the sensitivity or drag a rectangle around the photo.")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 132)
    }
}

private struct ResultThumb: View {
    @Environment(ScanStore.self) private var store
    let item: ScanItem
    let photo: FoundPhoto
    let number: Int
    @State private var image: CGImage?

    private struct Key: Equatable {
        var rect: PhotoRect
        var turns: Int
        var hasPreview: Bool
    }

    var body: some View {
        let selected = store.selectedPhoto == photo.id
        let size = photo.rect.outputSize(quarterTurns: photo.turns)
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(height: 90)
            .frame(minWidth: 60)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: selected ? 3 : 0))
            Text("\(number) · \(size.width) × \(size.height)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .onTapGesture { store.selectedPhoto = photo.id }
        .task(id: Key(rect: photo.rect, turns: photo.turns, hasPreview: store.preview(for: item) != nil)) {
            guard let preview = store.preview(for: item), item.width > 0 else { return }
            let rect = photo.rect.scaled(by: Double(preview.width) / Double(item.width))
            let turns = photo.turns
            image = await Task.detached(priority: .userInitiated) {
                PhotoRenderer.render(preview, rect: rect, quarterTurns: turns)
                    .flatMap { ScanLoader.downscaled($0, maxSide: 240) }
            }.value
        }
    }
}
