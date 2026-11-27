import Foundation
import JavaScriptCore

/// Runs one composition script. Owned by the SCRIPT worker; the public surface below is fixed.
///
/// Everything touching the JSContext is serialised by one lock, so `node(frame:)` may be called from any thread.
/// The context has no network, file, timer or DOM APIs (plain JavaScriptCore provides none and none are added).
public final class SprocketScript: @unchecked Sendable {
    public let config: CompositionConfig

    /// Lines the script printed with console.log (at most 200).
    public var logs: [String] { logStore.all }

    static let loadLimitSeconds = 2.0
    static let frameLimitSeconds = 0.25

    private let lock = NSLock()
    private let context: JSContext
    private let frameFn: JSValue
    private let logStore: ScriptLogStore
    private let warningStore: ScriptWarningStore

    /// Warnings raised while the script ran (for example a font named in `layoutText` that is not installed), each once.
    /// Returns what is new since the last call.
    func drainWarnings() -> [String] { warningStore.drain() }

    /// Loads the prelude, runs `source`, and reads the composition it registered. Throws SprocketError(.script / .timeout).
    public init(source: String) throws {
        guard ScriptWatchdog.available else {
            throw SprocketError(.script, "the JavaScript time limit is unavailable on this system; refusing to run scripts")
        }
        guard let ctx = JSContext() else { throw SprocketError(.script, "could not create a JavaScript context") }
        let store = ScriptLogStore()
        let logBlock: @convention(block) (String) -> Void = { store.append($0) }
        ctx.setObject(logBlock, forKeyedSubscript: "__motionLog" as NSString)
        // layoutText(): per-character positions from the same CoreText layout the renderer draws with.
        let warnings = ScriptWarningStore()
        let canvas = ScriptCanvasBox()
        let layoutBlock: @convention(block) (String) -> String = { json in
            guard let node = try? JSONDecoder().decode(Node.self, from: Data(json.utf8)), let str = node.text else { return "[]" }
            if let f = node.font, !f.isEmpty, !SprocketFonts.isInstalled(f) { warnings.add(SprocketFonts.missingMessage(f)) }
            guard let layout = TextLayout.make(node, canvasWidth: canvas.width) else { return "[]" }
            let items = layout.glyphs(original: str).map { g -> [String: Any] in
                ["char": g.char, "index": g.index, "line": g.line, "x": g.x, "y": g.y, "width": g.width, "height": g.height]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: items), let out = String(data: data, encoding: .utf8) else { return "[]" }
            return out
        }
        ctx.setObject(layoutBlock, forKeyedSubscript: "__motionLayoutText" as NSString)

        // Prelude (separate evaluation, so its lines never offset the author's).
        guard let url = Bundle.module.url(forResource: "prelude", withExtension: "js", subdirectory: "Prelude"),
              let prelude = try? String(contentsOf: url, encoding: .utf8) else {
            throw SprocketError(.script, "the Sprocket prelude is missing from the bundle")
        }
        ctx.exception = nil
        _ = ctx.evaluateScript(prelude, withSourceURL: URL(string: ScriptErrors.preludeURL))
        if let e = ctx.exception { throw ScriptErrors.make(e, context: "prelude") }

        // The author's script.
        let expired = ScriptWatchdog.run(ctx, seconds: Self.loadLimitSeconds) {
            _ = ctx.evaluateScript(source, withSourceURL: URL(string: ScriptErrors.userURL))
        }
        if expired {
            ctx.exception = nil
            throw SprocketError(.timeout, "timeout while loading the script: running the top level of the script took longer than the \(Int(Self.loadLimitSeconds)) s load limit. " +
                              "Look for a loop that never ends (while/for at the top level) or very heavy set-up work; the engine cannot tell which line it was on")
        }
        if let e = ctx.exception { throw ScriptErrors.make(e) }

        guard let host = ctx.objectForKeyedSubscript("__motion"), host.isObject,
              let count = host.invokeMethod("registrations", withArguments: []) else {
            throw SprocketError(.script, "the Sprocket runtime is not available")
        }
        let calls = Int(count.toInt32())
        guard calls == 1 else {
            throw SprocketError(.script, calls == 0
                ? "composition() was never called; call it once at the top level of the script"
                : "composition() was called \(calls) times; it must be called exactly once")
        }
        guard let cfgText = host.invokeMethod("configJSON", withArguments: [])?.toString(),
              let cfgData = cfgText.data(using: .utf8) else {
            throw SprocketError(.script, "composition() config could not be read")
        }
        let cfg: CompositionConfig
        do { cfg = try JSONDecoder().decode(CompositionConfig.self, from: cfgData) }
        catch { throw SprocketError(.script, "invalid composition config: \(Self.describe(error))") }
        guard (16...4096).contains(cfg.width), cfg.width % 2 == 0 else {
            throw SprocketError(.script, "invalid composition config: width must be an even integer 16...4096 (got \(cfg.width))")
        }
        guard (16...4096).contains(cfg.height), cfg.height % 2 == 0 else {
            throw SprocketError(.script, "invalid composition config: height must be an even integer 16...4096 (got \(cfg.height))")
        }
        guard (1...120).contains(cfg.fps) else { throw SprocketError(.script, "invalid composition config: fps must be 1...120 (got \(cfg.fps))") }
        guard (1...36000).contains(cfg.durationInFrames) else {
            throw SprocketError(.script, "invalid composition config: durationInFrames must be 1...36000 (got \(cfg.durationInFrames))")
        }
        guard let fn = host.objectForKeyedSubscript("frame"), fn.isObject else {
            throw SprocketError(.script, "the Sprocket runtime is not available")
        }
        canvas.width = cfg.width
        self.context = ctx
        self.warningStore = warnings
        self.logStore = store
        self.frameFn = fn
        self.config = cfg
    }

