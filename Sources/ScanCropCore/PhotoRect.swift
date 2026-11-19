import Foundation

/// A photo on a scan: a rectangle that may be rotated.
///
/// Coordinates are pixels with the origin in the top-left corner and y pointing down.
/// `angle` is the direction of the photo's own x axis in degrees, clockwise, in `-45...45`.
/// Turning the photo by `-angle` makes it upright.
public struct PhotoRect: Equatable, Hashable, Codable, Sendable {
    public var centerX: Double
    public var centerY: Double
    public var width: Double
    public var height: Double
    public var angle: Double

    public init(centerX: Double, centerY: Double, width: Double, height: Double, angle: Double = 0) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.angle = angle
    }

    /// An upright rectangle from its top-left corner and size.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(centerX: x + width / 2, centerY: y + height / 2, width: width, height: height, angle: 0)
    }

    /// The four corners, clockwise from the photo's own top-left corner.
    public var corners: [(x: Double, y: Double)] {
        let a = angle * .pi / 180
        let (s, c) = (sin(a), cos(a))
        let (hw, hh) = (width / 2, height / 2)
        let local: [(Double, Double)] = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]
        return local.map { p -> (x: Double, y: Double) in
            (x: centerX + c * p.0 - s * p.1, y: centerY + s * p.0 + c * p.1)
        }
    }

    /// The same rectangle in an image scaled by `factor` (e.g. from a preview to the full scan).
    public func scaled(by factor: Double) -> PhotoRect {
        PhotoRect(centerX: centerX * factor, centerY: centerY * factor,
                  width: width * factor, height: height * factor, angle: angle)
    }

    /// Shrinks the rectangle by `amount` pixels on every side (never below 1 × 1).
    public func inset(by amount: Double) -> PhotoRect {
        var r = self
        r.width = max(1, width - 2 * amount)
        r.height = max(1, height - 2 * amount)
        return r
    }

    /// Shrinks the rectangle by different amounts on each of its own sides.
    public func trimmed(left: Double, top: Double, right: Double, bottom: Double) -> PhotoRect {
        let a = angle * .pi / 180
        let (s, c) = (sin(a), cos(a))
        let du = (left - right) / 2
        let dv = (top - bottom) / 2
        return PhotoRect(centerX: centerX + c * du - s * dv,
                         centerY: centerY + s * du + c * dv,
                         width: max(1, width - left - right),
                         height: max(1, height - top - bottom),
                         angle: angle)
    }

    /// Whether a point lies inside the rectangle.
    public func contains(x: Double, y: Double) -> Bool {
        let a = angle * .pi / 180
        let (s, c) = (sin(a), cos(a))
        let (dx, dy) = (x - centerX, y - centerY)
        let u = c * dx + s * dy
        let v = -s * dx + c * dy
        return abs(u) <= width / 2 && abs(v) <= height / 2
    }

    /// Size of the exported photo after turning it by `quarterTurns` × 90°.
    public func outputSize(quarterTurns: Int) -> (width: Int, height: Int) {
        let w = max(1, Int(width.rounded()))
        let h = max(1, Int(height.rounded()))
        return quarterTurns.isMultiple(of: 2) ? (w, h) : (h, w)
    }
}
