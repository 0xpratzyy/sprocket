import Foundation
import CoreImage
import CryptoKit

// The web layer: `html(markup, props)` in a script draws anything a web page can draw (HTML, CSS, SVG, canvas, WebGL) as a
// transparent layer. This file holds the pieces that touch the node tree and the renderer; the page itself lives in
// WebPage.swift and the on-disk frames in WebFrameCache.swift.
//
// How it fits together:
//   1. `Node.resolvingWeb` fills in the defaults of every html node (box = canvas, time = frame / fps).
//   2. Before the movie is written the exporter collects every `WebRequest` (markup, size, page time) of every frame, renders
//      each distinct page once, in increasing time order, into PNG files on disk (`WebFrameStore.prepare`).
//   3. While drawing, `RenderPass.renderWeb` loads the file of the node's request as a CIImage and places it. From there it is
//      an ordinary layer: effects, transform, clip, mask, opacity and blend all apply.

/// One picture of one page: the markup, the page size in CSS px (= canvas px) and the page time.
public struct WebRequest: Hashable, Sendable {
    public var markup: String
    public var width: Int
    public var height: Int
    /// Page time in whole microseconds (so equal times compare equal and make stable file names).
    public var micros: Int
    /// SHA-256 of the markup (hex, 16 bytes). Part of equality; the markup itself is not compared.
    public let digest: String

    public init(markup: String, width: Int, height: Int, time: Double) {
        self.markup = markup
        self.width = width
        self.height = height
        self.micros = Int((max(0, min(time.isFinite ? time : 0, WebLimits.maxPageTime)) * 1e6).rounded())
        self.digest = WebDigest.of(markup)
    }

    public var time: Double { Double(micros) / 1e6 }
    public static func == (a: WebRequest, b: WebRequest) -> Bool {
        a.digest == b.digest && a.width == b.width && a.height == b.height && a.micros == b.micros
    }
    public func hash(into h: inout Hasher) { h.combine(digest); h.combine(width); h.combine(height); h.combine(micros) }
}

/// The hard limits of the web layer (see API.md).
public enum WebLimits {
    public static let loadSeconds = 5.0
    public static let stepSeconds = 1.0
    public static let maxMarkupBytes = 200 * 1024
    public static let maxBox = 4096
    public static let maxPageTime = 86_400.0
}

enum WebDigest {
    private static let cache: NSCache<NSString, NSString> = { let c = NSCache<NSString, NSString>(); c.countLimit = 64; return c }()
    /// Hex SHA-256 prefix of a string; the last few results are remembered (a frame's markup is the same string every frame).
    static func of(_ text: String) -> String {
        if let hit = cache.object(forKey: text as NSString) { return hit as String }
        let d = SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        cache.setObject(d as NSString, forKey: text as NSString)
        return d
    }
}

public extension Node {
    /// True when this tree has an html node anywhere (children and masks included).
    var containsHTML: Bool {
        if type == "html" { return true }
        return (children?.contains { $0.containsHTML } ?? false) || (mask?.contains { $0.containsHTML } ?? false)
    }

    /// The same tree with the defaults of every html node written out: `x`/`y` 0, `width`/`height` the canvas, `time` the
    /// frame's time (`frame / fps`). Trees without html nodes are returned as they are.
    func resolvingWeb(frame: Int, fps: Int, canvasWidth: Int, canvasHeight: Int) -> Node {
        guard containsHTML else { return self }
        var n = self
        if n.type == "html" {
            n.x = n.x ?? 0; n.y = n.y ?? 0
            n.width = n.width ?? Double(canvasWidth); n.height = n.height ?? Double(canvasHeight)
            n.time = n.time ?? Double(frame) / Double(max(1, fps))
        }
        n.children = n.children?.map { $0.resolvingWeb(frame: frame, fps: fps, canvasWidth: canvasWidth, canvasHeight: canvasHeight) }
        n.mask = n.mask?.map { $0.resolvingWeb(frame: frame, fps: fps, canvasWidth: canvasWidth, canvasHeight: canvasHeight) }
        return n
    }

    /// Every page picture this (resolved) tree needs. An html node with an empty or negative box draws nothing and asks for
    /// nothing. Throws SprocketError(.script, "html: ...") for markup over 200 KB or a box over 4096 px.
    func webRequests() throws -> [WebRequest] {
        var out: [WebRequest] = []
        var failure: SprocketError?
        func walk(_ n: Node) {
            if n.type == "html", failure == nil, let markup = n.html, let w = fin(n.width), let h = fin(n.height), w > 0, h > 0 {
                let t = fin(n.time) ?? 0
                if markup.utf8.count > WebLimits.maxMarkupBytes {
                    failure = SprocketError(.script, "html: the markup is \(markup.utf8.count / 1024) KB; the limit is \(WebLimits.maxMarkupBytes / 1024) KB")
                } else if w > Double(WebLimits.maxBox) || h > Double(WebLimits.maxBox) {
                    failure = SprocketError(.script, "html: the box is \(Int(w.rounded(.up)))x\(Int(h.rounded(.up))); each side may be at most \(WebLimits.maxBox) px")
                } else {
                    out.append(WebRequest(markup: markup, width: Int(w.rounded(.up)), height: Int(h.rounded(.up)), time: t))
                }
            }
            n.children?.forEach(walk); n.mask?.forEach(walk)
        }
        walk(self)
        if let failure { throw failure }
        return out
    }
}

/// Tells whether a page can change with time at all, from its text (the page itself is also asked once it has loaded).
/// A page that cannot is drawn once and that picture is reused for every time.
public enum WebPageHeuristics {
    /// Words that make a page time-dependent. The check is deliberately generous: a false "dynamic" only costs render time.
    static let timeWords = ["--t", "--frame", "sprocketFrame", "<animate", "<set ", "requestAnimationFrame", "setTimeout", "setInterval",
                            "Date", "performance", "@keyframes", "animation", "transition"]
    public static func mentionsTime(_ markup: String) -> Bool { timeWords.contains { markup.contains($0) } }
}

// MARK: renderer hook

extension RenderPass {
    /// The picture of an html node (resolved by `Node.resolvingWeb`), placed at its box. nil when the picture is missing.
    func renderWeb(_ n: Node) -> CIImage? {
        guard let markup = n.html, let x = fin(n.x), let y = fin(n.y), let w = fin(n.width), let h = fin(n.height), w > 0, h > 0,
              w <= Double(WebLimits.maxBox), h <= Double(WebLimits.maxBox)
        else { return nil }
        let pw = Int(w.rounded(.up)), ph = Int(h.rounded(.up))
        guard var img = resources.webFrame(markup: markup, width: pw, height: ph, time: fin(n.time) ?? 0) else { return nil }
        let e = img.extent
        if e.origin != .zero { img = img.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y)) }
        // The page's top edge goes at node y; Core Image's y is up, so the bottom edge sits at ciY = H - (y + height).
        return img.transformed(by: CGAffineTransform(translationX: x, y: flipY(y + Double(ph))))
    }
}