    /// The node tree for one frame (0-based). Deterministic: the same frame always gives the same tree.
    public func node(frame: Int) throws -> Node {
        let (text, f) = try frameJSON(frame)
        do { return try JSONDecoder().decode(Node.self, from: Data(text.utf8)) }
        catch { throw SprocketError(.script, "frame \(f) returned an invalid node tree: \(Self.describe(error))") }
    }

    /// Adds a line to `logs` (the web layer forwards a page's console output here).
    func appendLog(_ line: String) { logStore.append(line) }

    /// The same tree as JSON text, for debugging and tests.
    public func json(frame: Int) throws -> String { try frameJSON(frame).0 }

    private func frameJSON(_ requested: Int) throws -> (String, Int) {
        let f = min(max(requested, 0), config.durationInFrames - 1)
        lock.lock(); defer { lock.unlock() }
        var result: JSValue?
        context.exception = nil
        let expired = ScriptWatchdog.run(context, seconds: Self.frameLimitSeconds) {
            result = frameFn.call(withArguments: [f])
        }
        if expired {
            context.exception = nil
            throw SprocketError(.timeout, "timeout while rendering frame \(f): render() ran longer than the \(Int(Self.frameLimitSeconds * 1000)) ms limit for one frame. " +
                              "Look for a loop that never ends or very heavy work per frame; the engine cannot tell which line it was on")
        }
        if let e = context.exception {
            context.exception = nil
            var err = ScriptErrors.make(e)
            err.message = "frame \(f): \(err.message)"
            throw err
        }
        guard let text = result, text.isString, let s = text.toString() else {
            throw SprocketError(.script, "frame \(f) produced no result")
        }
        return (s, f)
    }

    private static func describe(_ error: Error) -> String {
        if let d = error as? DecodingError {
            switch d {
            case .keyNotFound(let k, _): return "missing \"\(k.stringValue)\""
            case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
                var path = c.codingPath.map { $0.stringValue }.joined(separator: ".")
                if let r = try? NSRegularExpression(pattern: "\\.?Index (\\d+)") {
                    path = r.stringByReplacingMatches(in: path, range: NSRange(path.startIndex..., in: path), withTemplate: "[$1]")
                }
                return path.isEmpty ? c.debugDescription : "\(path): \(c.debugDescription)"
            @unknown default: return "\(d)"
            }
        }
        return "\(error)"
    }
}
