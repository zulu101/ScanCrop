import CoreGraphics
import XCTest
@testable import ScanCropCore

/// Synthetic flatbed scans: an off-white lid with a little noise, and textured photos.
private struct Photo {
    var rect: PhotoRect
    var sky = false     // pale top third, close to the lid colour
    var frame = false   // white print border
}

private func scan(_ w: Int, _ h: Int, _ photos: [Photo], noise: Float = 0.008, edgeStrip: Bool = false,
                  lid: (Float, Float, Float) = (0.97, 0.97, 0.955)) -> RGBImage {
    var img = RGBImage(width: w, height: h, fill: lid)
    var seed: UInt64 = 42
    func rnd() -> Float {  // deterministic, roughly normal
        var s: Float = 0
        for _ in 0..<4 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            s += Float(seed >> 40) / Float(1 << 24)
        }
        return (s - 2) * 1.7
    }
    for i in 0..<(w * h * 3) { img.pixels[i] += noise * rnd() }
    if edgeStrip {
        for y in 0..<h { for x in (w - 6)..<w { for c in 0..<3 { img.pixels[3 * (y * w + x) + c] *= 0.75 } } }
    }
    for p in photos {
        let r = p.rect
        let a = r.angle * .pi / 180
        let (s, c) = (sin(a), cos(a))
        let xs = r.corners.map(\.x), ys = r.corners.map(\.y)
        let bx0 = max(0, Int(xs.min()!) - 1), bx1 = min(w, Int(xs.max()!) + 2)
        let by0 = max(0, Int(ys.min()!) - 1), by1 = min(h, Int(ys.max()!) + 2)
        for y in by0..<by1 {
            for x in bx0..<bx1 {
                let dx = Double(x) + 0.5 - r.centerX, dy = Double(y) + 0.5 - r.centerY
                let u = c * dx + s * dy, v = -s * dx + c * dy
                guard abs(u) < r.width / 2, abs(v) < r.height / 2 else { continue }
                var px: (Float, Float, Float) = (
                    Float(0.35 + 0.2 * sin(u * 0.03) * cos(v * 0.02)),
                    Float(0.30 + 0.15 * cos(u * 0.017)),
                    Float(0.25 + 0.2 * sin(v * 0.04)))
                if p.sky && v < -r.height / 2 + 0.35 * r.height { px = (0.90, 0.93, 0.95) }
                if p.frame {
                    let f = 0.05 * min(r.width, r.height)
                    if abs(u) > r.width / 2 - f || abs(v) > r.height / 2 - f { px = (0.995, 0.995, 0.99) }
                }
                let i = 3 * (y * w + x)
                img.pixels[i] = px.0 + 0.01 * rnd()
                img.pixels[i + 1] = px.1 + 0.01 * rnd()
                img.pixels[i + 2] = px.2 + 0.01 * rnd()
            }
        }
    }
    return img
}

private func assertMatches(_ found: [PhotoRect], _ truth: [PhotoRect], sizeTolerance: Double = 8,
                           file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(found.count, truth.count, "\(found)", file: file, line: line)
    for t in truth {
        guard let f = found.min(by: {
            hypot($0.centerX - t.centerX, $0.centerY - t.centerY) < hypot($1.centerX - t.centerX, $1.centerY - t.centerY)
        }) else { continue }
        XCTAssertEqual(f.centerX, t.centerX, accuracy: 4, "\(f) vs \(t)", file: file, line: line)
        XCTAssertEqual(f.centerY, t.centerY, accuracy: 4, "\(f) vs \(t)", file: file, line: line)
        XCTAssertEqual(f.width, t.width, accuracy: sizeTolerance, "\(f) vs \(t)", file: file, line: line)
        XCTAssertEqual(f.height, t.height, accuracy: sizeTolerance, "\(f) vs \(t)", file: file, line: line)
        XCTAssertEqual(f.angle, t.angle, accuracy: 0.5, "\(f) vs \(t)", file: file, line: line)
    }
}

final class DetectorTests: XCTestCase {
    func testOneTiltedPhoto() {
        let t = PhotoRect(centerX: 900, centerY: 700, width: 900, height: 600, angle: 2.3)
        assertMatches(PhotoDetector.detect(in: scan(1700, 1400, [Photo(rect: t)])), [t])
    }

    func testUprightPhotoNeedsNoResampling() {
        let t = PhotoRect(centerX: 900, centerY: 700, width: 900, height: 600, angle: 0)
        let found = PhotoDetector.detect(in: scan(1700, 1400, [Photo(rect: t)]))
        XCTAssertEqual(found.first?.angle, 0)
    }

