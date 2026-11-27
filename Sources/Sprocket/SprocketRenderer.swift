import Foundation
import CoreImage
import CoreGraphics
import Metal

/// Pictures a frame's tree may need. The exporter fills one of these before each frame is drawn.
public protocol FrameResources: Sendable {
    /// The decoded, upright video frame for this asset at this source time, or nil if it is missing.
    func videoFrame(src: String, time: Double) -> CIImage?
    func image(src: String) -> CIImage?
    /// The cut-out mask (white where the person / subject is, black elsewhere) of a clip at a source time, or nil if none
    /// is available. `matte` is "person" or "subject". The default (for conformers written before masks existed) is nil.
    func videoFrame(src: String, time: Double, matte: String?) -> CIImage?
    /// The picture of a web layer (see WebLayer.swift): the page `markup` at this size (CSS px = canvas px) and page time, or
    /// nil if none was made. The default is nil.
    func webFrame(markup: String, width: Int, height: Int, time: Double) -> CIImage?
}

public extension FrameResources {
    func videoFrame(src: String, time: Double, matte: String?) -> CIImage? {
        matte == nil ? videoFrame(src: src, time: time) : nil
    }
    func webFrame(markup: String, width: Int, height: Int, time: Double) -> CIImage? { nil }
}

/// Draws a node tree. Owned by the RENDERER worker; the public surface below is fixed.
///
/// Conventions: node space is pixels, top-left origin, y down. Core Image is bottom-left, so every image is placed with
/// `ciY = canvasHeight - nodeY`. The conversion happens in exactly two places: `RenderPass.rasterize` (vector bitmaps) and
/// the media / transform helpers, which all use `RenderPass.flipY`.
/// Per node the order is: content, effects, transform, clip, mask, opacity, then blend onto what is below.
public final class SprocketRenderer: @unchecked Sendable {
    public init() {}

    /// The frame as an image whose extent is exactly (0, 0, width, height), opaque, in Core Image's bottom-left space.
    /// Never throws: a node it cannot draw is skipped.
    public func render(_ node: Node, config: CompositionConfig, resources: FrameResources) -> CIImage {
        let w = max(1, min(config.width, 16384)), h = max(1, min(config.height, 16384))
        let pass = RenderPass(width: w, height: h, resources: resources)
        var bg = (r: 0.0, g: 0.0, b: 0.0, a: 1.0)
        if let s = config.background, let c = SprocketColor.parse(s) { bg = c }
        // Over black, so the frame is opaque whatever the background's alpha was.
        let base = CIImage(color: pass.ciColor((bg.r * bg.a, bg.g * bg.a, bg.b * bg.a, 1))).cropped(to: pass.rect)
        let out = pass.renderList([node], base: base, depth: 0) ?? base
        return out.cropped(to: pass.rect)
    }

    /// The shared Metal-backed context used to rasterise frames.
    /// Working space is sRGB (gamma-encoded) so colours pass through untouched and blend modes behave like they do in video tools.
    public static let context: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let options: [CIContextOption: Any] = [
            .workingColorSpace: srgb,
            .outputColorSpace: srgb,
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()
}

@inline(__always) func fin(_ v: Double?) -> Double? {
    if let v, v.isFinite { return v }
    return nil
}

enum RenderShared {
    static let srgb: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// Rasterised vector shapes, gradients, text and clip masks, keyed on their geometry and the canvas size.
    static let cache: NSCache<NSString, CIImage> = {
        let c = NSCache<NSString, CIImage>()
        c.totalCostLimit = 256 << 20
        return c
    }()
}

/// One frame's drawing state. Cheap to make; holds no state between frames besides the shared cache.
final class RenderPass {
    let W: Int, H: Int
    let rect: CGRect
    let resources: FrameResources
    let clearCanvas: CIImage
    static let maxDepth = 48

