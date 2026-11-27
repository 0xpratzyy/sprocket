import Foundation
import CoreImage
import CoreGraphics

extension RenderPass {
    private struct ShapeItem {
        var path: CGPath
        var bounds: CGRect
        var fill: CGColor?
        var gradient: ResolvedGradient?
        var stroke: CGColor?
        var strokeWidth: CGFloat
        var cap: CGLineCap
        var join: CGLineJoin
        var dash: [CGFloat]
        var dashOffset: CGFloat
        /// The outline to stroke (the path itself, or the trimmed / reshaped piece of it).
        var strokePath: CGPath?
        var key: String
    }

    private func cgColor(_ s: String?) -> CGColor? {
        guard let s, let c = SprocketColor.parse(s), c.a > 0 else { return nil }
        return CGColor(colorSpace: RenderShared.srgb, components: [c.r, c.g, c.b, c.a])
    }

    private func shapeItem(_ n: Node) -> ShapeItem? {
        var fill = cgColor(n.color)
        let stroke = cgColor(n.stroke)
        let sw = min(max(0, fin(n.strokeWidth) ?? 1), hypot(Double(W), Double(H)))   // never wider than the canvas diagonal
        let trimRange = n.trim.map { (fin($0.start) ?? 0, fin($0.end) ?? 1) }
        var hasStroke = stroke != nil && sw > 0
        if let tr = trimRange, !(tr.1 > tr.0) { hasStroke = false }   // an empty trim draws no stroke
        let wantsGradient = n.fill?.stops?.isEmpty == false
        guard fill != nil || hasStroke || wantsGradient else { return nil }
        let path: CGPath
        switch n.type {
        case "rect", "ellipse":
            let x = fin(n.x) ?? 0, y = fin(n.y) ?? 0
            let w = fin(n.width) ?? Double(W), h = fin(n.height) ?? Double(H)
            guard w > 0, h > 0, abs(x) < 1e7, abs(y) < 1e7, w < 1e7, h < 1e7 else { return nil }
            let r = CGRect(x: x, y: y, width: w, height: h)
            let rad = min(max(0, fin(n.radius) ?? 0), min(w, h) / 2)
            if n.type == "ellipse" {
                path = n.trim != nil ? RenderPass.ellipseFromTop(r) : CGPath(ellipseIn: r, transform: nil)
            } else if rad > 0 {
                if n.trim != nil {
                    // Starts on the top edge, just after the top-left corner, and runs clockwise.
                    let m = CGMutablePath()
                    m.move(to: CGPoint(x: r.minX + rad, y: r.minY))
                    m.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: rad)
                    m.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: rad)
                    m.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: rad)
                    m.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: rad)
                    m.closeSubpath()
                    path = m
                } else {
                    path = CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
                }
            } else if n.trim != nil {
                // Starts at the top-left corner and runs clockwise, so a trim grows the way the eye expects.
                let m = CGMutablePath()
                m.move(to: CGPoint(x: r.minX, y: r.minY)); m.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                m.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); m.addLine(to: CGPoint(x: r.minX, y: r.maxY)); m.closeSubpath()
                path = m
            } else {
                path = CGPath(rect: r, transform: nil)
            }
        case "path":
            guard let d = n.d, let p = RenderSVGPath.parse(d) else { return nil }
            path = p
        default: return nil
        }
        var b = path.boundingBoxOfPath
        guard !b.isNull, !b.isInfinite, b.minX.isFinite, b.minY.isFinite, b.width.isFinite, b.height.isFinite else { return nil }
        let shapeBox = b
        var gradient: ResolvedGradient?
        if let f = n.fill {
            gradient = ResolvedGradient(kind: f.kind, stops: f.stops, from: f.from, to: f.to, box: shapeBox)
            if gradient != nil { fill = nil }   // `fill` replaces `color`
        }
        guard fill != nil || gradient != nil || hasStroke else { return nil }

        // Stroke style: cap, join, dash, and the trimmed piece of the outline.
        let cap: CGLineCap = n.lineCap == "round" ? .round : n.lineCap == "square" ? .square : .butt
        let join: CGLineJoin = n.lineJoin == "round" ? .round : n.lineJoin == "bevel" ? .bevel : .miter
        var dash: [CGFloat] = []
        if let d = n.dash, !d.isEmpty, d.allSatisfy({ $0.isFinite && $0 >= 0 }), d.reduce(0, +) > 0 { dash = d.prefix(32).map { CGFloat($0) } }
        var strokePath: CGPath? = hasStroke ? path : nil
        if hasStroke, let tr = trimRange {
            strokePath = PathTrim.trimmed(path, start: tr.0, end: tr.1)
            if strokePath == nil { hasStroke = false }
        }
        guard fill != nil || gradient != nil || hasStroke else { return nil }
        if hasStroke { b = b.insetBy(dx: -sw - 1, dy: -sw - 1) } else { b = b.insetBy(dx: -1, dy: -1) }
        let style = "\(n.lineCap ?? "")|\(n.lineJoin ?? "")|\(dash)|\(n.dashOffset ?? 0)|\(n.trim.map { "\($0.start ?? 0),\($0.end ?? 1)" } ?? "")"
        let key = "\(n.type)|\(n.x ?? -1)|\(n.y ?? -1)|\(n.width ?? -1)|\(n.height ?? -1)|\(n.radius ?? 0)|\(n.color ?? "")|\(n.stroke ?? "")|\(sw)|\(n.d ?? "")|\(style)|\(gradient?.key ?? "")"
        return ShapeItem(path: path, bounds: b, fill: fill, gradient: gradient, stroke: hasStroke ? stroke : nil, strokeWidth: CGFloat(sw),
                         cap: cap, join: join, dash: dash, dashOffset: CGFloat(fin(n.dashOffset) ?? 0),
                         strokePath: hasStroke ? strokePath : nil, key: key)
    }

    /// Draws one or more plain shapes (rect, ellipse, path) into a single bitmap.
    func shapeBatch(_ nodes: [Node]) -> CIImage? {
        let items = nodes.compactMap { shapeItem($0) }
        guard !items.isEmpty else { return nil }
        var union = items[0].bounds
        for it in items.dropFirst() { union = union.union(it.bounds) }
        let key = items.map(\.key).joined(separator: "¦") + "|\(W)x\(H)"
        return cachedRaster(key: key, bounds: union) { ctx in
            for it in items {
                if let f = it.fill {
                    ctx.setFillColor(f); ctx.addPath(it.path); ctx.fillPath()
                } else if let g = it.gradient {
                    ctx.saveGState()
                    ctx.addPath(it.path); ctx.clip()
                    g.draw(in: ctx, region: it.path.boundingBoxOfPath.insetBy(dx: -2, dy: -2))
                    ctx.restoreGState()
                }
                if let s = it.stroke, let sp = it.strokePath {
                    ctx.setStrokeColor(s); ctx.setLineWidth(it.strokeWidth)
                    ctx.setLineJoin(it.join); ctx.setLineCap(it.cap)
                    if !it.dash.isEmpty { ctx.setLineDash(phase: it.dashOffset, lengths: it.dash) } else { ctx.setLineDash(phase: 0, lengths: []) }
                    ctx.addPath(sp); ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                }
            }
        }
    }

    /// An ellipse that starts at 12 o'clock and runs clockwise (four Bezier quarters), so a `trim` grows from the top.
    static func ellipseFromTop(_ r: CGRect) -> CGPath {
        let k = 0.5522847498
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
        let m = CGMutablePath()
        m.move(to: CGPoint(x: cx, y: cy - ry))
        m.addCurve(to: CGPoint(x: cx + rx, y: cy), control1: CGPoint(x: cx + k * rx, y: cy - ry), control2: CGPoint(x: cx + rx, y: cy - k * ry))
        m.addCurve(to: CGPoint(x: cx, y: cy + ry), control1: CGPoint(x: cx + rx, y: cy + k * ry), control2: CGPoint(x: cx + k * rx, y: cy + ry))
        m.addCurve(to: CGPoint(x: cx - rx, y: cy), control1: CGPoint(x: cx - k * rx, y: cy + ry), control2: CGPoint(x: cx - rx, y: cy + k * ry))
        m.addCurve(to: CGPoint(x: cx, y: cy - ry), control1: CGPoint(x: cx - rx, y: cy - k * ry), control2: CGPoint(x: cx - k * rx, y: cy - ry))
        m.closeSubpath()
        return m
    }

    func renderGradient(_ n: Node) -> CIImage? {
        guard let stopsIn = n.stops, !stopsIn.isEmpty else { return nil }
        let x = fin(n.x) ?? 0, y = fin(n.y) ?? 0
        let w = fin(n.width) ?? Double(W), h = fin(n.height) ?? Double(H)
        guard w > 0, h > 0, abs(x) < 1e7, abs(y) < 1e7, w < 1e7, h < 1e7 else { return nil }
        let box = CGRect(x: x, y: y, width: w, height: h)
        guard let g = ResolvedGradient(kind: n.kind, stops: stopsIn, from: n.from, to: n.to, box: box) else { return nil }
        let key = "grad|\(box)|" + g.key + "|\(W)x\(H)"
        return cachedRaster(key: key, bounds: box) { ctx in
            ctx.saveGState()
            ctx.clip(to: box)
            g.draw(in: ctx, region: box)
            ctx.restoreGState()
        }
    }

    // MARK: image / video

    /// Fits a source picture into the node's box (default: the canvas) and crops to it.
    func placeMedia(_ src: CIImage, _ n: Node) -> CIImage? {
        let e = src.extent
        guard !e.isInfinite, !e.isNull, e.width > 0, e.height > 0, e.width.isFinite, e.height.isFinite else { return nil }
        let bx = fin(n.x) ?? 0, by = fin(n.y) ?? 0
        let bw = fin(n.width) ?? Double(W), bh = fin(n.height) ?? Double(H)
        guard bw > 0, bh > 0, abs(bx) < 1e7, abs(by) < 1e7, bw < 1e7, bh < 1e7 else { return nil }
        let iw = Double(e.width), ih = Double(e.height)
        var sx = bw / iw, sy = bh / ih
        switch n.fit {
        case "fill": break
        case "contain": let s = min(sx, sy); sx = s; sy = s
        default: let s = max(sx, sy); sx = s; sy = s       // cover
        }
        let sw = iw * sx, sh = ih * sy
        let fx = min(1, max(0, fin(n.focusX) ?? 0.5)), fy = min(1, max(0, fin(n.focusY) ?? 0.5))
        // Position of the scaled picture's top-left in node space. cover: the overflow is shared by focus; contain: centred.
        let left: Double, top: Double
        if sw >= bw { left = bx - (sw - bw) * fx } else { left = bx + (bw - sw) / 2 }
        if sh >= bh { top = by - (sh - bh) * fy } else { top = by + (bh - sh) / 2 }
        // Source: shift to the origin, scale, then place its bottom-left corner (ciY = H - (top + sh)).
        var t = CGAffineTransform(translationX: -e.minX, y: -e.minY)
        if sx != 1 || sy != 1 { t = t.concatenating(CGAffineTransform(scaleX: sx, y: sy)) }
        t = t.concatenating(CGAffineTransform(translationX: left, y: flipY(top + sh)))
        let boxCI = CGRect(x: bx, y: flipY(by + bh), width: bw, height: bh)
        return src.transformed(by: t).cropped(to: boxCI.intersection(rect))
    }
}
