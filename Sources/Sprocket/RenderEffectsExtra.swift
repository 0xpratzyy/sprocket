import Foundation
import CoreImage
import CoreGraphics

/// Warp kernels for `wave` and `displace`: they say, for every output pixel, where in the input to read. Written in Core
/// Image's kernel language, which Apple has deprecated in favour of Metal but still compiles; if it ever stops compiling
/// the two effects pass the picture through unchanged (the render still finishes).
private enum WarpKernels {
    static let wave: CIWarpKernel? = CIWarpKernel(source: """
    kernel vec2 motionWave(float amt, float wl, float ca, float sa, float ph, float H) {
        vec2 d = destCoord();
        float yd = H - d.y;
        float t = d.x * ca + yd * sa;
        float disp = amt * sin(6.2831853 * t / wl + ph);
        return vec2(d.x + disp * sa, d.y + disp * ca);
    }
    """)

    static let displace: CIWarpKernel? = CIWarpKernel(source: """
    float hash12(vec2 p) {
        vec3 p3 = fract(vec3(p.x, p.y, p.x) * 0.1031);
        p3 = p3 + dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }
    float vnoise(vec2 p) {
        vec2 i = floor(p);
        vec2 f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        float a = hash12(i);
        float b = hash12(i + vec2(1.0, 0.0));
        float c = hash12(i + vec2(0.0, 1.0));
        float e = hash12(i + vec2(1.0, 1.0));
        return mix(mix(a, b, f.x), mix(c, e, f.x), f.y);
    }
    kernel vec2 motionDisplace(float amt, float sc, float s1, float s2) {
        vec2 d = destCoord() / sc;
        float dx = (vnoise(d + vec2(s1, s2)) - 0.5) * 2.0 * amt;
        float dy = (vnoise(d + vec2(s2 + 17.0, s1 + 31.0)) - 0.5) * 2.0 * amt;
        return destCoord() + vec2(dx, dy);
    }
    """)
}

/// A small seeded generator (splitmix64), so an effect's randomness depends only on its `seed`.
private struct SeededRandom {
    var state: UInt64
    init(seed: Double) {
        let s = Int64((max(-1e9, min(1e9, seed)) * 1000).rounded())
        state = UInt64(bitPattern: s) &* 0x9E3779B97F4A7C15 &+ 0x1234567
    }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(1 << 53)
    }
}

