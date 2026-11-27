import Foundation
import CoreGraphics

/// SVG path data (M L H V C S Q T A Z, absolute and relative) to CGPath. Parsing stops at the first error and keeps what it had.
enum RenderSVGPath {
    static func parse(_ d: String) -> CGPath? {
        let s = Array(d.utf8)
        var i = 0
        let path = CGMutablePath()

        func skipSep() { while i < s.count, s[i] == 32 || s[i] == 44 || s[i] == 9 || s[i] == 10 || s[i] == 13 { i += 1 } }
        func number() -> Double? {
            skipSep()
            let start = i
            if i < s.count, s[i] == 43 || s[i] == 45 { i += 1 }
            var digits = 0
            while i < s.count, s[i] >= 48, s[i] <= 57 { i += 1; digits += 1 }
            if i < s.count, s[i] == 46 {
                i += 1
                while i < s.count, s[i] >= 48, s[i] <= 57 { i += 1; digits += 1 }
            }
            guard digits > 0 else { i = start; return nil }
            if i < s.count, s[i] == 101 || s[i] == 69 {
                var j = i + 1
                if j < s.count, s[j] == 43 || s[j] == 45 { j += 1 }
                var ed = 0
                while j < s.count, s[j] >= 48, s[j] <= 57 { j += 1; ed += 1 }
                if ed > 0 { i = j }
            }
            guard let v = Double(String(decoding: s[start..<i], as: UTF8.self)), v.isFinite else { return nil }
            return v
        }
        func flag() -> Bool? {
            skipSep()
            guard i < s.count, s[i] == 48 || s[i] == 49 else { return nil }
            defer { i += 1 }
            return s[i] == 49
        }
        func isNumberStart() -> Bool {
            skipSep()
            guard i < s.count else { return false }
            let c = s[i]
            return (c >= 48 && c <= 57) || c == 46 || c == 45 || c == 43
        }

        var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0
        var lastCubic: CGPoint?   // second control point of the previous C/S
        var lastQuad: CGPoint?    // control point of the previous Q/T
        var cmd: UInt8 = 0
        var started = false

        loop: while true {
            skipSep()
            guard i < s.count else { break }
            let c = s[i]
            let isLetter = "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c)
            if isLetter {
                cmd = c; i += 1
            } else if cmd == 0 || cmd == 90 || cmd == 122 || !isNumberStart() {
                break
            } else if cmd == 77 { cmd = 76 } else if cmd == 109 { cmd = 108 }

            let rel = cmd >= 97
            let up = rel ? cmd - 32 : cmd
            let ox = rel ? cx : 0, oy = rel ? cy : 0
            var newCubic: CGPoint?, newQuad: CGPoint?

            switch up {
            case 77: // M
                guard let x = number(), let y = number() else { break loop }
                cx = ox + x; cy = oy + y; sx = cx; sy = cy
                path.move(to: CGPoint(x: cx, y: cy)); started = true
            case 76: // L
                guard started, let x = number(), let y = number() else { break loop }
                cx = ox + x; cy = oy + y
                path.addLine(to: CGPoint(x: cx, y: cy))
            case 72: // H
                guard started, let x = number() else { break loop }
                cx = ox + x
                path.addLine(to: CGPoint(x: cx, y: cy))
            case 86: // V
                guard started, let y = number() else { break loop }
                cy = oy + y
                path.addLine(to: CGPoint(x: cx, y: cy))
            case 67: // C
                guard started, let x1 = number(), let y1 = number(), let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { break loop }
                let c2 = CGPoint(x: ox + x2, y: oy + y2)
                path.addCurve(to: CGPoint(x: ox + x, y: oy + y), control1: CGPoint(x: ox + x1, y: oy + y1), control2: c2)
                cx = ox + x; cy = oy + y; newCubic = c2
            case 83: // S
                guard started, let x2 = number(), let y2 = number(), let x = number(), let y = number() else { break loop }
                let c1 = lastCubic.map { CGPoint(x: 2 * cx - $0.x, y: 2 * cy - $0.y) } ?? CGPoint(x: cx, y: cy)
                let c2 = CGPoint(x: ox + x2, y: oy + y2)
                path.addCurve(to: CGPoint(x: ox + x, y: oy + y), control1: c1, control2: c2)
                cx = ox + x; cy = oy + y; newCubic = c2
            case 81: // Q
                guard started, let x1 = number(), let y1 = number(), let x = number(), let y = number() else { break loop }
                let q = CGPoint(x: ox + x1, y: oy + y1)
                path.addQuadCurve(to: CGPoint(x: ox + x, y: oy + y), control: q)
                cx = ox + x; cy = oy + y; newQuad = q
            case 84: // T
                guard started, let x = number(), let y = number() else { break loop }
                let q = lastQuad.map { CGPoint(x: 2 * cx - $0.x, y: 2 * cy - $0.y) } ?? CGPoint(x: cx, y: cy)
                path.addQuadCurve(to: CGPoint(x: ox + x, y: oy + y), control: q)
                cx = ox + x; cy = oy + y; newQuad = q
            case 65: // A
                guard started, let rx = number(), let ry = number(), let rot = number(), let fa = flag(), let fs = flag(),
                      let x = number(), let y = number() else { break loop }
                addArc(path, x0: cx, y0: cy, rx: rx, ry: ry, phiDeg: rot, large: fa, sweep: fs, x: ox + x, y: oy + y)
                cx = ox + x; cy = oy + y
            case 90: // Z
                if started { path.closeSubpath() }
                cx = sx; cy = sy
            default: break loop
            }
            lastCubic = newCubic; lastQuad = newQuad
        }
        return path.isEmpty ? nil : path
    }