    init(width: Int, height: Int, resources: FrameResources) {
        W = width; H = height
        rect = CGRect(x: 0, y: 0, width: width, height: height)
        self.resources = resources
        clearCanvas = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: rect)
    }

    func ciColor(_ c: (r: Double, g: Double, b: Double, a: Double)) -> CIColor {
        CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a, colorSpace: RenderShared.srgb)
            ?? CIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    /// Node y (down) to Core Image y (up).
    func flipY(_ y: Double) -> Double { Double(H) - y }

    // MARK: layers

    /// Draws `nodes` first to last onto `base` (or onto nothing) and returns the flattened result, nil if nothing was drawn.
    func renderList(_ nodes: [Node], base: CIImage?, depth: Int) -> CIImage? {
        var acc = base
        var i = 0
        while i < nodes.count {
            let n = nodes[i]
            if isPlainShape(n) {
                // Runs of plain vector shapes share one bitmap (a mask of 100 rects is one raster, not 100).
                var batch: [Node] = []
                while i < nodes.count, isPlainShape(nodes[i]) { batch.append(nodes[i]); i += 1 }
                if let img = shapeBatch(batch) { acc = composite(img, over: acc, blend: nil, opaqueBase: base != nil) }
                continue
            }
            if let layer = renderLayer(n, depth: depth) { acc = composite(layer, over: acc, blend: n.blend, opaqueBase: base != nil) }
            i += 1
        }
        return acc
    }

    private func isPlainShape(_ n: Node) -> Bool {
        guard n.type == "rect" || n.type == "ellipse" || n.type == "path" else { return false }
        if hasNonFiniteGeometry(n) { return false }   // takes the single-layer path, which draws nothing
        if let o = n.opacity, !(o >= 1) { return false }
        if n.transform != nil || n.clip != nil { return false }
        if let b = n.blend, b != "normal" { return false }
        if let m = n.mask, !m.isEmpty { return false }
        if let e = n.effects, !e.isEmpty { return false }
        return true
    }

