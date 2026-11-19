import CoreGraphics
import Foundation

/// Cuts a photo out of a scan and turns it upright.
public enum PhotoRenderer {
    /// Renders `rect` (in `image`'s pixels) upright, then turned clockwise by `quarterTurns` × 90°.
    ///
    /// An upright rectangle without extra turns is copied pixel for pixel. Everything else is
    /// resampled once with high-quality interpolation. Colour space and bit depth of the scan
    /// are kept where Core Graphics can draw into them (RGB and greyscale, 8 or 16 bit).
    public static func render(_ image: CGImage, rect: PhotoRect, quarterTurns: Int = 0) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        if rect.angle == 0 {
            // Snap to whole pixels and crop without resampling.
            let x0 = max(0, Int(rect.centerX - rect.width / 2 + 0.5))
            let y0 = max(0, Int(rect.centerY - rect.height / 2 + 0.5))
            let x1 = min(image.width, x0 + max(1, Int(rect.width.rounded())))
            let y1 = min(image.height, y0 + max(1, Int(rect.height.rounded())))
            guard x1 > x0, y1 > y0,
                  let cropped = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            else { return nil }
            if turns == 0 { return cropped }
            let whole = PhotoRect(x: 0, y: 0, width: Double(cropped.width), height: Double(cropped.height))
            return draw(cropped, rect: whole, turns: turns, interpolation: .none)
        }
        return draw(image, rect: rect, turns: turns, interpolation: .high)
    }

    private static func draw(_ image: CGImage, rect: PhotoRect, turns: Int, interpolation: CGInterpolationQuality) -> CGImage? {
        let size = rect.outputSize(quarterTurns: turns)
        guard let ctx = makeContext(like: image, width: size.width, height: size.height) else { return nil }
        ctx.interpolationQuality = interpolation
        // Work in y-down coordinates, like the scan's pixels.
        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)
        // output = rotate(scan − centre) + output centre
        ctx.translateBy(x: CGFloat(size.width) / 2, y: CGFloat(size.height) / 2)
        let degrees = -rect.angle + Double(turns) * 90
        ctx.rotate(by: CGFloat(degrees * .pi / 180))
        ctx.translateBy(x: -CGFloat(rect.centerX), y: -CGFloat(rect.centerY))
        // Draw the scan upright inside the flipped space.
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// A bitmap context with the scan's colour space and depth if possible, else 8-bit sRGB.
    static func makeContext(like image: CGImage, width: Int, height: Int) -> CGContext? {
        let deep = image.bitsPerComponent > 8
        let bpc = deep ? 16 : 8
        if let space = image.colorSpace {
            switch space.model {
            case .rgb:
                if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: bpc,
                                       bytesPerRow: 0, space: space,
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                    return ctx
                }
            case .monochrome:
                if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: bpc,
                                       bytesPerRow: 0, space: space,
                                       bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                    return ctx
                }
            default:
                break
            }
        }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    /// Draws `image` scaled into an 8-bit sRGB buffer for the detector.
    public static func rgbImage(from image: CGImage, maxSide: Int? = nil) -> RGBImage? {
        var w = image.width, h = image.height
        if let maxSide, max(w, h) > maxSide {
            let f = Double(maxSide) / Double(max(w, h))
            w = max(1, Int((Double(w) * f).rounded()))
            h = max(1, Int((Double(h) * f).rounded()))
        }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var px = [Float](repeating: 0, count: w * h * 3)
        // Bitmap contexts store the top row first.
        for i in 0..<(w * h) {
            px[3 * i] = Float(bytes[4 * i]) / 255
            px[3 * i + 1] = Float(bytes[4 * i + 1]) / 255
            px[3 * i + 2] = Float(bytes[4 * i + 2]) / 255
        }
        return RGBImage(width: w, height: h, pixels: px)
    }
}