    private static func addArc(_ path: CGMutablePath, x0: Double, y0: Double, rx rx0: Double, ry ry0: Double,
                               phiDeg: Double, large: Bool, sweep: Bool, x: Double, y: Double) {
        if x0 == x && y0 == y { return }
        var rx = abs(rx0), ry = abs(ry0)
        if rx == 0 || ry == 0 { path.addLine(to: CGPoint(x: x, y: y)); return }
        let phi = phiDeg * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx2 = (x0 - x) / 2, dy2 = (y0 - y) / 2
        let x1p = cosP * dx2 + sinP * dy2
        let y1p = -sinP * dx2 + cosP * dy2
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let k = lambda.squareRoot(); rx *= k; ry *= k }
        let num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coef = den == 0 ? 0 : (max(0, num / den)).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let ccx = cosP * cxp - sinP * cyp + (x0 + x) / 2
        let ccy = sinP * cxp + cosP * cyp + (y0 + y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            var a = acos(max(-1, min(1, dot / max(len, 1e-300))))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
        if sweep && dtheta < 0 { dtheta += 2 * .pi }
        let segs = max(1, Int((abs(dtheta) / (.pi / 2)).rounded(.up)))
        let delta = dtheta / Double(segs)
        let t = 4.0 / 3.0 * tan(delta / 4)
        func pt(_ a: Double) -> CGPoint {
            CGPoint(x: ccx + rx * cos(a) * cosP - ry * sin(a) * sinP, y: ccy + rx * cos(a) * sinP + ry * sin(a) * cosP)
        }
        func dv(_ a: Double) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosP - ry * cos(a) * sinP, y: -rx * sin(a) * sinP + ry * cos(a) * cosP)
        }
        var a1 = theta1
        for k in 0..<segs {
            let a2 = a1 + delta
            let p1 = pt(a1), p2 = pt(a2), d1 = dv(a1), d2 = dv(a2)
            let end = k == segs - 1 ? CGPoint(x: x, y: y) : p2
            path.addCurve(to: end, control1: CGPoint(x: p1.x + t * d1.x, y: p1.y + t * d1.y),
                          control2: CGPoint(x: p2.x - t * d2.x, y: p2.y - t * d2.y))
            a1 = a2
        }
    }
}
