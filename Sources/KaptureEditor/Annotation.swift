// Annotation layer model. All geometry lives in IMAGE space (pixels of the base image),
// so rendering at canvas scale and flattening at native resolution are the same code path.
import AppKit

public enum Tool: String, CaseIterable, Codable {
    case select, arrow, line, rect, ellipse, freehand, highlight, text, counter, crop
}

public extension NSColor {
    /// "#RRGGBB" or "#RRGGBBAA" (leading # optional).
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 6 { h += "FF" }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                  blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
    }
}

public struct Annotation: Codable, Identifiable {
    public static let defaultFontSize: CGFloat = 48

    public var id: UUID
    public var tool: Tool
    public var points: [CGPoint]      // arrow/line: [from, to] · rect/ellipse/highlight: [a, b] · freehand: path · text/counter: [pos]
    public var colorHex: String
    public var strokeWidth: CGFloat   // image-space
    public var text: String?
    public var number: Int?           // counter
    public var fontSize: CGFloat?     // text, image-space

    public init(tool: Tool, points: [CGPoint], colorHex: String, strokeWidth: CGFloat,
                text: String? = nil, number: Int? = nil, fontSize: CGFloat? = nil) {
        self.id = UUID(); self.tool = tool; self.points = points; self.colorHex = colorHex
        self.strokeWidth = strokeWidth; self.text = text; self.number = number; self.fontSize = fontSize
    }

    public var color: NSColor { NSColor(hex: colorHex) }

    /// The text tool's font (image-space size).
    var font: NSFont { .systemFont(ofSize: fontSize ?? Self.defaultFontSize, weight: .semibold) }

    /// Counter badge radius, scaled with stroke width (image-space).
    var counterRadius: CGFloat { max(strokeWidth * 4, 24) }

    var rect: CGRect {
        guard points.count >= 2 else { return CGRect(origin: points.first ?? .zero, size: .zero) }
        let (a, b) = (points[0], points[1])
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Image-space bounding box (text measures its string; counter its badge circle).
    public var bounds: CGRect {
        guard let first = points.first else { return .zero }
        switch tool {
        case .text:
            guard let text else { break }
            let size = (text as NSString).size(withAttributes: [.font: font])
            return CGRect(origin: first, size: size)
        case .counter:
            let r = counterRadius
            return CGRect(x: first.x - r, y: first.y - r, width: r * 2, height: r * 2)
        default: break
        }
        return rect
    }

    /// Draw into a CGContext whose coordinate space is image space (origin top-left, y down).
    public func draw(in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let c = color
        ctx.setStrokeColor(c.cgColor)
        ctx.setFillColor(c.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch tool {
        case .select: break
        case .crop: break   // geometric, not painted — the renderer crops the output to its rect
        case .line:
            guard points.count >= 2 else { break }
            ctx.move(to: points[0]); ctx.addLine(to: points[1]); ctx.strokePath()
        case .arrow:
            guard points.count >= 2 else { break }
            drawArrow(ctx, from: points[0], to: points[1])
        case .rect:
            ctx.stroke(rect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2))
        case .ellipse:
            ctx.strokeEllipse(in: rect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2))
        case .freehand:
            guard points.count > 1 else { break }
            ctx.move(to: points[0])
            smoothPath(ctx)
            ctx.strokePath()
        case .highlight:
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(c.withAlphaComponent(0.45).cgColor)
            ctx.fill(rect)
        case .text:
            guard let text, let pos = points.first else { break }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: c,
                .strokeColor: NSColor.black.withAlphaComponent(0.25),
            ]
            drawFlipped(ctx) { (text as NSString).draw(at: pos, withAttributes: attrs) }
        case .counter:
            guard let number, let center = points.first else { break }
            let r = counterRadius
            let circle = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            ctx.fillEllipse(in: circle)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.1, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let s = "\(number)" as NSString
            let size = s.size(withAttributes: attrs)
            drawFlipped(ctx) {
                s.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                       withAttributes: attrs)
            }
        }
    }

    private func smoothPath(_ ctx: CGContext) {
        // Catmull-Rom-ish smoothing via midpoint quad curves
        guard points.count > 2 else { points.count == 2 ? ctx.addLine(to: points[1]) : (); return }
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            ctx.addQuadCurve(to: mid, control: points[i])
        }
        ctx.addLine(to: points[points.count - 1])
    }

    private func drawArrow(_ ctx: CGContext, from: CGPoint, to: CGPoint) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let headLen = max(strokeWidth * 3.2, 14.0)
        let headAngle: CGFloat = .pi / 7
        let lineEnd = CGPoint(x: to.x - cos(angle) * headLen * 0.6, y: to.y - sin(angle) * headLen * 0.6)
        ctx.move(to: from); ctx.addLine(to: lineEnd); ctx.strokePath()
        ctx.move(to: to)
        ctx.addLine(to: CGPoint(x: to.x - cos(angle - headAngle) * headLen, y: to.y - sin(angle - headAngle) * headLen))
        ctx.addLine(to: CGPoint(x: to.x - cos(angle + headAngle) * headLen, y: to.y - sin(angle + headAngle) * headLen))
        ctx.closePath()
        ctx.fillPath()
    }

    /// Text drawing needs a flipped NSGraphicsContext bridge inside our top-left-origin space.
    private func drawFlipped(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = ns
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    public func hitTest(_ p: CGPoint) -> Bool {
        let pad = max(strokeWidth * 2, 12)
        switch tool {
        case .text:
            guard let pos = points.first, let text else { return false }
            let size = (text as NSString).size(withAttributes: [.font: font])
            return CGRect(origin: pos, size: size).insetBy(dx: -pad, dy: -pad).contains(p)
        case .counter:
            guard let c = points.first else { return false }
            return hypot(p.x - c.x, p.y - c.y) < counterRadius + pad
        case .freehand:
            return points.contains { hypot(p.x - $0.x, p.y - $0.y) < pad }
        case .arrow, .line:
            guard points.count >= 2 else { return false }
            return distanceToSegment(p, points[0], points[1]) < pad
        default:
            return rect.insetBy(dx: -pad, dy: -pad).contains(p) && !rect.insetBy(dx: pad, dy: pad).contains(p)
                || (tool == .highlight || tool == .crop) && rect.contains(p)
        }
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

public enum AnnotationRenderer {
    /// Flatten base + layers at native resolution. The base image draws upright (no flip —
    /// CGContext.draw under a flipped CTM would mirror it vertically); the y-flip is applied
    /// afterwards so layers draw in image space (origin top-left, y down), matching the
    /// on-screen path in CanvasView.draw.
    public static func flatten(base: CGImage, layers: [Annotation]) -> CGImage? {
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        for l in layers { l.draw(in: ctx) }
        guard let out = ctx.makeImage() else { return nil }
        // Crop applies last, over the fully composited image (one crop layer at a time; the editor
        // replaces any previous one). Its rect is image-space top-left — cropping(to:) matches.
        if let crop = layers.last(where: { $0.tool == .crop }) {
            let clamped = crop.rect.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            if clamped.width >= 1, clamped.height >= 1 { return out.cropping(to: clamped) ?? out }
        }
        return out
    }
}

public enum AnnotationCodec {
    public static func encode(_ layers: [Annotation]) -> String {
        (try? JSONEncoder().encode(layers)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    public static func decode(_ json: String) -> [Annotation] {
        (try? JSONDecoder().decode([Annotation].self, from: Data(json.utf8))) ?? []
    }
}
