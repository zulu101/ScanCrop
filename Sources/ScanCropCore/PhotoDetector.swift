import Foundation

/// An RGB image with values in `0...1`, stored row by row (r, g, b, r, g, b, …).
public struct RGBImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height * 3, "RGBImage needs width × height × 3 values")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// A plain image of one colour.
    public init(width: Int, height: Int, fill: (Float, Float, Float)) {
        var px = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            px[3 * i] = fill.0
            px[3 * i + 1] = fill.1
            px[3 * i + 2] = fill.2
        }
        self.init(width: width, height: height, pixels: px)
    }

    @inline(__always) func rgb(_ x: Int, _ y: Int) -> (Float, Float, Float) {
        let i = 3 * (y * width + x)
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }

    /// Bilinear sample at a pixel position (pixel centres are at `x + 0.5`).
    func sample(_ x: Double, _ y: Double) -> (Float, Float, Float) {
        let fx = min(max(x - 0.5, 0), Double(width - 1))
        let fy = min(max(y - 0.5, 0), Double(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
        let a = rgb(x0, y0), b = rgb(x1, y0), c = rgb(x0, y1), d = rgb(x1, y1)
        func mix(_ p: Float, _ q: Float, _ r: Float, _ s: Float) -> Float {
            (p * (1 - tx) + q * tx) * (1 - ty) + (r * (1 - tx) + s * tx) * ty
        }
        return (mix(a.0, b.0, c.0, d.0), mix(a.1, b.1, c.1, d.1), mix(a.2, b.2, c.2, d.2))
    }
}

/// How photos are found on a scan.
public struct DetectionSettings: Equatable, Codable, Sendable {
    /// Higher finds fainter photo edges (e.g. a pale sky), lower ignores more dirt. `0.5...2`.
    public var sensitivity: Double
    /// Measure and correct the tilt of each photo. Off: upright rectangles only.
    public var straighten: Bool
    /// Also cut off the white border that many old prints have.
    public var removePrintBorder: Bool
    /// Ignore things smaller than this share of the scan's area.
    public var minimumArea: Double

    public init(sensitivity: Double = 1, straighten: Bool = true, removePrintBorder: Bool = false, minimumArea: Double = 0.003) {
        self.sensitivity = sensitivity
        self.straighten = straighten
        self.removePrintBorder = removePrintBorder
        self.minimumArea = minimumArea
    }
}

/// Finds photos lying on a flatbed scan.
///
/// 1. **Background:** the median colour of a ring just inside the scan's edge (the scanner lid).
/// 2. **Foreground:** pixels whose colour differs from the background by more than the lid's own
///    noise. Unlike a plain Otsu threshold this also keeps pale areas such as a sky at the edge of
///    a photo. Edge lines that are almost completely foreground (the dark edge of the scanner bed)
///    are cleared.
/// 3. **Clean-up:** closing fills gaps, opening removes dust and thin lines, holes are filled.
/// 4. **Photos:** each large connected area gets the minimum-area rectangle around its convex
///    hull (one side of that rectangle always lies on a hull edge), which measures the tilt.
///
/// Steps 3 and 4 follow PhotoCraft's `scancrop.rs` (MIT OR Apache-2.0), see NOTICE.
public enum PhotoDetector {
    /// The detection runs on an image of at most this many pixels per side.
    static let workingSize = 1200

    /// Finds the photos in `image`. The results are in `image`'s pixels, in reading order.
    public static func detect(in image: RGBImage, settings: DetectionSettings = .init()) -> [PhotoRect] {
        guard image.width >= 16, image.height >= 16 else { return [] }

        // Average k × k blocks into a small working image.
        let k = max(1, Int((Double(max(image.width, image.height)) / Double(workingSize)).rounded(.up)))
        let sw = (image.width + k - 1) / k
        let sh = (image.height + k - 1) / k
        var small = [Float](repeating: 0, count: sw * sh * 3)
        var count = [Float](repeating: 0, count: sw * sh)
        for y in 0..<image.height {
            let row = (y / k) * sw
            for x in 0..<image.width {
                let i = row + x / k
                let p = image.rgb(x, y)
                small[3 * i] += p.0
                small[3 * i + 1] += p.1
                small[3 * i + 2] += p.2
                count[i] += 1
            }
        }
        for i in 0..<(sw * sh) {
            let n = max(count[i], 1)
            small[3 * i] /= n
            small[3 * i + 1] /= n
            small[3 * i + 2] /= n
        }

        // Background: per-channel median of a ring two pixels inside the edge.
        let o = min(2, min(sw, sh) / 4)
        var ring: [Int] = []
        for x in o..<(sw - o) {
            ring.append(o * sw + x)
            ring.append((sh - 1 - o) * sw + x)
        }
        for y in o..<(sh - o) {
            ring.append(y * sw + o)
            ring.append(y * sw + sw - 1 - o)
        }
        var bg: [Float] = [0, 0, 0]
        for c in 0..<3 {
            bg[c] = median(ring.map { small[3 * $0 + c] })
        }
        let norm = Float(3).squareRoot()
        var dist = [Float](repeating: 0, count: sw * sh)
        for i in 0..<(sw * sh) {
            let dr = small[3 * i] - bg[0], dg = small[3 * i + 1] - bg[1], db = small[3 * i + 2] - bg[2]
            dist[i] = (dr * dr + dg * dg + db * db).squareRoot() / norm
        }
        let noise = median(ring.map { dist[$0] })
        let sensitivity = Float(min(max(settings.sensitivity, 0.25), 4))
        let noiseThreshold = max(0.025, 4 * noise) / sensitivity
        let threshold = min(noiseThreshold, max(otsu(dist), 0.04))

        var mask = dist.map { $0 > threshold }
        clearEdgeStrips(&mask, sw, sh)
        let r = max(1, max(sw, sh) / 200)
        mask = morph(mask, sw, sh, radius: r, dilate: true)    // close
        mask = morph(mask, sw, sh, radius: r, dilate: false)
        mask = morph(mask, sw, sh, radius: 2, dilate: false)   // open
        mask = morph(mask, sw, sh, radius: 2, dilate: true)
        fillHoles(&mask, sw, sh)

        let total = Double(sw * sh)
        var found: [PhotoRect] = []
        for comp in components(mask, sw, sh) where Double(comp.count) >= total * settings.minimumArea {
            // Corners of the component's boundary pixels.
            var pts: [(Double, Double)] = []
            for i in comp {
                let x = i % sw, y = i / sw
                let edge = x == 0 || y == 0 || x == sw - 1 || y == sh - 1
                    || !mask[i - 1] || !mask[i + 1] || !mask[i - sw] || !mask[i + sw]
                if edge {
                    let fx = Double(x), fy = Double(y)
                    pts.append((fx, fy)); pts.append((fx + 1, fy))
                    pts.append((fx, fy + 1)); pts.append((fx + 1, fy + 1))
                }
            }
            let hull = convexHull(pts)
            guard hull.count >= 3 else { continue }
            var rect = settings.straighten ? minimumAreaRect(hull) : boundingRect(hull)
            let longSide = max(rect.width, rect.height), shortSide = min(rect.width, rect.height)
            if shortSide < 2 || longSide / shortSide > 8 { continue }               // a strip, not a photo
            if Double(comp.count) / (rect.width * rect.height) < 0.6 { continue }  // not rectangular
            // Measurement precision is about 0.1°: treat less as upright, so no resampling is needed.
            if abs(rect.angle) < 0.15 { rect.angle = 0 }
            // Drop one working pixel on each side: it is half background.
            rect = rect.inset(by: 1).scaled(by: Double(k))
            if settings.removePrintBorder {
                rect = trimPrintBorder(rect, in: image)
            }
            found.append(rect)
        }
        return readingOrder(found)
    }

    // MARK: - Print border

    /// Cuts off a white border printed around the photo, if there is one on at least three sides.
    public static func trimPrintBorder(_ rect: PhotoRect, in image: RGBImage) -> PhotoRect {
        let w = Int(rect.width.rounded()), h = Int(rect.height.rounded())
        guard w >= 20, h >= 20 else { return rect }
        // Sample the photo upright, one sample per pixel.
        let a = rect.angle * .pi / 180
        let (s, c) = (sin(a), cos(a))
        var lum = [Float](repeating: 0, count: w * h)
        var sat = [Float](repeating: 0, count: w * h)
        for v in 0..<h {
            for u in 0..<w {
                let lu = Double(u) + 0.5 - rect.width / 2
                let lv = Double(v) + 0.5 - rect.height / 2
                let p = image.sample(rect.centerX + c * lu - s * lv, rect.centerY + s * lu + c * lv)
                lum[v * w + u] = 0.299 * p.0 + 0.587 * p.1 + 0.114 * p.2
                sat[v * w + u] = max(p.0, p.1, p.2) - min(p.0, p.1, p.2)
            }
        }
        func isBorder(_ idx: [Int]) -> Bool {
            var sum: Float = 0, sq: Float = 0, sumSat: Float = 0
            for i in idx {
                sum += lum[i]; sq += lum[i] * lum[i]; sumSat += sat[i]
            }
            let n = Float(idx.count)
            let mean = sum / n
            let sd = max(0, sq / n - mean * mean).squareRoot()
            return mean > 0.80 && sd < 0.06 && sumSat / n < 0.10
        }
        func row(_ v: Int) -> [Int] { (0..<w).map { v * w + $0 } }
        func col(_ u: Int) -> [Int] { (0..<h).map { $0 * w + u } }
        let maxH = Int(Double(h) * 0.15), maxW = Int(Double(w) * 0.15)
        var top = 0, bottom = 0, left = 0, right = 0
        while top < maxH, isBorder(row(top)) { top += 1 }
        while bottom < maxH, isBorder(row(h - 1 - bottom)) { bottom += 1 }
        while left < maxW, isBorder(col(left)) { left += 1 }
        while right < maxW, isBorder(col(w - 1 - right)) { right += 1 }
        // A real print border runs all round; a pale sky only touches one side.
        let minH = max(2, Int(Double(h) * 0.005)), minW = max(2, Int(Double(w) * 0.005))
        let sides = [top >= minH, bottom >= minH, left >= minW, right >= minW].filter { $0 }.count
        guard sides >= 3 else { return rect }
        return rect.trimmed(left: Double(left), top: Double(top), right: Double(right), bottom: Double(bottom))
    }

    // MARK: - Steps

    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    /// Otsu's threshold for values in `0...1`.
    static func otsu(_ values: [Float]) -> Float {
        let bins = 256
        var hist = [Double](repeating: 0, count: bins)
        for v in values {
            hist[Int(min(max(v, 0), 1) * Float(bins - 1))] += 1
        }
        let total = hist.reduce(0, +)
        var sum = 0.0
        for (i, h) in hist.enumerated() { sum += Double(i) * h }
        var wb = 0.0, sb = 0.0, best = 0.0, thr = 0
        for (i, h) in hist.enumerated() {
            wb += h
            if wb == 0 { continue }
            let wf = total - wb
            if wf == 0 { break }
            sb += Double(i) * h
            let mb = sb / wb, mf = (sum - sb) / wf
            let between = wb * wf * (mb - mf) * (mb - mf)
            if between > best { best = between; thr = i }
        }
        return (Float(thr) + 0.5) / Float(bins - 1)
    }

    /// Clears edge lines that are at least 80 % foreground (the scanner bed's dark edge), up to 3 % deep.
    static func clearEdgeStrips(_ mask: inout [Bool], _ w: Int, _ h: Int) {
        func clearRows(_ rows: [Int]) {
            for y in rows {
                let on = (0..<w).reduce(0) { $0 + (mask[y * w + $1] ? 1 : 0) }
                guard Double(on) >= 0.8 * Double(w) else { return }
                for x in 0..<w { mask[y * w + x] = false }
            }
        }
        func clearCols(_ cols: [Int]) {
            for x in cols {
                let on = (0..<h).reduce(0) { $0 + (mask[$1 * w + x] ? 1 : 0) }
                guard Double(on) >= 0.8 * Double(h) else { return }
                for y in 0..<h { mask[y * w + x] = false }
            }
        }
        let dy = max(1, h * 3 / 100), dx = max(1, w * 3 / 100)
        clearRows(Array(0..<dy))
        clearRows((0..<dy).map { h - 1 - $0 })
        clearCols(Array(0..<dx))
        clearCols((0..<dx).map { w - 1 - $0 })
    }

    /// Dilation or erosion with a square of side `2 × radius + 1`, done in two passes.
    /// Outside the image counts as background for dilation and as foreground for erosion,
    /// so photos that touch the scan's edge keep their full size.
    static func morph(_ mask: [Bool], _ w: Int, _ h: Int, radius r: Int, dilate: Bool) -> [Bool] {
        let full = 2 * r + 1
        let outside = dilate ? 0 : 1
        func pass(_ src: [Bool], horizontal: Bool) -> [Bool] {
            var out = [Bool](repeating: false, count: w * h)
            let lines = horizontal ? h : w
            let length = horizontal ? w : h
            var prefix = [Int](repeating: 0, count: length + 2 * r + 1)
            for line in 0..<lines {
                // prefix[i] = number of set pixels among padded positions 0..<i
                prefix[0] = 0
                for p in 0..<(length + 2 * r) {
                    let q = p - r
                    let v: Int
                    if q < 0 || q >= length {
                        v = outside
                    } else {
                        let idx = horizontal ? line * w + q : q * w + line
                        v = src[idx] ? 1 : 0
                    }
                    prefix[p + 1] = prefix[p] + v
                }
                for q in 0..<length {
                    let n = prefix[q + full] - prefix[q]
                    let idx = horizontal ? line * w + q : q * w + line
                    out[idx] = dilate ? n > 0 : n == full
                }
            }
            return out
        }
        return pass(pass(mask, horizontal: true), horizontal: false)
    }

    /// Sets every background pixel that cannot be reached from the image's edge (holes in photos).
    static func fillHoles(_ mask: inout [Bool], _ w: Int, _ h: Int) {
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        func seed(_ i: Int) {
            if !mask[i] && !outside[i] { outside[i] = true; stack.append(i) }
        }
        for x in 0..<w { seed(x); seed((h - 1) * w + x) }
        for y in 0..<h { seed(y * w); seed(y * w + w - 1) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0 { seed(i - 1) }
            if x < w - 1 { seed(i + 1) }
            if y > 0 { seed(i - w) }
            if y < h - 1 { seed(i + w) }
        }
        for i in 0..<(w * h) where !outside[i] { mask[i] = true }
    }

    /// 8-connected components, each as a list of pixel indices.
    static func components(_ mask: [Bool], _ w: Int, _ h: Int) -> [[Int]] {
        var seen = [Bool](repeating: false, count: w * h)
        var result: [[Int]] = []
        for start in 0..<(w * h) where mask[start] && !seen[start] {
            var comp: [Int] = []
            var stack = [start]
            seen[start] = true
            while let i = stack.popLast() {
                comp.append(i)
                let x = i % w, y = i / w
                for dy in -1...1 {
                    for dx in -1...1 {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                        let j = yy * w + xx
                        if mask[j] && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            result.append(comp)
        }
        return result
    }

    /// Convex hull (monotone chain), counter-clockwise in y-up terms.
    static func convexHull(_ input: [(Double, Double)]) -> [(Double, Double)] {
        var pts = input.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        // Remove duplicates.
        var unique: [(Double, Double)] = []
        for p in pts where unique.last.map({ $0.0 != p.0 || $0.1 != p.1 }) ?? true {
            unique.append(p)
        }
        pts = unique
        guard pts.count >= 3 else { return pts }
        func cross(_ o: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
            (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0)
        }
        var lower: [(Double, Double)] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [(Double, Double)] = []
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// The smallest rectangle around a convex hull; one of its sides lies on a hull edge.
    static func minimumAreaRect(_ hull: [(Double, Double)]) -> PhotoRect {
        var best: (area: Double, rect: PhotoRect)?
        for i in 0..<hull.count {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let th = atan2(b.1 - a.1, b.0 - a.0)
            let (s, c) = (sin(th), cos(th))
            let big = Double.greatestFiniteMagnitude
            var u0 = big, v0 = big, u1 = -big, v1 = -big
            for p in hull {
                let u = c * p.0 + s * p.1, v = -s * p.0 + c * p.1
                u0 = min(u0, u); u1 = max(u1, u); v0 = min(v0, v); v1 = max(v1, v)
            }
            let area = (u1 - u0) * (v1 - v0)
            if best == nil || area < best!.area {
                let cu = (u0 + u1) / 2, cv = (v0 + v1) / 2
                best = (area, PhotoRect(centerX: c * cu - s * cv, centerY: s * cu + c * cv,
                                        width: u1 - u0, height: v1 - v0, angle: th * 180 / .pi))
            }
        }
        var r = best!.rect
        // Normalise to -45…45°, swapping the sides for each quarter turn.
        while r.angle > 45 { r.angle -= 90; swap(&r.width, &r.height) }
        while r.angle < -45 { r.angle += 90; swap(&r.width, &r.height) }
        return r
    }

    static func boundingRect(_ pts: [(Double, Double)]) -> PhotoRect {
        let xs = pts.map(\.0), ys = pts.map(\.1)
        let x0 = xs.min()!, x1 = xs.max()!, y0 = ys.min()!, y1 = ys.max()!
        return PhotoRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Top to bottom in rows, then left to right.
    static func readingOrder(_ photos: [PhotoRect]) -> [PhotoRect] {
        guard let smallest = photos.map({ min($0.width, $0.height) }).min() else { return photos }
        let band = max(smallest, 1) / 3
        return photos.sorted {
            let ra = ($0.centerY / band).rounded(.down), rb = ($1.centerY / band).rounded(.down)
            return ra != rb ? ra < rb : $0.centerX < $1.centerX
        }
    }
}