    func testSeveralPhotosInReadingOrder() {
        let truth = [
            PhotoRect(centerX: 500, centerY: 400, width: 600, height: 400, angle: 7),
            PhotoRect(centerX: 1300, centerY: 450, width: 500, height: 650, angle: -12),
            PhotoRect(centerX: 800, centerY: 1150, width: 700, height: 350, angle: 1),
        ]
        let found = PhotoDetector.detect(in: scan(1700, 1400, truth.map { Photo(rect: $0) }))
        assertMatches(found, truth)
        XCTAssertEqual(found.map { Int(($0.centerX / 100).rounded()) }, [5, 13, 8], "reading order")
    }

    func testPaleSkyAtTheEdgeIsKept() {
        // A plain Otsu threshold loses the sky and returns a photo a third too short.
        let t = PhotoRect(centerX: 900, centerY: 700, width: 900, height: 600, angle: 1.5)
        assertMatches(PhotoDetector.detect(in: scan(1700, 1400, [Photo(rect: t, sky: true)])), [t])
    }

    func testPhotoInTheCornerKeepsItsSize() {
        let t = PhotoRect(x: 0, y: 0, width: 900, height: 600)
        assertMatches(PhotoDetector.detect(in: scan(1700, 1400, [Photo(rect: t)])), [t])
    }

    func testScannerEdgeStripIsIgnored() {
        let t = PhotoRect(centerX: 1240, centerY: 700, width: 900, height: 600, angle: 0)
        assertMatches(PhotoDetector.detect(in: scan(1700, 1400, [Photo(rect: t)], edgeStrip: true)), [t])
    }

    func testSmallPassportPhoto() {
        let truth = [
            PhotoRect(centerX: 300, centerY: 300, width: 100, height: 130, angle: 4),
            PhotoRect(centerX: 900, centerY: 700, width: 900, height: 600, angle: 0),
        ]
        assertMatches(PhotoDetector.detect(in: scan(1700, 1400, truth.map { Photo(rect: $0) })), truth)
    }

    func testNoisyLid() {
        let t = PhotoRect(centerX: 900, centerY: 700, width: 900, height: 600, angle: -1)
        assertMatches(PhotoDetector.detect(in: scan(1700, 1400, [Photo(rect: t)], noise: 0.02)), [t])
    }

    func testEmptyScan() {
        XCTAssertTrue(PhotoDetector.detect(in: scan(800, 600, [])).isEmpty)
    }

    func testWithoutStraighteningRectanglesStayUpright() {
        let t = PhotoRect(centerX: 900, centerY: 700, width: 900, height: 600, angle: 3)
        let found = PhotoDetector.detect(in: scan(1700, 1400, [Photo(rect: t)]),
                                         settings: DetectionSettings(straighten: false))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].angle, 0)
        XCTAssertGreaterThan(found[0].width, 900)  // the bounding box of the tilted photo
    }

    func testPrintBorderIsRemovedOnlyWhenAsked() {
        // A grey lid, so the white border is visible against it.
        let t = PhotoRect(centerX: 900, centerY: 700, width: 900, height: 600, angle: 2)
        let img = scan(1700, 1400, [Photo(rect: t, frame: true)], lid: (0.80, 0.80, 0.79))
        let plain = PhotoDetector.detect(in: img)
        assertMatches(plain, [t])
        let trimmed = PhotoDetector.detect(in: img, settings: DetectionSettings(removePrintBorder: true))
        let inner = t.inset(by: 0.05 * 600)
        assertMatches(trimmed, [inner], sizeTolerance: 10)
    }

    func testPaleSkyIsNotMistakenForAPrintBorder() {
        let t = PhotoRect(centerX: 900, centerY: 700, width: 900, height: 600, angle: 0)
        let found = PhotoDetector.detect(in: scan(1700, 1400, [Photo(rect: t, sky: true)]),
                                         settings: DetectionSettings(removePrintBorder: true))
        assertMatches(found, [t])
    }
}

final class GeometryTests: XCTestCase {
    func testCornersAndContains() {
        let r = PhotoRect(centerX: 100, centerY: 50, width: 40, height: 20, angle: 0)
        let c = r.corners
        XCTAssertEqual(c[0].x, 80, accuracy: 1e-9)
        XCTAssertEqual(c[0].y, 40, accuracy: 1e-9)
        XCTAssertTrue(r.contains(x: 119, y: 59))
        XCTAssertFalse(r.contains(x: 121, y: 50))
    }

