import Foundation
import CoreImage
import CoreGraphics

/// A gradient with its defaults filled in, ready to draw into a CGContext. Shared by the `gradient` node and the `fill` prop.
struct ResolvedGradient {
    var radial: Bool
    var from: CGPoint
    var to: CGPoint
    var stops: [(at: Double, color: (r: Double, g: Double, b: Double, a: Double))]
    var key: String

    /// `box` is the bounding box the defaults refer to (see API.md "Gradient"): linear runs from the box's top-left
    /// straight down to its bottom edge; radial runs from the centre out to max(width, height) / 2.
    init?(kind: String?, stops stopsIn: [Node.GradientStop]?, from: Node.Point?, to: Node.Point?, box: CGRect) {
        guard let stopsIn, !stopsIn.isEmpty else { return nil }
        let sorted = stopsIn.filter { $0.at.isFinite }.sorted { $0.at < $1.at }
        guard !sorted.isEmpty else { return nil }
        stops = sorted.map { ($0.at, SprocketColor.parse($0.color) ?? (0, 0, 0, 0)) }
        radial = kind == "radial"
        let f = CGPoint(x: fin(from?.x) ?? (radial ? box.midX : box.minX), y: fin(from?.y) ?? (radial ? box.midY : box.minY))
        let t: CGPoint
        if let p = to, p.x.isFinite, p.y.isFinite { t = CGPoint(x: p.x, y: p.y) }
        else if radial { t = CGPoint(x: f.x + max(box.width, box.height) / 2, y: f.y) }
        else { t = CGPoint(x: f.x, y: box.maxY) }
        self.from = f; self.to = t
        key = "\(radial)|\(f)|\(t)|" + stops.map { "\($0.at)\($0.color)" }.joined(separator: ",")
    }

    /// Paints the gradient over `region` (the caller sets the clip).
    func draw(in ctx: CGContext, region: CGRect) {
        let last = stops[stops.count - 1].color
        if stops.count == 1 || from == to {
            ctx.setFillColor(CGColor(colorSpace: RenderShared.srgb, components: [last.r, last.g, last.b, last.a])!)
            ctx.fill(region)
            return
        }
        var comps: [CGFloat] = []
        for s in stops { comps += [s.color.r, s.color.g, s.color.b, s.color.a] }
        let locs = stops.map { CGFloat(min(1, max(0, $0.at))) }
        guard let g = CGGradient(colorSpace: RenderShared.srgb, colorComponents: comps, locations: locs, count: stops.count) else { return }
        if radial {
            let r = hypot(to.x - from.x, to.y - from.y)
            ctx.drawRadialGradient(g, startCenter: from, startRadius: 0, endCenter: from, endRadius: r, options: [.drawsAfterEndLocation])
        } else {
            ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }
}

/// Trimming a stroke: the part of an outline between two fractions of its total length.
enum PathTrim {
    private struct Sub { var pts: [CGPoint]; var closed: Bool }

    /// Flattens curves into short straight pieces (about 2 px each, at most 400 per curve) so lengths can be measured.
    private static func flatten(_ path: CGPath) -> [Sub] {
        var subs: [Sub] = []
        var cur: [CGPoint] = []
        var closed = false
        func flush() { if cur.count > 1 || (cur.count == 1 && closed) { subs.append(Sub(pts: cur, closed: closed)) }; cur = []; closed = false }
        func steps(_ len: Double) -> Int { max(6, min(400, Int(len / 2))) }
        path.applyWithBlock { el in
            let p = el.pointee.points
            switch el.pointee.type {
            case .moveToPoint: flush(); cur = [p[0]]
            case .addLineToPoint: cur.append(p[0])
            case .addQuadCurveToPoint:
                guard let a = cur.last else { return }
                let n = steps(hypot(p[0].x - a.x, p[0].y - a.y) + hypot(p[1].x - p[0].x, p[1].y - p[0].y))
                for i in 1...n {
                    let t = Double(i) / Double(n), u = 1 - t
                    cur.append(CGPoint(x: u * u * a.x + 2 * u * t * p[0].x + t * t * p[1].x,
                                       y: u * u * a.y + 2 * u * t * p[0].y + t * t * p[1].y))
                }
            case .addCurveToPoint:
                guard let a = cur.last else { return }
                let n = steps(hypot(p[0].x - a.x, p[0].y - a.y) + hypot(p[1].x - p[0].x, p[1].y - p[0].y) + hypot(p[2].x - p[1].x, p[2].y - p[1].y))
                for i in 1...n {
                    let t = Double(i) / Double(n), u = 1 - t
                    let b0 = u * u * u, b1 = 3 * u * u * t, b2 = 3 * u * t * t, b3 = t * t * t
                    cur.append(CGPoint(x: b0 * a.x + b1 * p[0].x + b2 * p[1].x + b3 * p[2].x,
                                       y: b0 * a.y + b1 * p[0].y + b2 * p[1].y + b3 * p[2].y))
                }
            case .closeSubpath:
                if let f = cur.first { cur.append(f) }
                closed = true
                flush()
            @unknown default: break
            }
        }
        flush()
        return subs
    }

