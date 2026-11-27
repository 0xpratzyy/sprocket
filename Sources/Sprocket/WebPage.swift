import Foundation
import CoreGraphics
import ImageIO
import WebKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// One sealed web page, held in an offscreen WKWebView and stepped through page times for the web layer.
//
// SAFETY. Scripts are written by an AI, so the page is a sandbox with no way out:
//   * loaded with loadHTMLString(_, baseURL: nil): the page's origin is about:blank, it can read no file;
//   * a Content-Security-Policy <meta> (first thing in <head>) allows only inline script / style and data: / sprocket-asset: pictures;
//   * a WKContentRuleList blocks every URL that is not data:, about: or sprocket-asset:;
//   * the navigation delegate cancels every navigation but about:/data:, and window.open() opens nothing;
//   * there are no script message handlers: Swift talks to the page only through evaluate calls it makes itself;
//   * the only way to see a file is `sprocket-asset://ID`, served by `AssetSchemeHandler` from the exporter's asset map, images only.
//
// TIME. Rendering must be deterministic and frame-exact, so the page never sees the wall clock. A script injected at document
// start (`shim` below) replaces Date, performance.now, Math.random, setTimeout / setInterval and requestAnimationFrame with
// virtual versions driven by the step; CSS and Web animations are paused from the start (a CSS rule) and every step sets their
// `currentTime` to t * 1000. See `step` in the shim for the exact order.

/// What one page needs from the host.
struct WebPageSetup {
    var markup: String
    var width: Int
    var height: Int
    /// Asset id -> file, the only files the page can ask for (images).
    var assets: [String: URL]
}

@MainActor
final class WebPage {
    private let setup: WebPageSetup
    private let webView: WKWebView
    private let delegate = PageDelegate()
    private let handler: AssetSchemeHandler
    #if os(macOS)
    private let window: NSWindow
    #else
    private let window: UIWindow
    #endif
    private var closed = false
    private let document: String
    private(set) var logs: [String] = []

    /// True when nothing on the page can change with time: no animations, no script timers or frame callbacks, no
    /// `sprocketFrame`, no SMIL. Valid after `load()`.
    private(set) var isStatic = false

    // MARK: setup

    private static var compiledRules: WKContentRuleList?

    static let csp = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data: sprocket-asset:; font-src data:; media-src 'none'; connect-src 'none'"