    func testTrimmedMovesTheCentreAlongTheTilt() {
        let r = PhotoRect(centerX: 0, centerY: 0, width: 100, height: 100, angle: 45)
        let t = r.trimmed(left: 10, top: 0, right: 0, bottom: 0)
        XCTAssertEqual(t.width, 90, accuracy: 1e-9)
        // Moved by 5 along the photo's x axis, which points down-right at 45°.
        XCTAssertEqual(t.centerX, 5 * cos(.pi / 4), accuracy: 1e-9)
        XCTAssertEqual(t.centerY, 5 * sin(.pi / 4), accuracy: 1e-9)
    }
}

final class RendererTests: XCTestCase {
    /// A white scan with one red photo, tilted by `angle`.
    private func cgScan(angle: Double) -> (CGImage, PhotoRect) {
        let (w, h) = (800, 600)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let rect = PhotoRect(centerX: 380, centerY: 260, width: 400, height: 250, angle: angle)
        // Corners are in y-down pixels; the context is y-up.
        let path = CGMutablePath()
        let pts = rect.corners.map { CGPoint(x: $0.x, y: Double(h) - $0.y) }
        path.addLines(between: pts)
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillPath()
        // A blue marker in the photo's own top-left corner, to check the orientation.
        let a = angle * .pi / 180
        let mu = -rect.width / 2 + 30, mv = -rect.height / 2 + 30
        let mx = rect.centerX + cos(a) * mu - sin(a) * mv
        let my = rect.centerY + sin(a) * mu + cos(a) * mv
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.9, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: mx - 12, y: Double(h) - my - 12, width: 24, height: 24))
        return (ctx.makeImage()!, rect)
    }

    private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let buf = PhotoRenderer.rgbImage(from: img)!
        let p = buf.rgb(x, y)
        return (Int(p.0 * 255), Int(p.1 * 255), Int(p.2 * 255))
    }

    func testEndToEndTiltedPhotoHasNoWhiteCorners() throws {
        let (img, truth) = cgScan(angle: 6)
        let buf = try XCTUnwrap(PhotoRenderer.rgbImage(from: img))
        let found = PhotoDetector.detect(in: buf)
        XCTAssertEqual(found.count, 1)
        let rect = try XCTUnwrap(found.first)
        XCTAssertEqual(rect.angle, truth.angle, accuracy: 0.5)
        let out = try XCTUnwrap(PhotoRenderer.render(img, rect: rect.inset(by: 2)))
        let (w, h) = (out.width, out.height)
        for (x, y) in [(1, 1), (w - 2, 1), (1, h - 2), (w - 2, h - 2), (w / 2, h / 2)] where !(x < 60 && y < 60) {
            let p = pixel(out, x, y)
            XCTAssertGreaterThan(p.0, 150, "red at \(x),\(y): \(p)")
            XCTAssertLessThan(p.1, 80, "not white at \(x),\(y): \(p)")
        }
        // The marker stays in the top-left corner: the photo is upright, not mirrored.
        let marker = pixel(out, 28, 28)
        XCTAssertGreaterThan(marker.2, 150, "\(marker)")
    }

    func testQuarterTurnsSwapTheSize() throws {
        let (img, truth) = cgScan(angle: 0)
        let rect = truth.inset(by: 2)
        let upright = try XCTUnwrap(PhotoRenderer.render(img, rect: rect))
        XCTAssertEqual(upright.width, 396)
        XCTAssertEqual(upright.height, 246)
        let turned = try XCTUnwrap(PhotoRenderer.render(img, rect: rect, quarterTurns: 1))
        XCTAssertEqual(turned.width, 246)
        XCTAssertEqual(turned.height, 396)
        // Turned clockwise: the marker moves from the top-left to the top-right corner.
        let marker = pixel(turned, turned.width - 28, 28)
        XCTAssertGreaterThan(marker.2, 150, "\(marker)")
    }

    func testUprightCropIsPixelExact() throws {
        let (img, truth) = cgScan(angle: 0)
        let out = try XCTUnwrap(PhotoRenderer.render(img, rect: truth))
        XCTAssertEqual(out.width, 400)
        XCTAssertEqual(out.height, 250)
        let p = pixel(out, 0, out.height - 1)
        XCTAssertGreaterThan(p.0, 190)
        XCTAssertLessThan(p.1, 40)
    }
}
