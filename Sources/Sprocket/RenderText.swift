import Foundation
import CoreImage
import CoreGraphics
import CoreText

extension RenderPass {
    private static func weightTrait(_ w: Double?) -> CGFloat {
        let table: [(Double, Double)] = [(100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
        let v = min(900, max(100, fin(w) ?? 400))
        for i in 1..<table.count where v <= table[i].0 {
            let (a, b) = (table[i - 1], table[i])
            return CGFloat(a.1 + (b.1 - a.1) * (v - a.0) / (b.0 - a.0))
        }
        return 0.62
    }

    /// The named family at the given weight (and italic) if it is installed, otherwise nil.
    static func installedFont(family: String?, size: CGFloat, weight: Double?, italic: Bool = false) -> CTFont? {
        guard let fam = family, !fam.isEmpty else { return nil }
        let wt = weightTrait(weight)
        var traits: [String: Any] = [kCTFontWeightTrait as String: wt]
        if italic { traits[kCTFontSymbolicTrait as String] = CTFontSymbolicTraits.traitItalic.rawValue }
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute as String: fam, kCTFontTraitsAttribute as String: traits] as CFDictionary)
        let f = CTFontCreateWithFontDescriptor(desc, size, nil)
        let famName = (CTFontCopyFamilyName(f) as String).lowercased()
        let full = (CTFontCopyFullName(f) as String).lowercased()
        return famName == fam.lowercased() || full == fam.lowercased() ? f : nil
    }

    /// The named family if it exists on this device, otherwise the system font, at the given weight.
    /// `italic` asks for the italic face; a font without one is slanted by `needsSyntheticItalic`.
    static func makeFont(family: String?, size: CGFloat, weight: Double?, italic: Bool = false) -> CTFont {
        if let f = installedFont(family: family, size: size, weight: weight, italic: italic) { return f }
        let wt = weightTrait(weight)
        let traits = [kCTFontWeightTrait as String: wt] as CFDictionary
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let desc = CTFontCopyFontDescriptor(base)
        let d2 = CTFontDescriptorCreateCopyWithAttributes(desc, [kCTFontTraitsAttribute as String: traits] as CFDictionary)
        let f = CTFontCreateWithFontDescriptor(d2, size, nil)
        if italic, let it = CTFontCreateCopyWithSymbolicTraits(f, size, nil, .traitItalic, .traitItalic) { return it }
        return f
    }

    /// True when italic was asked for but the font has no italic face: the glyphs are drawn slanted by a shear instead.
    static func needsSyntheticItalic(_ font: CTFont, italic: Bool) -> Bool {
        italic && !CTFontGetSymbolicTraits(font).contains(.traitItalic) && CTFontGetSlantAngle(font) == 0
    }

