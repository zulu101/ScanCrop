import CoreGraphics
import Foundation
import ImageIO
import ScanCropCore
import UniformTypeIdentifiers

/// Reads scans from disk. Everything here runs off the main thread.
enum ScanLoader {
    /// File types that are accepted as scans.
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "bmp", "gif", "webp"]

    /// Size of the image the detector and the preview work on.
    static let previewSide = 2000

    struct Info {
        var width: Int
        var height: Int
    }

    enum LoadError: LocalizedError {
        case unreadable
        var errorDescription: String? { String(localized: "The file could not be read as an image.") }
    }

    /// Expands folders (including subfolders) into their image files, sorted by name.
    static func imageURLs(from urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let files = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants])
                var found: [URL] = []
                while let f = files?.nextObject() as? URL {
                    if imageExtensions.contains(f.pathExtension.lowercased()) { found.append(f) }
                }
                result += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if imageExtensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
    }

    static func info(of url: URL) throws -> Info {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw LoadError.unreadable }
        return Info(width: w, height: h)
    }

    /// A downscaled copy of the scan, at most `maxSide` pixels on its long side.
    /// EXIF orientation is ignored on purpose: crops are made on the stored pixels.
    static func preview(of url: URL, maxSide: Int = previewSide) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw LoadError.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw LoadError.unreadable
        }
        return img
    }

    /// The full-resolution scan.
    static func fullImage(of url: URL) throws -> (CGImage, [CFString: Any], CFString?) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw LoadError.unreadable }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        return (img, props, CGImageSourceGetType(src))
    }

    struct Analysis {
        var info: Info
        var thumbnail: CGImage
        var photos: [PhotoRect]   // in full-resolution pixels
    }

    /// Loads a scan, finds its photos and makes a small thumbnail for the list.
    static func analyze(_ url: URL, settings: DetectionSettings) throws -> Analysis {
        let info = try info(of: url)
        let preview = try preview(of: url)
        guard let buffer = PhotoRenderer.rgbImage(from: preview) else { throw LoadError.unreadable }
        let scale = Double(info.width) / Double(preview.width)
        let photos = PhotoDetector.detect(in: buffer, settings: settings).map { $0.scaled(by: scale) }
        let thumb = downscaled(preview, maxSide: 160) ?? preview
        return Analysis(info: info, thumbnail: thumb, photos: photos)
    }

    static func downscaled(_ image: CGImage, maxSide: Int) -> CGImage? {
        let f = Double(maxSide) / Double(max(image.width, image.height))
        guard f < 1 else { return image }
        let w = max(1, Int(Double(image.width) * f)), h = max(1, Int(Double(image.height) * f))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
