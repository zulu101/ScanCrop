import CoreGraphics
import Foundation
import ImageIO
import ScanCropCore
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case original, jpeg, tiff, png, heic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: String(localized: "Same as scan")
        case .jpeg: "JPEG"
        case .tiff: String(localized: "TIFF (lossless)")
        case .png: String(localized: "PNG (lossless)")
        case .heic: "HEIC"
        }
    }

    var isLossy: Bool { self == .jpeg || self == .heic || self == .original }
}

struct ExportOptions {
    var format: ExportFormat = .original
    var quality: Double = 0.92
    /// Extra trim on each side, in per cent of the photo's shorter side.
    var extraTrimPercent: Double = 0
    var folder: URL
}

/// A scan's photos as they are exported: full-resolution rectangles plus quarter turns.
struct ExportJob: Sendable {
    var url: URL
    var photos: [(rect: PhotoRect, turns: Int)]
}

enum Exporter {
    enum ExportError: LocalizedError {
        case cannotRender, cannotWrite(String)
        var errorDescription: String? {
            switch self {
            case .cannotRender: String(localized: "A photo could not be cut out.")
            case .cannotWrite(let name): String(localized: "\(name) could not be saved.")
            }
        }
    }

    /// Writes every photo of one scan into `options.folder` and returns the new files.
    static func export(_ job: ExportJob, options: ExportOptions) throws -> [URL] {
        let (image, props, sourceType) = try ScanLoader.fullImage(of: job.url)
        let (type, ext) = destinationType(for: options.format, sourceType: sourceType)
        let stem = job.url.deletingPathExtension().lastPathComponent
        var written: [URL] = []
        for (index, photo) in job.photos.enumerated() {
            var rect = photo.rect
            if options.extraTrimPercent > 0 {
                rect = rect.inset(by: min(rect.width, rect.height) * options.extraTrimPercent / 100)
            }
            guard let cropped = PhotoRenderer.render(image, rect: rect, quarterTurns: photo.turns) else {
                throw ExportError.cannotRender
            }
            let name = job.photos.count == 1 ? stem : "\(stem)_\(index + 1)"
            let url = uniqueURL(in: options.folder, name: name, ext: ext)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
                throw ExportError.cannotWrite(url.lastPathComponent)
            }
            CGImageDestinationAddImage(dest, cropped, properties(from: props, options: options, type: type) as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw ExportError.cannotWrite(url.lastPathComponent) }
            written.append(url)
        }
        return written
    }

    static func destinationType(for format: ExportFormat, sourceType: CFString?) -> (CFString, String) {
        switch format {
        case .jpeg: return (UTType.jpeg.identifier as CFString, "jpg")
        case .tiff: return (UTType.tiff.identifier as CFString, "tif")
        case .png: return (UTType.png.identifier as CFString, "png")
        case .heic: return (UTType.heic.identifier as CFString, "heic")
        case .original:
            let source = sourceType.flatMap { UTType($0 as String) }
            if source == .png { return (UTType.png.identifier as CFString, "png") }
            if source == .tiff { return (UTType.tiff.identifier as CFString, "tif") }
            if source == .heic { return (UTType.heic.identifier as CFString, "heic") }
            return (UTType.jpeg.identifier as CFString, "jpg")
        }
    }

    /// Keeps resolution (DPI), EXIF and IPTC data of the scan; the colour profile travels with the image.
    static func properties(from source: [CFString: Any], options: ExportOptions, type: CFString) -> [CFString: Any] {
        var p: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if let dpi = source[kCGImagePropertyDPIWidth] { p[kCGImagePropertyDPIWidth] = dpi }
        if let dpi = source[kCGImagePropertyDPIHeight] { p[kCGImagePropertyDPIHeight] = dpi }
        if var exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            p[kCGImagePropertyExifDictionary] = exif
        }
        if let iptc = source[kCGImagePropertyIPTCDictionary] { p[kCGImagePropertyIPTCDictionary] = iptc }
        let t = UTType(type as String)
        if t == .jpeg || t == .heic {
            p[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        if t == .tiff {
            p[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5]  // LZW
        }
        return p
    }

    /// `name.ext`, or `name-2.ext`, `name-3.ext`, … if that file exists already.
    static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name)-\(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }
}