    func renderText(_ n: Node) -> CIImage? {
        guard let str = n.text, !str.isEmpty else { return nil }
        let size = fin(n.size) ?? 48
        guard size >= 1, size <= 4000 else { return nil }
        let x = fin(n.x) ?? 0, y = fin(n.y) ?? 0
        let wrap = fin(n.width) ?? Double(W)
        guard wrap > 0, wrap < 1e6, abs(x) < 1e7, abs(y) < 1e7 else { return nil }
        let fillColor = SprocketColor.parse(n.color ?? "#ffffff")
        let sw = min(max(0, fin(n.strokeWidth) ?? 0), hypot(Double(W), Double(H)))
        let strokeColor = sw > 0 ? n.stroke.flatMap(SprocketColor.parse) : nil
        let hasGradient = n.fill?.stops?.isEmpty == false
        guard hasGradient || (fillColor?.a ?? 0) > 0 || (strokeColor?.a ?? 0) > 0 else { return nil }

        var shadowSpec: (c: (r: Double, g: Double, b: Double, a: Double), blur: Double, dx: Double, dy: Double)?
        if let s = n.shadow, let c = s.color.flatMap(SprocketColor.parse) ?? SprocketColor.parse("rgba(0,0,0,0.5)"), c.a > 0 {
            shadowSpec = (c, max(0, fin(s.blur) ?? 0), fin(s.x) ?? 0, fin(s.y) ?? 0)
        }

        let key = "text|\(str)|\(x)|\(y)|\(wrap)|\(n.font ?? "")|\(size)|\(n.weight ?? 400)|\(n.color ?? "")|\(n.align ?? "center")|\(n.lineHeight ?? 0)|\(n.letterSpacing ?? 0)|\(n.stroke ?? "")|\(sw)|\(String(describing: n.shadow))|\(n.italic == true)|\(String(describing: n.fill))|\(W)x\(H)"
        if let hit = RenderShared.cache.object(forKey: key as NSString) { return hit }

        guard let layout = TextLayout.make(n, canvasWidth: W) else { return nil }
        let pad = size * 0.6 + sw + 2
        let region = CGRect(x: x - pad, y: y - pad, width: wrap + 2 * pad, height: Double(layout.lines.count) * layout.boxHeight + 2 * pad)

        // The gradient's default box is the text's own ink area: the widest line's span and the block's height.
        var gradient: ResolvedGradient?
        if hasGradient, let f = n.fill {
            let drawn = layout.lines.filter { $0.ct != nil }
            let minX = drawn.map(\.x).min() ?? x, maxX = drawn.map { $0.x + $0.width }.max() ?? x + wrap
            let box = CGRect(x: minX, y: y, width: max(1, maxX - minX), height: Double(layout.lines.count) * layout.boxHeight)
            gradient = ResolvedGradient(kind: f.kind, stops: f.stops, from: f.from, to: f.to, box: box)
        }

        let image = rasterize(bounds: region) { ctx in
            // The context is y-down; keep the glyphs upright (and slant them when the font has no italic face).
            let shear: CGFloat = layout.syntheticItalic ? 0.2 : 0
            ctx.textMatrix = CGAffineTransform(a: 1, b: 0, c: shear, d: -1, tx: 0, ty: 0)
            for line in layout.lines {
                guard let ct = line.ct else { continue }
                let px = line.x, baseline = line.baseline
                ctx.textPosition = CGPoint(x: px, y: baseline)
                if let sc = strokeColor, sc.a > 0 {
                    ctx.setTextDrawingMode(.stroke)
                    ctx.setStrokeColor(CGColor(colorSpace: RenderShared.srgb, components: [sc.r, sc.g, sc.b, sc.a])!)
                    ctx.setLineWidth(CGFloat(sw)); ctx.setLineJoin(.round)
                    CTLineDraw(ct, ctx)
                    ctx.textPosition = CGPoint(x: px, y: baseline)
                }
                if gradient == nil, let fc = fillColor, fc.a > 0 {
                    ctx.setTextDrawingMode(.fill)
                    ctx.setFillColor(CGColor(colorSpace: RenderShared.srgb, components: [fc.r, fc.g, fc.b, fc.a])!)
                    CTLineDraw(ct, ctx)
                }
            }
            if let g = gradient {
                // The glyphs are drawn once in a layer, then the gradient is painted over them with "source in" (only where
                // there are glyphs), then the layer lands on top of the strokes.
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setTextDrawingMode(.fill)
                ctx.setFillColor(CGColor(colorSpace: RenderShared.srgb, components: [1, 1, 1, 1])!)
                for line in layout.lines {
                    guard let ct = line.ct else { continue }
                    ctx.textPosition = CGPoint(x: line.x, y: line.baseline)
                    CTLineDraw(ct, ctx)
                }
                ctx.setBlendMode(.sourceIn)
                g.draw(in: ctx, region: region)
                ctx.endTransparencyLayer()
            }
        }
        guard var result = image else { return nil }

        if let sh = shadowSpec {
            var s = result.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: sh.c.a),
                "inputBiasVector": CIVector(x: sh.c.r, y: sh.c.g, z: sh.c.b, w: 0),
            ])
            if sh.blur > 0 { s = s.applyingGaussianBlur(sigma: min(200, sh.blur / 2)) }
            s = s.transformed(by: CGAffineTransform(translationX: sh.dx, y: -sh.dy))
            result = result.composited(over: s)
        }
        result = result.cropped(to: rect)
        let e = rect
        RenderShared.cache.setObject(result, forKey: key as NSString, cost: Int(e.width * e.height))
        return result
    }
}