    /// Blocks everything that is not data:, about: or sprocket-asset: (WebKit applies it to every sub-resource request).
    static let ruleJSON = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^sprocket-asset:"},"action":{"type":"ignore-previous-rules"}}]
    """

    private static func contentRules() async throws -> WKContentRuleList {
        if let r = compiledRules { return r }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Sprocket-web-rules", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WKContentRuleListStore(url: dir)
        guard let store else { throw SprocketError(.script, "html: cannot create the network block list") }
        do {
            guard let r = try await store.compileContentRuleList(forIdentifier: "sprocket-web-v2", encodedContentRuleList: ruleJSON) else {
                throw SprocketError(.script, "html: cannot compile the network block list")
            }
            compiledRules = r
            return r
        } catch let e as SprocketError { throw e }
        catch { throw SprocketError(.script, "html: cannot compile the network block list: \(error.localizedDescription)") }
    }

    /// A command-line tool has no NSApplication until something makes one; WebKit needs it to talk to the window server.
    /// A host app already has one, and nothing changes then.
    static func prepareApp() {
        #if os(macOS)
        if NSApp == nil {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)   // no Dock icon, no menu bar
            app.finishLaunching()
        }
        #endif
    }

    init(_ setup: WebPageSetup) async throws {
        Self.prepareApp()
        self.setup = setup
        self.handler = AssetSchemeHandler(assets: setup.assets)
        let rules = try await Self.contentRules()

        let (document, lineOffset) = Self.document(for: setup)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(handler, forURLScheme: "sprocket-asset")
        config.userContentController.add(rules)
        config.userContentController.addUserScript(WKUserScript(
            source: Self.shim.replacingOccurrences(of: "__LINE_OFFSET__", with: String(lineOffset)),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let frame = CGRect(x: 0, y: 0, width: setup.width, height: setup.height)
        let view = WKWebView(frame: frame, configuration: config)
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        webView = view

        // A transparent page needs a transparent view, on both platforms.
        #if os(macOS)
        view.underPageBackgroundColor = .clear
        // WKWebView paints an opaque white backing unless told not to. The key is how AppKit spells it; guard it, since a
        // missing selector would raise an Objective-C exception.
        if view.responds(to: NSSelectorFromString("_setDrawsBackground:")) { view.setValue(false, forKey: "drawsBackground") }
        // WebKit only paints a view that is in a window which is on screen. A borderless, clear window far outside every
        // display counts as "on screen" for painting but is never seen or clicked.
        let win = NSWindow(contentRect: CGRect(x: -30000, y: -30000, width: CGFloat(setup.width), height: CGFloat(setup.height)),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = false
        win.ignoresMouseEvents = true
        win.contentView = view
        win.orderFrontRegardless()
        window = win
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.underPageBackgroundColor = .clear
        // A WKWebView that is not in a visible window may not paint at all on iOS, so snapshots would come back blank.
        // The view is therefore hosted in its own UIWindow: not hidden, below every other window, and placed entirely off
        // the screen so the user never sees it. (Unverified on a device: this could not be run on iOS here.)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let win = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        win.frame = CGRect(x: -CGFloat(setup.width) - 100, y: 0, width: CGFloat(setup.width), height: CGFloat(setup.height))
        win.windowLevel = UIWindow.Level(rawValue: -1000)
        win.backgroundColor = .clear
        win.isOpaque = false
        let host = UIViewController()
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(origin: .zero, size: frame.size)
        host.view.addSubview(view)
        win.rootViewController = host
        win.isHidden = false
        window = win
        #endif
        self.document = document
    }

    /// The full document for a markup string: the CSP and the page set-up come first in `<head>`. Returns the number of
    /// lines this adds before the author's first line (to report errors against the author's lines).
    private static func document(for setup: WebPageSetup) -> (String, Int) {
        let head = "<meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">" +
            "<style>*,*::before,*::after{animation-play-state:paused !important}" +
            "html{width:\(setup.width)px;height:\(setup.height)px;overflow:hidden;background:transparent}" +
            "html,body{margin:0;padding:0;background:transparent}</style>"
        let m = setup.markup
        let lower = m.lowercased()
        if lower.contains("<html") || lower.contains("<!doctype") {
            if let r = m.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                return (m.replacingCharacters(in: r, with: String(m[r]) + head), 0)
            }
            if let r = m.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                return (m.replacingCharacters(in: r, with: String(m[r]) + "<head>" + head + "</head>"), 0)
            }
            return ("<!doctype html><head>" + head + "</head>" + m, 0)
        }
        return ("<!doctype html><html><head>" + head + "</head><body>\n" + m + "\n</body></html>", 1)
    }

    func close() {
        guard !closed else { return }
        closed = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        #if os(macOS)
        window.contentView = nil
        window.orderOut(nil)
        window.close()
        #else
        webView.removeFromSuperview()
        window.isHidden = true
        window.rootViewController = nil
        #endif
    }

    // MARK: load

    /// Loads the page and waits for fonts and pictures. Throws SprocketError(.script, "html: ...") when it takes over 5 s or
    /// the page throws.
    func load() async throws {
        let deadline = Date().addingTimeInterval(WebLimits.loadSeconds)
        try await Timed.run(WebLimits.loadSeconds, "loading the page took longer than \(Int(WebLimits.loadSeconds)) s") { finish in
            self.delegate.onLoad = finish
            self.webView.loadHTMLString(self.document, baseURL: nil)
        }
        let left = max(0.2, deadline.timeIntervalSinceNow)
        let reply = try await evaluate("return await window.__sprocketHost.ready();", [:], seconds: left,
                                       timeout: "loading the page (fonts, pictures) took longer than \(Int(WebLimits.loadSeconds)) s")
        do { try consume(reply, phase: "while loading") }
        catch let e as SprocketError where e.message.contains("Script error.") {
            // A page that is loaded without a base URL has its load-time errors hidden by WebKit ("Script error.", no line).
            // Run the page's inline scripts again in an isolated world (not subject to the page's CSP, so eval is allowed) to get
            // the real message. Only reached on the failure path, after which the page is thrown away.
            let detail = try? await evaluate(Self.diagnoseBody, [:], world: .defaultClient, seconds: 2, timeout: "diagnosis timed out") as? String
            if let detail, !detail.isEmpty { throw SprocketError(.script, "html: the page threw an error while loading: \(detail)") }
            throw e
        }
        let staticReply = try await evaluate("return window.__sprocketHost.isStatic();", [:], seconds: 2, timeout: "the page does not answer")
        isStatic = (staticReply as? Bool) == true && !WebPageHeuristics.mentionsTime(setup.markup)
    }

    // MARK: step + snapshot

    /// Sets the page to time `t` (seconds) and frame number `frame`: pauses and seeks every animation, sets `--t` / `--frame`,
    /// runs the virtual timers and frame callbacks, calls `window.sprocketFrame(t, frame)` and waits for layout.
    func step(t: Double, frame: Int) async throws {
        let reply = try await evaluate("return await window.__sprocketHost.step(t, frame);", ["t": t, "frame": frame],
                                       seconds: WebLimits.stepSeconds,
                                       timeout: "one frame step (t = \(String(format: "%.3f", t)) s) took longer than \(Int(WebLimits.stepSeconds)) s")
        try consume(reply, phase: "at t = \(String(format: "%.3f", t)) s")
    }

    /// The page as exactly `width` x `height` premultiplied RGBA pixels, sRGB, transparent where the page draws nothing.
    func snapshot() async throws -> CGImage {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = CGRect(x: 0, y: 0, width: setup.width, height: setup.height)
        cfg.snapshotWidth = NSNumber(value: setup.width)
        cfg.afterScreenUpdates = true
        let cg: CGImage = try await Timed.run(5, "taking the snapshot took longer than 5 s") { finish in
            self.webView.takeSnapshot(with: cfg) { image, error in
                #if os(macOS)
                var rect = CGRect(x: 0, y: 0, width: CGFloat(self.setup.width), height: CGFloat(self.setup.height))
                let out = image?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                #else
                let out = image?.cgImage
                #endif
                if let out { finish(.success(out)) }
                else { finish(.failure(SprocketError(.script, "html: the page could not be photographed (\(error?.localizedDescription ?? "no image"))"))) }
            }
        }
        guard let fixed = Self.normalise(cg, width: setup.width, height: setup.height) else {
            throw SprocketError(.script, "html: the snapshot could not be converted to \(setup.width)x\(setup.height) pixels")
        }
        return fixed
    }

    /// Turns a snapshot into an exact w x h sRGB premultiplied-RGBA bitmap. The system hands back more pixels than asked on a
    /// Retina display (2x on a Mac, 2x or 3x on iPhone). When the size is a whole multiple they are averaged down with a plain box
    /// filter, so an edge that sits on a CSS pixel boundary stays exactly sharp and the text gets 4x (or 9x) anti-aliasing; any
    /// other size is scaled with CoreGraphics.
    static func normalise(_ cg: CGImage, width: Int, height: Int) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let k = cg.width / max(1, width)
        guard k > 1, cg.width == k * width, cg.height == k * height else {
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)
            else { return nil }
            ctx.interpolationQuality = .high
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return ctx.makeImage()
        }
        guard let big = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info),
              let small = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info),
              let src = big.data?.assumingMemoryBound(to: UInt8.self), let dst = small.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        big.clear(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        big.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let sRow = big.bytesPerRow, dRow = small.bytesPerRow, n = k * k, half = n / 2
        for y in 0..<height {
            let d = dst + y * dRow
            for x in 0..<width {
                var r = 0, g = 0, b = 0, a = 0
                for ky in 0..<k {
                    var p = src + (y * k + ky) * sRow + x * k * 4
                    for _ in 0..<k { r += Int(p[0]); g += Int(p[1]); b += Int(p[2]); a += Int(p[3]); p += 4 }
                }
                let o = d + x * 4
                o[0] = UInt8((r + half) / n); o[1] = UInt8((g + half) / n); o[2] = UInt8((b + half) / n); o[3] = UInt8((a + half) / n)
            }
        }
        return small.makeImage()
    }

    // MARK: JS plumbing

    /// Runs a function body in the page world, with a time limit. The reply is the body's return value.
    private func evaluate(_ body: String, _ args: [String: Any], world: WKContentWorld = .page, seconds: Double, timeout: String) async throws -> Any? {
        try await Timed.run(seconds, timeout) { (finish: @escaping (Result<Any?, Error>) -> Void) in
            self.webView.callAsyncJavaScript(body, arguments: args, in: nil, in: world) { result in
                switch result {
                case .success(let v): finish(.success(v))
                case .failure(let e):
                    let text = (e as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? e.localizedDescription
                    finish(.failure(SprocketError(.script, "html: \(text)")))
                }
            }
        }
    }

    /// Reads the page's reply (`{"errors": [...], "logs": [...]}`): logs are kept for the caller, errors are thrown.
    private func consume(_ reply: Any?, phase: String) throws {
        guard let text = reply as? String, let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let lines = obj["logs"] as? [String] { logs.append(contentsOf: lines) }
        if let errors = obj["errors"] as? [String], let first = errors.first {
            let more = errors.count > 1 ? " (and \(errors.count - 1) more)" : ""
            throw SprocketError(.script, "html: the page threw an error \(phase): \(first)\(more)")
        }
    }

    /// Re-runs the page's inline scripts in order, in the isolated world, and returns "Name: message" of the first one that throws
    /// (redeclaration errors, caused by running a script twice, are skipped).
    private static let diagnoseBody = """
        const scripts = Array.from(document.querySelectorAll('script:not([src])'));
        for (const s of scripts) {
          try { (0, eval)(s.textContent); }
          catch (e) {
            const m = String(e && e.message);
            if (/already been declared|duplicate variable|redeclar/i.test(m)) continue;
            return (e && e.name ? e.name : 'Error') + ': ' + m;
          }
        }
        return null;
        """

    /// Log lines collected since the last call.
    func takeLogs() -> [String] { let l = logs; logs = []; return l }
}

// MARK: time limits

/// Wraps a callback-style call in an async function that gives up after `seconds`, with a SprocketError.
enum Timed {
    final class Once<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<T, Error>?
        init(_ c: CheckedContinuation<T, Error>) { cont = c }
        func finish(_ r: Result<T, Error>) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(with: r)
        }
    }

    @MainActor
    static func run<T>(_ seconds: Double, _ what: String, _ start: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let once = Once(cont)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { once.finish(.failure(SprocketError(.script, "html: \(what)"))) }
            start { once.finish($0) }
        }
    }
}

// MARK: navigation

/// Allows the one document load, cancels every other navigation, opens no windows.
@MainActor
final class PageDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onLoad: ((Result<Void, Error>) -> Void)?

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? "about"
        decisionHandler(scheme == "about" || scheme == "data" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoad?(.success(())); onLoad = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onLoad?(.failure(SprocketError(.script, "html: the page failed to load: \(error.localizedDescription)"))); onLoad = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onLoad?(.failure(SprocketError(.script, "html: the page failed to load: \(error.localizedDescription)"))); onLoad = nil
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        onLoad?(.failure(SprocketError(.script, "html: the web content process ended (the page used too much memory or crashed)"))); onLoad = nil
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}

// MARK: assets

/// Serves `sprocket-asset://ID` to the page: image assets from the exporter's asset map, nothing else. No paths, no video or
/// audio, an unknown id is a 404.
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "sprocket-asset"
    private let assets: [String: URL]
    private let lock = NSLock()
    private var cache: [String: (data: Data, mime: String)] = [:]

    init(assets: [String: URL]) { self.assets = assets }

    /// The asset id inside `sprocket-asset://ID[/...][?...]`, percent-decoded. Browsers lower-case the host of a URL, so when
    /// the exact id is unknown a case-insensitive match is accepted if it is unambiguous.
    func assetID(for url: URL) -> String? {
        let text = url.absoluteString
        guard text.lowercased().hasPrefix(Self.scheme + "://") else { return nil }
        var rest = String(text.dropFirst(Self.scheme.count + 3))
        if let end = rest.firstIndex(where: { "/?#".contains($0) }) { rest = String(rest[..<end]) }
        let id = rest.removingPercentEncoding ?? rest
        if assets[id] != nil { return id }
        let hits = assets.keys.filter { $0.caseInsensitiveCompare(id) == .orderedSame }
        return hits.count == 1 ? hits[0] : nil
    }

    /// The bytes and MIME type of an image asset, or nil when the id is unknown or the file is not a readable image.
    func load(id: String) -> (data: Data, mime: String)? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[id] { return c }
        guard let url = assets[id], let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= 256 << 20,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source), let ut = UTType(type as String), ut.conforms(to: .image),
              CGImageSourceGetStatus(source) == .statusComplete
        else { return nil }
        let entry = (data: data, mime: ut.preferredMIMEType ?? "application/octet-stream")
        if cache.count < 16 { cache[id] = entry }
        return entry
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url
        let headers = ["Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"]
        guard let url, let id = assetID(for: url), let entry = load(id: id) else {
            let u = url ?? URL(string: "sprocket-asset://unknown")!
            if let r = HTTPURLResponse(url: u, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: headers) { task.didReceive(r) }
            task.didReceive(Data())
            task.didFinish()
            return
        }
        var h = headers
        h["Content-Type"] = entry.mime
        h["Content-Length"] = String(entry.data.count)
        if let r = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: h) { task.didReceive(r) }
        task.didReceive(entry.data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

// MARK: the injected script

extension WebPage {
    /// Runs before any page script. Owns the virtual clock. Exposed to Swift (and, harmlessly, to the page) as
    /// `window.__sprocketHost`.
    static let shim = #"""
    (function () {
      var LINE_OFFSET = __LINE_OFFSET__;
      var host = { now: 0, dynamic: false, errors: [], logs: [], timers: [], raf: [], nextId: 1, seq: 0 };
      Object.defineProperty(window, "__sprocketHost", { value: host, enumerable: false });
      var RealDate = Date;
      var realTimeout = window.setTimeout.bind(window);

      // console -> collected logs (Swift forwards them to the script's own log)
      function fmt(v) {
        try {
          if (typeof v === "string") return v;
          if (v instanceof Error) return v.stack || v.message;
          var s = JSON.stringify(v);
          return s === undefined ? String(v) : s;
        } catch (e) { return String(v); }
      }
      ["log", "info", "warn", "error", "debug"].forEach(function (k) {
        console[k] = function () {
          var parts = [];
          for (var i = 0; i < arguments.length; i++) parts.push(fmt(arguments[i]));
          var s = parts.join(" ");
          if (s.length > 2000) s = s.slice(0, 2000);
          if (host.logs.length < 400) host.logs.push("html: " + s);
        };
      });

      // uncaught errors and rejected promises
      function note(msg) { if (host.errors.length < 20) host.errors.push(String(msg)); }
      window.addEventListener("error", function (e) {
        var m = (e.error && e.error.message) ? e.error.message : e.message;
        var line = e.lineno ? " (page line " + Math.max(1, e.lineno - LINE_OFFSET) + ")" : "";
        note(m + line);
      });
      window.addEventListener("unhandledrejection", function (e) {
        var r = e.reason;
        note("unhandled promise rejection: " + ((r && r.message) ? r.message : fmt(r)));
      });

      // Math.random: seeded, so the same page load draws the same picture.
      var seed = 0x2545F491;
      Math.random = function () {
        seed = (seed + 0x6D2B79F5) | 0;
        var t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
        t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
      };

      // Date and performance read the virtual clock (page time in milliseconds).
      function FakeDate() {
        host.dynamic = true;
        if (!(this instanceof FakeDate)) return new RealDate(host.now).toString();
        if (arguments.length === 0) return new RealDate(host.now);
        var a = arguments;
        switch (a.length) {
          case 1: return new RealDate(a[0]);
          case 2: return new RealDate(a[0], a[1]);
          case 3: return new RealDate(a[0], a[1], a[2]);
          case 4: return new RealDate(a[0], a[1], a[2], a[3]);
          case 5: return new RealDate(a[0], a[1], a[2], a[3], a[4]);
          case 6: return new RealDate(a[0], a[1], a[2], a[3], a[4], a[5]);
          default: return new RealDate(a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
        }
      }
      FakeDate.prototype = RealDate.prototype;
      FakeDate.now = function () { host.dynamic = true; return host.now; };
      FakeDate.UTC = RealDate.UTC;
      FakeDate.parse = RealDate.parse;
      window.Date = FakeDate;
      try { Object.defineProperty(performance, "now", { value: function () { host.dynamic = true; return host.now; }, configurable: true }); } catch (e) {}
      try { Object.defineProperty(document.timeline, "currentTime", { get: function () { return host.now; }, configurable: true }); } catch (e) {}

      // Virtual timers and frame callbacks: they run inside the frame step, never by themselves.
      function addTimer(fn, ms, args, every) {
        host.dynamic = true;
        if (typeof fn !== "function") return 0;
        ms = Math.max(0, Number(ms) || 0);
        var id = host.nextId++;
        host.timers.push({ id: id, at: host.now + ms, seq: host.seq++, fn: fn, args: args, every: every ? Math.max(1, ms) : 0 });
        return id;
      }
      window.setTimeout = function (fn, ms) { return addTimer(fn, ms, Array.prototype.slice.call(arguments, 2), false); };
      window.setInterval = function (fn, ms) { return addTimer(fn, ms, Array.prototype.slice.call(arguments, 2), true); };
      window.clearTimeout = window.clearInterval = function (id) {
        host.timers = host.timers.filter(function (t) { return t.id !== id; });
      };
      window.requestAnimationFrame = function (cb) {
        host.dynamic = true;
        var id = host.nextId++;
        if (typeof cb === "function") host.raf.push({ id: id, cb: cb });
        return id;
      };
      window.cancelAnimationFrame = function (id) { host.raf = host.raf.filter(function (r) { return r.id !== id; }); };

      // WebGL: keep the drawing buffer, so the picture is still there when the snapshot is taken.
      var realGetContext = HTMLCanvasElement.prototype.getContext;
      HTMLCanvasElement.prototype.getContext = function (type, attrs) {
        if (typeof type === "string" && type.indexOf("webgl") === 0) attrs = Object.assign({ alpha: true, premultipliedAlpha: true }, attrs, { preserveDrawingBuffer: true });
        return realGetContext.call(this, type, attrs);
      };

      function freeze(t) {
        var ms = t * 1000, list = document.getAnimations();
        for (var i = 0; i < list.length; i++) { try { list[i].pause(); list[i].currentTime = ms; } catch (e) {} }
        var svgs = document.querySelectorAll("svg");
        for (var j = 0; j < svgs.length; j++) {
          try { if (svgs[j].pauseAnimations) { svgs[j].pauseAnimations(); svgs[j].setCurrentTime(t); } } catch (e) {}
        }
      }
      function guard(fn, what) { try { return fn(); } catch (e) { note(what + ": " + ((e && e.message) ? e.message : fmt(e))); } }
      function drain() {
        var out = JSON.stringify({ errors: host.errors, logs: host.logs });
        host.errors = []; host.logs = [];
        return out;
      }

      // Fonts and pictures: wait until they are ready, so the first picture is complete.
      host.ready = async function () {
        try { await document.fonts.ready; } catch (e) {}
        var urls = {};
        function addURL(text) {
          if (!text) return;
          var re = /url\((?:"|')?(sprocket-asset:[^"')]+|data:[^"')]+)(?:"|')?\)/g, m;
          while ((m = re.exec(text)) !== null) urls[m[1]] = true;
        }
        try {
          var all = document.querySelectorAll("*");
          for (var i = 0; i < all.length && i < 4000; i++) {
            var cs = getComputedStyle(all[i]);
            addURL(cs.backgroundImage); addURL(cs.maskImage); addURL(cs.webkitMaskImage); addURL(cs.borderImageSource); addURL(cs.listStyleImage);
          }
          var svgImgs = document.querySelectorAll("image");
          for (var k = 0; k < svgImgs.length; k++) {
            var h = svgImgs[k].getAttribute("href") || svgImgs[k].getAttribute("xlink:href");
            if (h) urls[h] = true;
          }
          var pending = [];
          Object.keys(urls).slice(0, 64).forEach(function (u) {
            var im = new Image(); im.src = u;
            pending.push(im.decode ? im.decode().catch(function () {}) : Promise.resolve());
          });
          Array.prototype.forEach.call(document.images, function (im) {
            pending.push(im.decode ? im.decode().catch(function () {}) : Promise.resolve());
          });
          await Promise.all(pending);
        } catch (e) {}
        await new Promise(function (r) { realTimeout(r, 0); });
        return drain();
      };

      host.isStatic = function () {
        if (host.dynamic || typeof window.sprocketFrame === "function") return false;
        if (document.querySelector("animate, animateTransform, animateMotion, set")) return false;
        return document.getAnimations().length === 0;
      };

      // One frame step. Order: (1) pause every animation and seek it to t, (2) set --t and --frame on :root, (3) run the
      // virtual timers due by t, then the frame callbacks, then window.sprocketFrame(t, frame) (awaited), (4) seek again
      // (animations made in step 3) and force style, layout and paint to settle. Swift takes the picture after that.
      host.step = async function (t, frame) {
        host.now = t * 1000;
        var root = document.documentElement;
        guard(function () { freeze(t); }, "animation seek");
        root.style.setProperty("--t", String(t));
        root.style.setProperty("--frame", String(frame));
        guard(function () {
          var guardCount = 0;
          for (;;) {
            var due = host.timers.filter(function (x) { return x.at <= host.now; })
              .sort(function (a, b) { return a.at - b.at || a.seq - b.seq; })[0];
            if (!due || ++guardCount > 10000) break;
            if (due.every) { due.at += due.every; due.seq = host.seq++; }
            else host.timers = host.timers.filter(function (x) { return x !== due; });
            guard(function () { due.fn.apply(window, due.args); }, "timer");
          }
          var cbs = host.raf; host.raf = [];
          cbs.forEach(function (r) { guard(function () { r.cb(host.now); }, "requestAnimationFrame"); });
        }, "timers");
        if (typeof window.sprocketFrame === "function") {
          try {
            var r = window.sprocketFrame(t, frame);
            if (r && typeof r.then === "function") await r;
          } catch (e) { note("sprocketFrame: " + ((e && e.message) ? e.message : fmt(e))); }
        }
        guard(function () { freeze(t); }, "animation seek");
        void document.documentElement.offsetHeight;
        void getComputedStyle(root).getPropertyValue("--t");
        return drain();
      };
    })();
    """#
}