extension RenderPass {
    private func cmatrix(_ im: CIImage, r: [Double], g: [Double], b: [Double], a: [Double] = [0, 0, 0, 1], bias: [Double] = [0, 0, 0, 0]) -> CIImage {
        im.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r[0], y: r[1], z: r[2], w: r[3]), "inputGVector": CIVector(x: g[0], y: g[1], z: g[2], w: g[3]),
            "inputBVector": CIVector(x: b[0], y: b[1], z: b[2], w: b[3]), "inputAVector": CIVector(x: a[0], y: a[1], z: a[2], w: a[3]),
            "inputBiasVector": CIVector(x: bias[0], y: bias[1], z: bias[2], w: bias[3]),
        ])
    }

    /// The drawing-tool effects (dropShadow, wave, twirl, bulge, displace, glitch, scanlines, posterize, threshold,
    /// halftone, duotone, mirror, edges). Nil when `e.name` is not one of them.
    func applyExtraEffect(_ im: CIImage, _ e: Node.Effect) -> CIImage? {
        let amount = fin(e.amount), radius = fin(e.radius), angle = fin(e.angle)
        let W = Double(self.W), H = Double(self.H)
        switch e.name {

        case "dropShadow":
            let c = e.color.flatMap(SprocketColor.parse) ?? (0, 0, 0, 0.5)
            guard c.a > 0 else { return im }
            let r = min(300, max(0, radius ?? 10))
            let dx = max(-1e4, min(1e4, fin(e.x) ?? 0)), dy = max(-1e4, min(1e4, fin(e.y) ?? 8))
            // The shadow is the node's own alpha, filled with the colour, blurred, moved, and drawn under the node.
            var s = cmatrix(im, r: [0, 0, 0, 0], g: [0, 0, 0, 0], b: [0, 0, 0, 0], a: [0, 0, 0, c.a], bias: [c.r, c.g, c.b, 0])
            if r > 0 { s = s.applyingGaussianBlur(sigma: r / 2) }
            s = s.transformed(by: CGAffineTransform(translationX: dx, y: -dy))
            return im.composited(over: s).cropped(to: rect)

        case "wave":
            let amt = max(-1000, min(1000, amount ?? 10))
            let wl = max(1, min(1e5, fin(e.wavelength) ?? 120))
            guard amt != 0, let k = WarpKernels.wave else { return im }
            let a = (angle ?? 0) * .pi / 180, ph = (fin(e.phase) ?? 0) * .pi / 180
            let src = canvasNormalized(im).clampedToExtent()
            let grow = abs(amt) + 2
            return k.apply(extent: rect, roiCallback: { _, r in r.insetBy(dx: -grow, dy: -grow) }, image: src,
                           arguments: [amt, wl, cos(a), sin(a), ph, H])?.cropped(to: rect) ?? im

        case "displace":
            let amt = max(-1000, min(1000, amount ?? 20))
            let sc = max(2, min(1e4, fin(e.scale) ?? 120))
            guard amt != 0, let k = WarpKernels.displace else { return im }
            var rng = SeededRandom(seed: fin(e.seed) ?? 0)
            let s1 = rng.next() * 1000, s2 = rng.next() * 1000
            let src = canvasNormalized(im).clampedToExtent()
            let grow = abs(amt) + 2
            return k.apply(extent: rect, roiCallback: { _, r in r.insetBy(dx: -grow, dy: -grow) }, image: src,
                           arguments: [amt, sc, s1, s2])?.cropped(to: rect) ?? im

        case "twirl":
            let r = max(1, min(1e4, radius ?? min(W, H) / 2))
            let a = max(-3600, min(3600, angle ?? 90)) * .pi / 180
            let cx = fin(e.x) ?? W / 2, cy = fin(e.y) ?? H / 2
            // Positive angle turns the picture clockwise on screen; Core Image's y is up, so the sign flips.
            return canvasNormalized(im).clampedToExtent().applyingFilter("CITwirlDistortion", parameters: [
                kCIInputCenterKey: CIVector(x: cx, y: flipY(cy)), kCIInputRadiusKey: r, kCIInputAngleKey: -a,
            ]).cropped(to: rect)

        case "bulge":
            let r = max(1, min(1e4, radius ?? min(W, H) / 2))
            let a = max(-1, min(1, amount ?? 0.5))
            guard a != 0 else { return im }
            let cx = fin(e.x) ?? W / 2, cy = fin(e.y) ?? H / 2
            return canvasNormalized(im).clampedToExtent().applyingFilter("CIBumpDistortion", parameters: [
                kCIInputCenterKey: CIVector(x: cx, y: flipY(cy)), kCIInputRadiusKey: r, kCIInputScaleKey: a,
            ]).cropped(to: rect)

        case "glitch":
            let a = min(1, max(0, amount ?? 0.5))
            guard a > 0 else { return im }
            let n = canvasNormalized(im)
            let count = max(1, min(64, Int((fin(e.slices) ?? 10).rounded())))
            var rng = SeededRandom(seed: fin(e.seed) ?? 0)
            // Random band heights that add up to the canvas height, then some bands slide sideways (wrapping around).
            var weights = (0..<count).map { _ in 0.3 + rng.next() }
            let sum = weights.reduce(0, +)
            weights = weights.map { $0 / sum * H }
            var y = 0.0
            var out = clearCanvas
            for (i, h) in weights.enumerated() {
                let y1 = i == count - 1 ? H : (y + h).rounded()
                let band = CGRect(x: 0, y: y.rounded(), width: W, height: max(0, y1 - y.rounded()))
                y = y1
                guard band.height > 0 else { continue }
                let move = rng.next() < 0.6
                let dx = ((rng.next() * 2 - 1) * a * W * 0.2).rounded()
                var piece = n.cropped(to: band)
                if move && dx != 0 {
                    let a1 = n.transformed(by: CGAffineTransform(translationX: dx, y: 0))
                    let a2 = n.transformed(by: CGAffineTransform(translationX: dx - (dx > 0 ? W : -W), y: 0))
                    piece = a1.composited(over: a2).cropped(to: band)
                }
                out = piece.composited(over: out)
            }
            out = out.cropped(to: rect)
            var split = Node.Effect(name: "rgbSplit"); split.amount = a * W * 0.015; split.angle = 0
            return applyEffect(out, split)

        case "scanlines":
            let amt = min(1, max(0, amount ?? 0.35))
            let sp = max(2, min(500, fin(e.spacing) ?? 4))
            guard amt > 0, let gen = CIFilter(name: "CIStripesGenerator") else { return im }
            gen.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: amt), forKey: "inputColor0")
            gen.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")
            gen.setValue(sp / 2, forKey: "inputWidth")
            gen.setValue(1.0, forKey: "inputSharpness")
            gen.setValue(CIVector(x: 0, y: 0), forKey: kCIInputCenterKey)
            guard let stripes = gen.outputImage else { return im }
            let lines = stripes.transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).cropped(to: rect)
            return lines.applyingFilter("CISourceAtopCompositing", parameters: [kCIInputBackgroundImageKey: canvasNormalized(im)]).cropped(to: rect)

        case "posterize":
            let l = max(2, min(256, (fin(e.levels) ?? 6).rounded()))
            return im.applyingFilter("CIColorPosterize", parameters: ["inputLevels": l])

        case "threshold":
            let t = min(1, max(0, amount ?? 0.5))
            // luma, then a very steep ramp at the threshold: pure black or white (alpha untouched)
            let k = 1000.0, lr = 0.2126 * k, lg = 0.7152 * k, lb = 0.0722 * k, bias = -t * k
            return cmatrix(im, r: [lr, lg, lb, 0], g: [lr, lg, lb, 0], b: [lr, lg, lb, 0], bias: [bias, bias, bias, 0])

        case "halftone":
            let r = max(1, min(200, radius ?? 4))
            let n = canvasNormalized(im)
            let ht = n.applyingFilter("CICMYKHalftone", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0), kCIInputWidthKey: r * 2, kCIInputAngleKey: -(angle ?? 0) * .pi / 180,
                kCIInputSharpnessKey: 0.8,
            ])
            return ht.cropped(to: rect).applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: n]).cropped(to: rect)

        case "duotone":
            let d = e.dark.flatMap(SprocketColor.parse) ?? (0, 0, 0, 1)
            let l = e.light.flatMap(SprocketColor.parse) ?? (1, 1, 1, 1)
            func row(_ lo: Double, _ hi: Double) -> [Double] { let s = hi - lo; return [s * 0.2126, s * 0.7152, s * 0.0722, 0] }
            return cmatrix(im, r: row(d.r, l.r), g: row(d.g, l.g), b: row(d.b, l.b), bias: [d.r, d.g, d.b, 0])

        case "mirror":
            let n = canvasNormalized(im)
            if e.axis == "y" {
                let cy = flipY(min(H, max(0, fin(e.y) ?? H / 2)))   // Core Image y of the mirror line
                // Top part (above the line on screen) is reflected onto the bottom part.
                let top = n.cropped(to: CGRect(x: 0, y: cy, width: W, height: max(0, H - cy)))
                let refl = top.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * cy))
                return top.composited(over: refl).cropped(to: rect)
            } else {
                let cx = min(W, max(0, fin(e.x) ?? W / 2))
                // Left part is reflected onto the right part.
                let left = n.cropped(to: CGRect(x: 0, y: 0, width: cx, height: H))
                let refl = left.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * cx, ty: 0))
                return left.composited(over: refl).cropped(to: rect)
            }

        case "edges":
            let a = min(10, max(0, amount ?? 1))
            let n = canvasNormalized(im)
            return n.clampedToExtent().applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: a]).cropped(to: rect)
                .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: n]).cropped(to: rect)

        default:
            return nil
        }
    }
}