    /// One node with all its own props applied, cropped to the canvas. Nil if it draws nothing.
    func renderLayer(_ n: Node, depth: Int) -> CIImage? {
        guard depth < RenderPass.maxDepth else { return nil }
        let opacity = n.opacity.map { $0.isNaN ? 1 : min(1, max(0, $0)) } ?? 1
        guard opacity > 0 else { return nil }
        guard !hasNonFiniteGeometry(n) else { return nil }   // rule: a non-finite geometry value draws nothing

        var content: CIImage?
        switch n.type {
        case "group": content = renderList(n.children ?? [], base: nil, depth: depth + 1)
        case "solid":
            if let s = n.color, let c = SprocketColor.parse(s), c.a > 0 {
                content = CIImage(color: ciColor(premultiplied: c)).cropped(to: rect)
            }
        case "rect", "ellipse", "path": content = shapeBatch([n])
        case "gradient": content = renderGradient(n)
        case "image": content = n.src.flatMap { resources.image(src: $0) }.flatMap { placeMedia($0, n) }
        case "video":
            if let s = n.src, let f = resources.videoFrame(src: s, time: Node.videoTime(n.time), matte: n.matte) { content = placeMedia(f, n) }
        case "text": content = renderText(n)
        case "html": content = renderWeb(n)
        default: break
        }
        guard var im = content else { return nil }

        if let fx = n.effects, !fx.isEmpty { im = applyEffects(im, fx) }
        if let t = n.transform {
            guard let tt = applyTransform(im, t) else { return nil }
            im = tt
        }
        if let c = n.clip {
            guard let m = clipMask(c) else { return nil }
            im = im.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: m])
        }
        if let maskNodes = n.mask, !maskNodes.isEmpty {
            guard let m = renderList(maskNodes, base: nil, depth: depth + 1) else { return nil }
            var alpha = m
            if n.maskMode == "luma" {
                let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: rect)
                alpha = m.composited(over: black).cropped(to: rect).applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                ])
            }
            im = im.applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: alpha])
        }
        if opacity < 1 { im = applyOpacity(im, opacity) }
        return im.cropped(to: rect)
    }

    /// True when any geometry number (position, size, radius, font size, stroke width, transform, clip, gradient points) is NaN or infinite.
    func hasNonFiniteGeometry(_ n: Node) -> Bool {
        func bad(_ v: Double?) -> Bool { if let v { return !v.isFinite }; return false }
        if bad(n.x) || bad(n.y) || bad(n.width) || bad(n.height) || bad(n.radius) || bad(n.size) || bad(n.strokeWidth) { return true }
        if let t = n.transform,
           bad(t.translateX) || bad(t.translateY) || bad(t.scale) || bad(t.scaleX) || bad(t.scaleY) || bad(t.rotate) || bad(t.originX) || bad(t.originY)
            || bad(t.skewX) || bad(t.skewY) || bad(t.rotateX) || bad(t.rotateY) || bad(t.perspective) { return true }
        if let c = n.clip, !(c.x.isFinite && c.y.isFinite && c.width.isFinite && c.height.isFinite) || bad(n.clip?.radius) { return true }
        if let p = n.from, !(p.x.isFinite && p.y.isFinite) { return true }
        if let p = n.to, !(p.x.isFinite && p.y.isFinite) { return true }
        if let f = n.fill, let p = f.from, !(p.x.isFinite && p.y.isFinite) { return true }
        if let f = n.fill, let p = f.to, !(p.x.isFinite && p.y.isFinite) { return true }
        return false
    }

    func ciColor(premultiplied c: (r: Double, g: Double, b: Double, a: Double)) -> CIColor {
        // CIColor is straight (non-premultiplied); CIImage(color:) premultiplies it itself.
        ciColor(c)
    }

    func applyOpacity(_ im: CIImage, _ o: Double) -> CIImage {
        im.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: o),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
    }

    func composite(_ layer: CIImage, over acc: CIImage?, blend: String?, opaqueBase: Bool = false) -> CIImage {
        guard let acc else { return layer.cropped(to: rect) }
        let name: String
        switch blend ?? "normal" {
        case "multiply": name = "CIMultiplyBlendMode"
        case "screen": name = "CIScreenBlendMode"
        case "overlay": name = "CIOverlayBlendMode"
        case "add": name = "CIAdditionCompositing"
        case "darken": name = "CIDarkenBlendMode"
        case "lighten": name = "CILightenBlendMode"
        case "softLight": name = "CISoftLightBlendMode"
        case "hardLight": name = "CIHardLightBlendMode"
        case "difference": name = "CIDifferenceBlendMode"
        default: name = "CISourceOverCompositing"
        }
        var out = layer.applyingFilter(name, parameters: [kCIInputBackgroundImageKey: acc])
        if blend == "add" && opaqueBase {
            // An addition lets alpha pass 1; the base is opaque, so the result is too.
            out = out.settingAlphaOne(in: rect)
        }
        return out.cropped(to: rect)
    }

    // MARK: transform / clip

    /// Scale, skew, 3D tilt, rotate clockwise, then translate, about the origin (default: canvas centre). Nil if the node vanishes.
    func applyTransform(_ im: CIImage, _ t: Node.Transform) -> CIImage? {
        let sx = fin(t.scaleX) ?? fin(t.scale) ?? 1
        let sy = fin(t.scaleY) ?? fin(t.scale) ?? 1
        let rot = fin(t.rotate) ?? 0
        let tx = fin(t.translateX) ?? 0, ty = fin(t.translateY) ?? 0
        let skx = max(-89.9, min(89.9, fin(t.skewX) ?? 0)), sky = max(-89.9, min(89.9, fin(t.skewY) ?? 0))
        let tilt = (fin(t.rotateX) ?? 0) != 0 || (fin(t.rotateY) ?? 0) != 0
        if sx == 1 && sy == 1 && rot == 0 && tx == 0 && ty == 0 && skx == 0 && sky == 0 && !tilt { return im }
        guard sx != 0, sy != 0, abs(sx) < 1e4, abs(sy) < 1e4, abs(tx) < 1e7, abs(ty) < 1e7 else { return nil }
        let ox = fin(t.originX) ?? Double(W) / 2, oy = fin(t.originY) ?? Double(H) / 2
        // A 3D tilt needs a perspective mapping of the layer's corners (see RenderDrawing.swift).
        if tilt { return applyTransform3D(im, t: t, sx: sx, sy: sy, rot: rot, tx: tx, ty: ty, ox: ox, oy: oy) }
        let p = CGPoint(x: ox, y: flipY(oy))
        var a = CGAffineTransform(translationX: -p.x, y: -p.y)
        a = a.concatenating(CGAffineTransform(scaleX: sx, y: sy))
        if skx != 0 || sky != 0 {
            // Skew in screen terms (y down): x += tan(skewX) * y, y += tan(skewY) * x. Core Image's y is up, so the y terms flip sign.
            a = a.concatenating(CGAffineTransform(a: 1, b: -tan(sky * .pi / 180), c: -tan(skx * .pi / 180), d: 1, tx: 0, ty: 0))
        }
        a = a.concatenating(CGAffineTransform(rotationAngle: -rot * .pi / 180))   // clockwise on screen = counter-clockwise in y-up
        a = a.concatenating(CGAffineTransform(translationX: p.x + tx, y: p.y - ty))
        return im.transformed(by: a)
    }

    func clipMask(_ c: Node.Clip) -> CIImage? {
        guard c.x.isFinite, c.y.isFinite, c.width.isFinite, c.height.isFinite, c.width > 0, c.height > 0 else { return nil }
        let r = min(max(0, fin(c.radius) ?? 0), min(c.width, c.height) / 2)
        let key = "clip|\(c.x)|\(c.y)|\(c.width)|\(c.height)|\(r)|\(W)x\(H)"
        let box = CGRect(x: c.x, y: c.y, width: c.width, height: c.height)
        return cachedRaster(key: key, bounds: box) { ctx in
            ctx.setFillColor(CGColor(colorSpace: RenderShared.srgb, components: [1, 1, 1, 1])!)
            ctx.addPath(r > 0 ? CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil) : CGPath(rect: box, transform: nil))
            ctx.fillPath()
        }
    }

    // MARK: rasterising

    /// Rasterises into a bitmap covering `bounds` (node space, clipped to the canvas) and places it on the canvas.
    /// `draw` works in node space (y down). This is where the y flip for vector content happens.
    func rasterize(bounds: CGRect, draw: (CGContext) -> Void) -> CIImage? {
        let b = bounds.intersection(rect.insetBy(dx: 0, dy: 0))
        guard !b.isNull, b.width.isFinite, b.height.isFinite else { return nil }
        let r = CGRect(x: floor(b.minX), y: floor(b.minY), width: ceil(b.maxX) - floor(b.minX), height: ceil(b.maxY) - floor(b.minY))
            .intersection(rect)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        let w = Int(r.width), h = Int(r.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: RenderShared.srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)   // memory row 0 is the top: now y down
        ctx.translateBy(x: -r.minX, y: -r.minY)
        draw(ctx)
        guard let cg = ctx.makeImage() else { return nil }
        // The bitmap's bottom edge sits at node y = r.maxY, i.e. ciY = H - r.maxY.
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: r.minX, y: flipY(r.maxY)))
    }

    func cachedRaster(key: String, bounds: CGRect, draw: (CGContext) -> Void) -> CIImage? {
        let k = key as NSString
        if let hit = RenderShared.cache.object(forKey: k) { return hit }
        guard let img = rasterize(bounds: bounds, draw: draw) else { return nil }
        let e = img.extent
        RenderShared.cache.setObject(img, forKey: k, cost: Int(e.width * e.height * 4))
        return img
    }
}
