import Foundation
import CoreImage
import CoreGraphics

extension RenderPass {
    /// Pads a layer to exactly the canvas (transparent where it has no pixels), so effects see canvas edges, not layer edges.
    func canvasNormalized(_ im: CIImage) -> CIImage {
        if im.extent == rect { return im }
        return im.composited(over: clearCanvas).cropped(to: rect)
    }

    /// Gaussian blur that holds the canvas border steady (no transparent or dark rim), then crops back.
    private func edgeClampedBlur(_ im: CIImage, sigma: Double) -> CIImage {
        guard sigma > 0 else { return im }
        return canvasNormalized(im).clampedToExtent().applyingGaussianBlur(sigma: min(sigma, 300)).cropped(to: rect)
    }

    private func clamped(_ im: CIImage, _ filter: String, _ params: [String: Any]) -> CIImage {
        canvasNormalized(im).clampedToExtent().applyingFilter(filter, parameters: params).cropped(to: rect)
    }

    func applyEffects(_ input: CIImage, _ effects: [Node.Effect]) -> CIImage {
        var im = input
        for e in effects { im = applyEffect(im, e) }
        return im
    }

    private func matrix(_ im: CIImage, r: [Double], g: [Double], b: [Double], a: [Double], bias: [Double]) -> CIImage {
        im.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r[0], y: r[1], z: r[2], w: r[3]), "inputGVector": CIVector(x: g[0], y: g[1], z: g[2], w: g[3]),
            "inputBVector": CIVector(x: b[0], y: b[1], z: b[2], w: b[3]), "inputAVector": CIVector(x: a[0], y: a[1], z: a[2], w: a[3]),
            "inputBiasVector": CIVector(x: bias[0], y: bias[1], z: bias[2], w: bias[3]),
        ])
    }

    private func controls(_ im: CIImage, brightness: Double = 0, contrast: Double = 1, saturation: Double = 1) -> CIImage {
        im.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation,
        ])
    }

    func applyEffect(_ im: CIImage, _ e: Node.Effect) -> CIImage {
        let amount = fin(e.amount), radius = fin(e.radius), angle = fin(e.angle)
        switch e.name {
        case "blur":
            return edgeClampedBlur(im, sigma: max(0, radius ?? 0))

        case "motionBlur":
            let r = min(300, max(0, radius ?? 0))
            guard r > 0 else { return im }
            return clamped(im, "CIMotionBlur", [kCIInputRadiusKey: r, kCIInputAngleKey: -(angle ?? 0) * .pi / 180])

        case "zoomBlur":
            let a = min(300, max(0, amount ?? 0))
            guard a > 0 else { return im }
            let cx = fin(e.x) ?? Double(W) / 2, cy = fin(e.y) ?? Double(H) / 2
            return clamped(im, "CIZoomBlur", [kCIInputAmountKey: a, kCIInputCenterKey: CIVector(x: cx, y: flipY(cy))])

        case "brightness":
            return controls(im, brightness: min(1, max(-1, amount ?? 0)))
        case "contrast":
            return controls(im, contrast: min(4, max(0, amount ?? 1)))
        case "saturation":
            return controls(im, saturation: min(4, max(0, amount ?? 1)))
        case "exposure":
            return im.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: min(10, max(-10, amount ?? 0))])
        case "hue":
            return im.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: (angle ?? 0) * .pi / 180])
        case "invert":
            return im.applyingFilter("CIColorInvert")
        case "sepia":
            return im.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: min(1, max(0, amount ?? 1))])
        case "grayscale":
            return controls(im, saturation: 1 - min(1, max(0, amount ?? 1)))

        case "vignette":
            let n = canvasNormalized(im)
            return n.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: min(2, max(0, amount ?? 1)) * 2, kCIInputRadiusKey: min(2, max(0, radius ?? 1)) * 0.5,
            ]).cropped(to: rect)

        case "pixellate":
            let s = min(500, max(1, radius ?? 8))
            return canvasNormalized(im).applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: s, kCIInputCenterKey: CIVector(x: 0, y: 0),
            ]).cropped(to: rect)

        case "sharpen":
            return im.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: min(2, max(0, amount ?? 0.5))])

        case "glow":
            let a = min(1, max(0, amount ?? 0.5))
            let r = max(0, radius ?? 20)
            guard a > 0, r > 0 else { return im }
            let n = canvasNormalized(im)
            // Only the bright parts bloom: a knee at 0.4, so flat mid-tones and darks do not get lifted.
            let k = 1 / 0.6
            let bright = matrix(n, r: [k, 0, 0, 0], g: [0, k, 0, 0], b: [0, 0, k, 0], a: [0, 0, 0, 1], bias: [-0.4 * k, -0.4 * k, -0.4 * k, 0])
                .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
            let halo = applyOpacity(edgeClampedBlur(bright, sigma: r), a)
            return halo.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: n]).cropped(to: rect)

        case "grain":
            return grain(im, amount: min(1, max(0, amount ?? 0.4)), seed: fin(e.seed) ?? 0)

        case "rgbSplit":
            let d = max(-500, min(500, amount ?? 0))
            guard d != 0 else { return im }
            let a = (angle ?? 0) * .pi / 180
            // y-down angle: +x right, +y down; Core Image's y is up.
            let dx = cos(a) * d, dy = -sin(a) * d
            let n = canvasNormalized(im).clampedToExtent()
            func shifted(_ ox: Double, _ oy: Double) -> CIImage {
                n.transformed(by: CGAffineTransform(translationX: ox, y: oy)).cropped(to: rect)
            }
            func channel(_ im: CIImage, _ r: Double, _ g: Double, _ b: Double) -> CIImage {
                matrix(im, r: [r, 0, 0, 0], g: [0, g, 0, 0], b: [0, 0, b, 0], a: [0, 0, 0, 1], bias: [0, 0, 0, 0])
            }
            let red = channel(shifted(dx, dy), 1, 0, 0)
            let green = channel(shifted(0, 0), 0, 1, 0)
            let blue = channel(shifted(-dx, -dy), 0, 0, 1)
            // Per-component maximum of the three single-channel images: each keeps only its own channel, so the maximum is the
            // combined colour, and the alpha is the union of the three shifted alphas (an addition would let alpha pass 1).
            let rg = red.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: green])
            return blue.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: rg]).cropped(to: rect)

        case "tint":
            guard let cs = e.color, let c = SprocketColor.parse(cs) else { return im }
            let a = min(1, max(0, amount ?? 0.5)) * c.a
            guard a > 0 else { return im }
            let overlay = CIImage(color: ciColor((c.r, c.g, c.b, a))).cropped(to: rect)
            return overlay.applyingFilter("CISourceAtopCompositing", parameters: [kCIInputBackgroundImageKey: im])

        case "colorMatrix":
            guard let m = e.matrix, m.count == 20, m.allSatisfy({ $0.isFinite }) else { return im }
            return matrix(im, r: Array(m[0..<4]), g: Array(m[5..<9]), b: Array(m[10..<14]), a: Array(m[15..<19]),
                          bias: [m[4], m[9], m[14], m[19]])

        default:
            return applyExtraEffect(im, e) ?? im   // the drawing-tool effects live in RenderEffectsExtra.swift; unknown names are ignored
        }
    }

    /// Film grain: the same pattern for the same seed. Mid-grey noise laid over the picture with the overlay blend, kept inside the layer's alpha.
    private func grain(_ im: CIImage, amount: Double, seed: Double) -> CIImage {
        guard amount > 0, let gen = CIFilter(name: "CIRandomGenerator")?.outputImage else { return im }
        let s = Int64((max(-1e9, min(1e9, seed)) * 1000).rounded())
        let ox = Double(((s &* 7919) % 4096 + 4096) % 4096), oy = Double(((s &* 104729) % 4096 + 4096) % 4096)
        let noise = gen.transformed(by: CGAffineTransform(translationX: ox, y: oy)).cropped(to: rect).settingAlphaOne(in: rect)
        // Every channel takes the red noise value; centred on 0.5 and scaled by amount.
        let grey = matrix(noise, r: [amount, 0, 0, 0], g: [amount, 0, 0, 0], b: [amount, 0, 0, 0], a: [0, 0, 0, 0],
                          bias: [0.5 - 0.5 * amount, 0.5 - 0.5 * amount, 0.5 - 0.5 * amount, 1])
        let n = canvasNormalized(im)
        let blended = grey.applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: n])
        return blended.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: n]).cropped(to: rect)
    }
}
