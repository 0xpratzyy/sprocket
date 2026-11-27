import Foundation
import JavaScriptCore

/// Set by the watchdog callback when JavaScriptCore terminates a script for running too long.
final class ScriptTimeoutFlag { var fired = false }

/// Collects console output from the script (capped).
final class ScriptLogStore: @unchecked Sendable {
    static let maxLines = 200
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if lines.count < Self.maxLines { lines.append(line) }
    }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

/// Problems found while the script ran (a font that is not installed, named in `layoutText`), de-duplicated, in order.
/// The exporter drains them into `SprocketExporter.warnings`.
final class ScriptWarningStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String] = []
    private var seen = Set<String>()
    func add(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        if seen.insert(message).inserted { pending.append(message) }
    }
    func drain() -> [String] { lock.lock(); defer { lock.unlock() }; let p = pending; pending = []; return p }
}

/// The canvas width, known once the script has called `composition()`; `layoutText` needs it for the default wrap width.
final class ScriptCanvasBox: @unchecked Sendable { nonisolated(unsafe) var width = 1080 }

/// JavaScriptCore's execution time limit. `JSContextGroupSetExecutionTimeLimit` is exported by the framework
/// (it is in JavaScriptCore.tbd) but is not declared in the public SDK headers, so it is looked up with dlsym.
enum ScriptWatchdog {
    typealias Callback = @convention(c) (UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Bool
    typealias SetFn = @convention(c) (UnsafeRawPointer?, Double, Callback?, UnsafeMutableRawPointer?) -> Void
    typealias ClearFn = @convention(c) (UnsafeRawPointer?) -> Void

    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    static let setLimit: SetFn? = dlsym(rtldDefault, "JSContextGroupSetExecutionTimeLimit").map { unsafeBitCast($0, to: SetFn.self) }
    static let clearLimit: ClearFn? = dlsym(rtldDefault, "JSContextGroupClearExecutionTimeLimit").map { unsafeBitCast($0, to: ClearFn.self) }
    static var available: Bool { setLimit != nil && clearLimit != nil }

    private static let onExpire: Callback = { _, info in
        if let info { Unmanaged<ScriptTimeoutFlag>.fromOpaque(info).takeUnretainedValue().fired = true }
        return true // terminate the script
    }

    /// Runs `body` with a CPU-time limit on the context's JS VM. Returns true when the limit fired.
    static func run(_ context: JSContext, seconds: Double, _ body: () -> Void) -> Bool {
        guard let set = setLimit, let clear = clearLimit, let group = JSContextGetGroup(context.jsGlobalContextRef) else {
            body(); return false
        }
        let flag = ScriptTimeoutFlag()
        let raw = UnsafeRawPointer(group)
        set(raw, seconds, onExpire, Unmanaged.passUnretained(flag).toOpaque())
        body()
        clear(raw)
        return flag.fired
    }
}

enum ScriptErrors {
    static let userURL = "composition.js"
    static let preludeURL = "sprocket-prelude.js"

    /// Turns a JS exception into a SprocketError with the 1-based line in the author's file.
    static func make(_ exc: JSValue?, kind: SprocketError.Kind = .script, context: String? = nil) -> SprocketError {
        var message = "script error"
        var line: Int?
        if let exc {
            if exc.isObject {
                let msg = exc.objectForKeyedSubscript("message")
                let name = exc.objectForKeyedSubscript("name")
                let m = (msg?.isUndefined ?? true) ? exc.toString() ?? "script error" : msg?.toString() ?? "script error"
                if let n = name, n.isString, let ns = n.toString(), ns != "Error", !m.hasPrefix(ns) { message = "\(ns): \(m)" } else { message = m }
                let src = exc.objectForKeyedSubscript("sourceURL")
                let l = exc.objectForKeyedSubscript("line")
                if let src, src.isString, src.toString()?.hasSuffix(userURL) == true, let l, l.isNumber {
                    line = Int(l.toInt32())
                } else if let stack = exc.objectForKeyedSubscript("stack"), stack.isString, let s = stack.toString() {
                    if let r = s.range(of: "\(userURL):(\\d+)", options: .regularExpression) {
                        let digits = s[r].dropFirst(userURL.count + 1)
                        line = Int(digits)
                    }
                }
            } else {
                // A thrown string, number or other primitive carries no line or stack in JavaScriptCore.
                let kind = exc.isString ? "a string" : exc.isNumber ? "a number" : exc.isBoolean ? "a boolean" : exc.isNull ? "null" : exc.isUndefined ? "undefined" : "a value"
                let shown = exc.isString ? "\"\(exc.toString() ?? "")\"" : (exc.toString() ?? "")
                message = "the script threw \(kind), not an Error: \(shown). JavaScript gives no line number for that; " +
                          "use throw new Error(\"...\") and the error will include the line"
            }
        }
        if let context { message = "\(context): \(message)" }
        return SprocketError(kind, message, line: line)
    }
}
