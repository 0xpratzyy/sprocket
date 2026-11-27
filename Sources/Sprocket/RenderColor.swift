import Foundation

/// CSS colour strings as used by the Sprocket authoring API (see API.md).
public enum SprocketColor {
    private static let names: [String: (Double, Double, Double, Double)] = [
        "white": (1, 1, 1, 1), "black": (0, 0, 0, 1),
        "red": (1, 0, 0, 1), "green": (0, 128.0 / 255, 0, 1), "blue": (0, 0, 1, 1),
        "yellow": (1, 1, 0, 1), "orange": (1, 165.0 / 255, 0, 1),
        "purple": (128.0 / 255, 0, 128.0 / 255, 1), "pink": (1, 192.0 / 255, 203.0 / 255, 1),
        "gray": (128.0 / 255, 128.0 / 255, 128.0 / 255, 1), "grey": (128.0 / 255, 128.0 / 255, 128.0 / 255, 1),
        "cyan": (0, 1, 1, 1), "magenta": (1, 0, 1, 1),
        "transparent": (0, 0, 0, 0),
    ]

    /// `#rgb #rgba #rrggbb #rrggbbaa rgb() rgba() hsl() hsla()` and the basic names. Components are 0...1 and not premultiplied.
    /// Returns nil for anything it cannot read.
    public static func parse(_ s: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        if let n = names[t] { return (n.0, n.1, n.2, n.3) }
        if t.hasPrefix("#") { return parseHex(String(t.dropFirst())) }
        guard t.hasSuffix(")"), let open = t.firstIndex(of: "(") else { return nil }
        let fn = String(t[t.startIndex..<open]).trimmingCharacters(in: .whitespaces)
        let inner = t[t.index(after: open)..<t.index(before: t.endIndex)]
        let args = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" || $0 == "\t" }).map(String.init)
        guard args.count == 3 || args.count == 4 else { return nil }
        var alpha = 1.0
        if args.count == 4 {
            guard let a = number(args[3], percentScale: 1) else { return nil }
            alpha = clamp01(a)
        }
        switch fn {
        case "rgb", "rgba":
            guard let r = number(args[0], percentScale: 255), let g = number(args[1], percentScale: 255),
                  let b = number(args[2], percentScale: 255) else { return nil }
            return (clamp01(r / 255), clamp01(g / 255), clamp01(b / 255), alpha)
        case "hsl", "hsla":
            var hs = args[0]
            if hs.hasSuffix("deg") { hs.removeLast(3) }
            guard let h = Double(hs), h.isFinite,
                  let sat = number(args[1], percentScale: 1, requirePercent: true),
                  let lig = number(args[2], percentScale: 1, requirePercent: true) else { return nil }
            let (r, g, b) = hslToRGB(h: h, s: clamp01(sat), l: clamp01(lig))
            return (r, g, b, alpha)
        default: return nil
        }
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    /// A number, or a percentage which is converted with `percentScale` (percent / 100 * percentScale).
    private static func number(_ s: String, percentScale: Double, requirePercent: Bool = false) -> Double? {
        if s.hasSuffix("%") {
            guard let v = Double(s.dropLast()), v.isFinite else { return nil }
            return v / 100 * percentScale
        }
        if requirePercent { return nil }
        guard let v = Double(s), v.isFinite else { return nil }
        return v
    }

    private static func parseHex(_ h: String) -> (r: Double, g: Double, b: Double, a: Double)? {
        let chars = Array(h)
        guard chars.allSatisfy({ $0.isHexDigit }) else { return nil }
        func v(_ i: Int) -> Double { Double(Int(String(chars[i]), radix: 16) ?? 0) }
        func pair(_ i: Int) -> Double { (v(i) * 16 + v(i + 1)) / 255 }
        switch chars.count {
        case 3: return (v(0) * 17 / 255, v(1) * 17 / 255, v(2) * 17 / 255, 1)
        case 4: return (v(0) * 17 / 255, v(1) * 17 / 255, v(2) * 17 / 255, v(3) * 17 / 255)
        case 6: return (pair(0), pair(2), pair(4), 1)
        case 8: return (pair(0), pair(2), pair(4), pair(6))
        default: return nil
        }
    }

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        var hue = h.truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        hue /= 360
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func f(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        if s == 0 { return (l, l, l) }
        return (f(hue + 1.0 / 3), f(hue), f(hue - 1.0 / 3))
    }
}
