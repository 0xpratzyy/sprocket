import Foundation

/// The contract between the script (which returns this tree as JSON for each frame) and the renderer (which draws it).
/// Coordinates are pixels, origin top-left, y down. Unknown `type`s draw nothing. See API.md for the full meaning of every field.
public struct Node: Codable, Sendable, Equatable {
    /// "group", "solid", "rect", "ellipse", "path", "gradient", "image", "video", "text"
    public var type: String

    // Every node
    public var opacity: Double?
    public var transform: Transform?
    /// "normal" (default), "multiply", "screen", "overlay", "add", "darken", "lighten", "softLight", "hardLight", "difference"
    public var blend: String?
    /// Another tree; this node shows only where the mask is opaque ("alpha", default) or bright ("luma").
    public var mask: [Node]?
    public var maskMode: String?
    /// Rounded-rectangle clip in canvas pixels, applied after the transform.
    public var clip: Clip?
    public var effects: [Effect]?

    // group
    public var children: [Node]?

    // Geometry: rect, ellipse, image, video, gradient, text (x, y, width). Missing = the whole canvas.
    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?

    // solid, rect, ellipse, path (fill), text
    public var color: String?
    public var radius: Double?
    public var stroke: String?
    public var strokeWidth: Double?
    /// Stroke style (rect, ellipse, path): "butt" (default), "round", "square"; "miter" (default), "round", "bevel".
    public var lineCap: String?
    public var lineJoin: String?
    /// Dash pattern in pixels (on, off, on, off ...) and where in the pattern the stroke starts.
    public var dash: [Double]?
    public var dashOffset: Double?
    /// Draws only part of the stroke: fractions 0...1 of the outline's length. The fill is unaffected.
    public var trim: Trim?
    /// rect, ellipse, path, text: a gradient used instead of `color` as the fill.
    public var fill: GradientFill?

    // path: SVG path data
    public var d: String?

    // gradient
    public var kind: String?            // "linear" (default) or "radial"
    public var stops: [GradientStop]?
    public var from: Point?             // canvas pixels
    public var to: Point?

    // image, video
    public var src: String?             // an asset id the host maps to a file
    public var time: Double?            // video: seconds into the source file
    public var fit: String?             // "cover" (default), "contain", "fill"
    public var focusX: Double?          // 0...1, which part stays in view when "cover" crops. Default 0.5
    public var focusY: Double?
    /// video only: nil draws the clip itself; "person" or "subject" draws a white-on-black cut-out mask of the clip
    /// (made on demand by the exporter), placed exactly like the clip would be. See `cutout()` in API.md.
    public var matte: String?

    // html: a web layer. `html` is the page's markup; x, y, width, height are its box in canvas pixels (default the canvas)
    // and `time` is the page time in seconds (default: the frame's time). See WebLayer.swift.
    public var html: String?

    // text
    public var text: String?
    public var font: String?
    public var size: Double?
    public var weight: Double?          // 100...900
    public var align: String?           // "left", "center" (default), "right"
    public var lineHeight: Double?      // multiple of size
    public var letterSpacing: Double?   // pixels
    public var shadow: Shadow?
    public var italic: Bool?

    public init(type: String) { self.type = type }