    /// The outline between `start` and `end` (fractions of the total length over all sub-paths), as straight pieces.
    /// Returns the path unchanged when the range covers everything, nil when nothing is left.
    static func trimmed(_ path: CGPath, start: Double, end: Double) -> CGPath? {
        let s0 = min(1, max(0, start)), e0 = min(1, max(0, end))
        guard e0 > s0 else { return nil }
        if s0 <= 0 && e0 >= 1 { return path }
        let subs = flatten(path)
        func len(_ pts: [CGPoint]) -> Double {
            var l = 0.0
            for i in 1..<pts.count { l += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
            return l
        }
        let lens = subs.map { len($0.pts) }
        let total = lens.reduce(0, +)
        guard total > 0 else { return nil }
        let a = s0 * total, b = e0 * total
        let out = CGMutablePath()
        var base = 0.0
        for (k, sub) in subs.enumerated() {
            let L = lens[k]
            let lo = max(a, base) - base, hi = min(b, base + L) - base
            base += L
            guard hi > lo, L > 0 else { continue }
            if lo <= 0 && hi >= L {
                out.move(to: sub.pts[0])
                for p in sub.pts.dropFirst() { out.addLine(to: p) }
                if sub.closed { out.closeSubpath() }
                continue
            }
            var acc = 0.0
            var started = false
            for i in 1..<sub.pts.count {
                let p0 = sub.pts[i - 1], p1 = sub.pts[i]
                let seg = hypot(p1.x - p0.x, p1.y - p0.y)
                defer { acc += seg }
                guard seg > 0, acc + seg > lo, acc < hi else { continue }
                let t0 = max(0, (lo - acc) / seg), t1 = min(1, (hi - acc) / seg)
                let q0 = CGPoint(x: p0.x + (p1.x - p0.x) * t0, y: p0.y + (p1.y - p0.y) * t0)
                let q1 = CGPoint(x: p0.x + (p1.x - p0.x) * t1, y: p0.y + (p1.y - p0.y) * t1)
                if !started { out.move(to: q0); started = true }
                out.addLine(to: q1)
            }
        }
        return out.isEmpty ? nil : out
    }
}

extension RenderPass {
    /// A projective mapping of the layer: scale, skew, 3D tilt, rotate, translate, all about the origin (ox, oy in node space).
    /// The four corners of the layer's extent are carried through the whole chain and `CIPerspectiveTransform` maps the
    /// picture onto them; a plane seen through a pinhole camera is exactly such a mapping. Nil when the node vanishes
    /// (a corner is on or behind the camera).
    func applyTransform3D(_ im: CIImage, t: Node.Transform, sx: Double, sy: Double, rot: Double, tx: Double, ty: Double,
                          ox: Double, oy: Double) -> CIImage? {
        let e = im.extent
        guard !e.isInfinite, !e.isNull, e.width > 0, e.height > 0 else { return nil }
        let skx = tan(max(-89.9, min(89.9, fin(t.skewX) ?? 0)) * .pi / 180)
        let sky = tan(max(-89.9, min(89.9, fin(t.skewY) ?? 0)) * .pi / 180)
        let ax = (fin(t.rotateX) ?? 0) * .pi / 180, ay = (fin(t.rotateY) ?? 0) * .pi / 180
        var d = fin(t.perspective) ?? 1000
        if !(d > 0) { d = 1000 }
        d = min(d, 1e7)
        let cosX = cos(ax), sinX = sin(ax), cosY = cos(ay), sinY = sin(ay)
        let cr = cos(rot * .pi / 180), sr = sin(rot * .pi / 180)

        func map(_ ciPoint: CGPoint) -> CGPoint? {
            // node space, relative to the origin, y down
            var x = ciPoint.x - ox, y = flipY(ciPoint.y) - oy
            x *= sx; y *= sy
            let kx = x + skx * y, ky = y + sky * x
            x = kx; y = ky
            // rotateY: positive swings the right side away from the viewer (CSS convention); then rotateX: top away
            var z = 0.0
            let x1 = x * cosY, z1 = -x * sinY
            x = x1; z = z1
            let y2 = y * cosX - z * sinX, z2 = y * sinX + z * cosX
            y = y2; z = z2
            guard d - z > d * 0.02 else { return nil }
            let k = d / (d - z)
            x *= k; y *= k
            let rx = x * cr - y * sr, ry = x * sr + y * cr
            return CGPoint(x: ox + tx + rx, y: flipY(oy + ty + ry))
        }
        guard let tl = map(CGPoint(x: e.minX, y: e.maxY)), let tr = map(CGPoint(x: e.maxX, y: e.maxY)),
              let br = map(CGPoint(x: e.maxX, y: e.minY)), let bl = map(CGPoint(x: e.minX, y: e.minY)) else { return nil }
        let corners = [tl, tr, br, bl]
        guard corners.allSatisfy({ abs($0.x) < 1e7 && abs($0.y) < 1e7 && $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return im.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: tl), "inputTopRight": CIVector(cgPoint: tr),
            "inputBottomRight": CIVector(cgPoint: br), "inputBottomLeft": CIVector(cgPoint: bl),
        ])
    }
}