    public struct Transform: Codable, Sendable, Equatable {
        public var translateX: Double?
        public var translateY: Double?
        public var scale: Double?
        public var scaleX: Double?
        public var scaleY: Double?
        public var rotate: Double?      // degrees, clockwise
        public var originX: Double?     // canvas pixels; default canvas centre
        public var originY: Double?
        public var skewX: Double?       // degrees
        public var skewY: Double?
        public var rotateX: Double?     // degrees, 3D tilt about the origin
        public var rotateY: Double?
        public var perspective: Double? // px, default 1000
        public init() {}
    }
    public struct Trim: Codable, Sendable, Equatable { public var start: Double?; public var end: Double? }
    /// A gradient given inline (the `fill` prop); same meaning as the fields of the `gradient` node.
    public struct GradientFill: Codable, Sendable, Equatable {
        public var kind: String?
        public var stops: [GradientStop]?
        public var from: Point?
        public var to: Point?
    }
    public struct Clip: Codable, Sendable, Equatable {
        public var x: Double; public var y: Double; public var width: Double; public var height: Double
        public var radius: Double?
    }
    public struct Effect: Codable, Sendable, Equatable {
        public var name: String
        public var amount: Double?
        public var radius: Double?
        public var angle: Double?
        public var x: Double?
        public var y: Double?
        public var color: String?
        public var seed: Double?
        public var matrix: [Double]?
        public var levels: Double?
        public var spacing: Double?
        public var wavelength: Double?
        public var phase: Double?
        public var slices: Double?
        public var axis: String?
        public var dark: String?
        public var light: String?
        public var scale: Double?
    }
    public struct GradientStop: Codable, Sendable, Equatable { public var at: Double; public var color: String }
    public struct Point: Codable, Sendable, Equatable { public var x: Double; public var y: Double }
    public struct Shadow: Codable, Sendable, Equatable {
        public var color: String?; public var blur: Double?; public var x: Double?; public var y: Double?
    }

    /// The source time a video node asks for: before 0 (or NaN, or -infinity) is 0 (the first frame); +infinity is the largest
    /// finite time, which holds the last frame like any time past the end.
    public static func videoTime(_ t: Double?) -> Double {
        guard let t, !t.isNaN else { return 0 }
        if t == .infinity { return Double.greatestFiniteMagnitude }
        return max(0, t)
    }

    /// One video frame the tree needs: asset id, source time and, for a cut-out mask, its kind. The clip itself and its
    /// mask are different requests.
    public struct VideoRequest: Hashable, Sendable {
        public var src: String
        public var time: Double
        /// nil: the clip. "person" / "subject": the mask of the clip.
        public var matte: String?
        public init(src: String, time: Double, matte: String? = nil) { self.src = src; self.time = time; self.matte = matte }
    }

    /// Every video frame this tree needs, masks included.
    public var videoRequests: [VideoRequest] {
        var out: [VideoRequest] = []
        func walk(_ n: Node) {
            if n.type == "video", let s = n.src { out.append(VideoRequest(src: s, time: Node.videoTime(n.time), matte: n.matte)) }
            n.children?.forEach(walk); n.mask?.forEach(walk)
        }
        walk(self)
        return out
    }
    /// Every image asset id this tree needs.
    public var imageSources: [String] {
        var out: [String] = []
        func walk(_ n: Node) {
            if n.type == "image", let s = n.src { out.append(s) }
            n.children?.forEach(walk); n.mask?.forEach(walk)
        }
        walk(self)
        return out
    }
}

/// What the script declares once: the canvas and the sound.
public struct CompositionConfig: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var durationInFrames: Int
    public var audio: [AudioClip]?
    public var background: String?

    public var duration: Double { Double(durationInFrames) / Double(max(1, fps)) }

    public struct AudioClip: Codable, Sendable, Equatable {
        public var src: String              // asset id (audio file, or a video whose sound is used)
        public var startFrame: Int?         // where it starts on the timeline. Default 0
        public var offset: Double?          // seconds into the source. Default 0
        public var durationInFrames: Int?   // default: to the end of the source or the composition
        public var volume: Double?          // 0...1. Default 1
        public var fadeIn: Double?          // seconds
        public var fadeOut: Double?
    }
}

public struct SprocketError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: String, Sendable { case script, timeout, asset, render, export, cancelled }
    public var kind: Kind
    public var message: String
    /// 1-based line in the user's script, when known.
    public var line: Int?
    public init(_ kind: Kind, _ message: String, line: Int? = nil) { self.kind = kind; self.message = message; self.line = line }
    public var errorDescription: String? { line.map { "\(message) (line \($0))" } ?? message }
}
