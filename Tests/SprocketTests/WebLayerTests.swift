import XCTest
import CoreImage
import CoreGraphics
import ImageIO
import Network
@testable import Sprocket

/// The web layer (`html(...)`): a sealed WKWebView draws each page, the exporter caches the pictures on disk and the renderer
/// composites them like any other node. These tests run real WebKit pages (about 0.3 s for the first one).
final class WebLayerTests: XCTestCase {
    var cacheDir: URL!

    override func setUp() {
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("web-tests-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: cacheDir) }

    // MARK: helpers

    func bitmap(_ cg: CGImage) -> Bitmap {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Bitmap(w: w, h: h, data: buf)
    }

    func composition(_ w: Int, _ h: Int, fps: Int = 10, frames: Int = 10, bg: String = "#000000", body: String) -> String {
        "composition({ width: \(w), height: \(h), fps: \(fps), durationInFrames: \(frames), background: \"\(bg)\" }, function (frame, ctx) {\n\(body)\n});"
    }

    func exporter(_ source: String, assets: [String: URL] = [:]) throws -> (SprocketExporter, SprocketScript) {
        let script = try SprocketScript(source: source)
        return (SprocketExporter(script: script, assets: assets, matteCacheDirectory: cacheDir.appendingPathComponent("m"),
                               webCacheDirectory: cacheDir.appendingPathComponent("w")), script)
    }

    func still(_ source: String, frame: Int = 0, assets: [String: URL] = [:]) async throws -> Bitmap {
        let (ex, _) = try exporter(source, assets: assets)
        return bitmap(try await ex.still(frame: frame))
    }

    let bgGreen = RGBA(r: 0, g: 255, b: 0, a: 255)
    let red = RGBA(r: 255, g: 0, b: 0, a: 255)

    // MARK: static box, transparency, placement

    func testStaticBoxIsTransparentAndPlacedAtItsBox() async throws {
        // A 100x100 page drawn at (50, 20) on a 200x200 green canvas; inside it a red 60x40 rectangle at (20, 30).
        let src = composition(200, 200, bg: "#00ff00", body: """
          return html("<div style='position:absolute;left:20px;top:30px;width:60px;height:40px;background:#f00'></div>", { x: 50, y: 20, width: 100, height: 100 });
        """)
        let (ex, _) = try exporter(src)
        let b = bitmap(try await ex.still(frame: 0))
        XCTAssertEqual(b.w, 200)
        XCTAssertTrue(b.px(100, 70).near(red), "\(b.px(100, 70))")       // inside the red rectangle: canvas (70..130, 50..90)
        XCTAssertTrue(b.px(60, 70).near(bgGreen), "\(b.px(60, 70))")     // left of it, inside the box: transparent, background shows
        XCTAssertTrue(b.px(100, 40).near(bgGreen), "\(b.px(100, 40))")   // above it
        XCTAssertTrue(b.px(100, 95).near(bgGreen), "\(b.px(100, 95))")   // below it
        XCTAssertTrue(b.px(10, 10).near(bgGreen), "\(b.px(10, 10))")     // outside the box
        XCTAssertTrue(b.px(129, 89).near(red) && b.px(131, 91).near(bgGreen))
        // The cached picture itself has real alpha: corners 0, content 255.
        let files = try FileManager.default.contentsOfDirectory(at: ex.webCacheDirectoryForTests, includingPropertiesForKeys: nil).filter { $0.pathExtension == "png" }
        XCTAssertEqual(files.count, 1)
        let png = bitmap(try XCTUnwrap(CGImageSourceCreateWithURL(files[0] as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }))
        XCTAssertEqual(png.w, 100); XCTAssertEqual(png.h, 100)
        XCTAssertEqual(png.px(0, 0).a, 0)
        XCTAssertEqual(png.px(99, 99).a, 0)
        XCTAssertEqual(png.px(50, 50), RGBA(r: 255, g: 0, b: 0, a: 255))
    }

    func testDefaultBoxIsTheWholeCanvas() async throws {
        let b = try await still(composition(120, 80, bg: "#00ff00", body: """
          return html("<div style='position:absolute;right:0;bottom:0;width:20px;height:10px;background:#f00'></div>");
        """))
        XCTAssertTrue(b.px(119, 79).near(red), "\(b.px(119, 79))")
        XCTAssertTrue(b.px(99, 69).near(bgGreen), "\(b.px(99, 69))")
    }

    // MARK: time

    /// A 20px red square slides right at 80 px/s with a plain CSS animation.
    static let slide = """
      <style>div { position:absolute; top:40px; left:0; width:20px; height:20px; background:#f00; animation: go 1s linear both; }
      @keyframes go { from { left: 0px } to { left: 80px } }</style><div></div>
    """

    func testCSSKeyframesAreFrameExact() async throws {
        let src = composition(120, 100, fps: 10, frames: 10, bg: "#00ff00", body: "return html(`\(Self.slide)`);")
        let (ex, _) = try exporter(src)
        // frame 5 = 0.5 s = left 40 -> pixels 40..59
        let f5 = bitmap(try await ex.still(frame: 5))
        XCTAssertTrue(f5.px(45, 50).near(red) && f5.px(58, 50).near(red), "frame 5 \(f5.px(45, 50))")
        XCTAssertTrue(f5.px(36, 50).near(bgGreen) && f5.px(62, 50).near(bgGreen))
        let f2 = bitmap(try await ex.still(frame: 2))     // 0.2 s = left 16
        XCTAssertTrue(f2.px(20, 50).near(red) && f2.px(60, 50).near(bgGreen), "frame 2")
        XCTAssertNotEqual(f2.data, f5.data)
        let f0 = bitmap(try await ex.still(frame: 0))
        XCTAssertTrue(f0.px(5, 50).near(red) && f0.px(30, 50).near(bgGreen), "frame 0")
        // The same frame twice is identical, also from an exporter with an empty cache (renders again from scratch).
        let f5again = bitmap(try await ex.still(frame: 5))
        XCTAssertEqual(f5.data, f5again.data)
        let fresh = SprocketExporter(script: try SprocketScript(source: src), assets: [:], webCacheDirectory: cacheDir.appendingPathComponent("w2"))
        let f5fresh = bitmap(try await fresh.still(frame: 5))
        XCTAssertGreaterThan(fresh.webFramesRendered, 0)
        XCTAssertEqual(f5.data, f5fresh.data)
    }

    func testPageTimeOverridesFrameTime() async throws {
        // time: 0.5 on frame 0 shows the page as it looks at 0.5 s.
        let b = try await still(composition(120, 100, body: "return html(`\(Self.slide)`, { time: 0.5 });"), frame: 0)
        XCTAssertTrue(b.px(45, 50).near(red) && b.px(10, 50).near(RGBA(r: 0, g: 0, b: 0, a: 255)), "\(b.px(45, 50))")
    }

    func testCustomPropertyTAndFrame() async throws {
        // width = --t seconds * 100px, height = --frame * 10px, at fps 10 frame 3 -> t = 0.3: 30 x 30.
        let src = composition(100, 100, fps: 10, body: """
          return html("<div style='position:absolute;left:0;top:0;background:#f00;width:calc(var(--t) * 100px);height:calc(var(--frame) * 10px)'></div>");
        """)
        let b = try await still(src, frame: 3)
        XCTAssertTrue(b.px(28, 28).near(red), "\(b.px(28, 28))")
        XCTAssertTrue(b.px(33, 10).near(RGBA(r: 0, g: 0, b: 0, a: 255)) && b.px(10, 33).near(RGBA(r: 0, g: 0, b: 0, a: 255)))
    }

    func testMotionFrameDrawsCanvas() async throws {
        let page = """
        <canvas id='c' width='100' height='100' style='display:block'></canvas>
        <script>const g = document.getElementById('c').getContext('2d');
        window.sprocketFrame = (t, frame) => { g.clearRect(0,0,100,100); g.fillStyle = '#f00'; g.fillRect(Math.round(t * 100), 40, 20, 20); };</script>
        """
        let src = composition(150, 100, fps: 10, bg: "#00ff00", body: "return html(`\(page)`);")
        let (ex, _) = try exporter(src)
        let f3 = bitmap(try await ex.still(frame: 3))                  // t = 0.3 -> x = 30..49
        XCTAssertTrue(f3.px(40, 50).near(red) && f3.px(25, 50).near(bgGreen) && f3.px(55, 50).near(bgGreen), "\(f3.px(40, 50))")
        let f6 = bitmap(try await ex.still(frame: 6))
        XCTAssertTrue(f6.px(70, 50).near(red) && f6.px(40, 50).near(bgGreen))
    }

    func testAsyncMotionFrameIsAwaited() async throws {
        let page = """
        <div id='d' style='position:absolute;left:0;top:0;width:40px;height:40px;background:#00f'></div>
        <script>window.sprocketFrame = async (t) => { await new Promise(r => Promise.resolve().then(r)); document.getElementById('d').style.background = '#f00'; };</script>
        """
        let b = try await still(composition(60, 60, body: "return html(`\(page)`);"))
        XCTAssertTrue(b.px(10, 10).near(red), "\(b.px(10, 10))")
    }

    func testVirtualClockAndSeededRandom() async throws {
        // Date.now() is t*1000, performance.now() too, setTimeout fires by virtual time, rAF runs inside the step.
        let page = """
        <canvas id='c' width='200' height='40' style='display:block'></canvas>
        <script>const g = document.getElementById('c').getContext('2d'); let timeout = false, raf = false;
        setTimeout(() => { timeout = true; }, 100);
        window.sprocketFrame = (t) => { requestAnimationFrame(() => { raf = true; });
          g.clearRect(0,0,200,40); g.fillStyle = '#f00'; g.fillRect(0, 0, Date.now() / 10, 10);        // 100 px wide at t = 1 s
          g.fillStyle = '#0f0'; g.fillRect(0, 10, performance.now() / 10, 10);
          g.fillStyle = timeout ? '#00f' : '#888'; g.fillRect(0, 20, 20, 10);
          g.fillStyle = raf ? '#ff0' : '#444'; g.fillRect(30, 20, 20, 10);
          g.fillStyle = '#fff'; g.fillRect(Math.floor(Math.random() * 150), 30, 10, 10); };</script>
        """
        let src = composition(200, 40, fps: 10, body: "return html(`\(page)`);")
        let (ex, _) = try exporter(src)
        let b = bitmap(try await ex.still(frame: 5))         // t = 0.5 s -> 50 px
        XCTAssertTrue(b.px(45, 5).near(red) && b.px(55, 5).alpha0orBlack)
        XCTAssertTrue(b.px(45, 15).near(RGBA(r: 0, g: 255, b: 0, a: 255)) && b.px(55, 15).alpha0orBlack)
        XCTAssertTrue(b.px(10, 25).near(RGBA(r: 0, g: 0, b: 255, a: 255)), "setTimeout(100 ms) has fired by t = 0.5: \(b.px(10, 25))")
        // rAF registered during a step runs in the next step, so the first step cannot show it yet:
        XCTAssertTrue(b.px(40, 25).near(RGBA(r: 68, g: 68, b: 68, a: 255)), "\(b.px(40, 25))")
        // Math.random is seeded: a second exporter draws the same square at the same place.
        let again = try await still(src, frame: 5)
        XCTAssertEqual(b.data, again.data)
    }

    // MARK: sandbox

    /// Counts connections to a local TCP port and answers with a 1x1 red PNG.
    final class Honeypot: @unchecked Sendable {
        let listener: NWListener
        let lock = NSLock()
        private var _hits = 0
        var hits: Int { lock.withLock { _hits } }
        var port: UInt16 { listener.port!.rawValue }
        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] c in
                self?.lock.withLock { self!._hits += 1 }
                c.start(queue: .global())
                c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nAccess-Control-Allow-Origin: *\r\n\r\n".utf8), completion: .contentProcessed { _ in c.cancel() })
            }
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.start(queue: .global())
            _ = ready.wait(timeout: .now() + 5)
        }
    }

    func testNetworkAndFilesAreBlocked() async throws {
        let pot = try Honeypot()
        defer { pot.listener.cancel() }
        let base = "http://127.0.0.1:\(pot.port)"
        let page = """
        <style>#a { position:absolute; left:0; top:0; width:30px; height:30px; background:url(\(base)/bg.png) #00f; }</style>
        <div id='a'></div>
        <img id='i' src='\(base)/x.png' style='position:absolute;left:40px;top:0;width:30px;height:30px;background:#00f'>
        <iframe src='\(base)/frame' style='position:absolute;left:0;top:40px;width:30px;height:30px;border:0'></iframe>
        <link rel='stylesheet' href='\(base)/s.css'>
        <script src='\(base)/s.js'></script>
        <div id='r' style='position:absolute;left:40px;top:40px;width:30px;height:30px;background:#888'></div>
        <script>
          window.sprocketFrame = async () => {
            let result = 'blocked';
            try { await fetch('\(base)/fetch'); result = 'LEAK-fetch'; } catch (e) {}
            try { const x = new XMLHttpRequest(); x.open('GET', '\(base)/xhr', false); x.send(); if (x.status) result = 'LEAK-xhr'; } catch (e) {}
            try { await fetch('file:///etc/hosts'); result = 'LEAK-file'; } catch (e) {}
            try { new WebSocket('ws://127.0.0.1:\(pot.port)/ws'); } catch (e) {}
            document.getElementById('r').style.background = result === 'blocked' ? '#0f0' : '#f00';
          };
        </script>
        """
        let src = composition(80, 80, body: "return html(`\(page)`);")
        let b = try await still(src)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(pot.hits, 0, "the page reached the local server")
        XCTAssertTrue(b.px(50, 50).near(RGBA(r: 0, g: 255, b: 0, a: 255)), "fetch / XHR / file reads must fail: \(b.px(50, 50))")
        // A broken <img> keeps its CSS background (it shows the blue box): the image itself was not drawn.
        XCTAssertTrue(b.px(15, 15).near(RGBA(r: 0, g: 0, b: 255, a: 255)), "css url() background must not load: \(b.px(15, 15))")
    }

    func testMotionAssetImagesAreServedAndNothingElseIs() async throws {
        let dir = cacheDir.appendingPathComponent("assets"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // a 4x4 PNG tagged sRGB (200, 100, 50), plus a text file posing as an asset
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [200.0 / 255, 100.0 / 255, 50.0 / 255, 1])!); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let png = dir.appendingPathComponent("red.png")
        let dest = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); CGImageDestinationFinalize(dest)
        let pic = RGBA(r: 200, g: 100, b: 50, a: 255)
        let secret = dir.appendingPathComponent("secret.txt"); try "top secret".write(to: secret, atomically: true, encoding: .utf8)
        let page = """
        <img src='sprocket-asset://pic' style='position:absolute;left:0;top:0;width:30px;height:30px;image-rendering:pixelated'>
        <div style="position:absolute;left:40px;top:0;width:30px;height:30px;background:url(sprocket-asset://pic) center/cover"></div>
        <div id='t' style='position:absolute;left:0;top:40px;width:30px;height:30px;background:#888'></div>
        <div id='u' style='position:absolute;left:40px;top:40px;width:30px;height:30px;background:#888'></div>
        <script>
          window.sprocketFrame = async () => {
            const ok = async (u) => { try { const r = await fetch(u); return r.ok; } catch (e) { return false; } };
            document.getElementById('t').style.background = (await ok('sprocket-asset://secret')) ? '#f0f' : '#0f0';   // text file: must 404
            document.getElementById('u').style.background = (await ok('sprocket-asset://nope')) ? '#f0f' : '#0f0';     // unknown id: 404
          };
        </script>
        """
        let src = composition(80, 80, body: "return html(`\(page)`);")
        let b = try await still(src, assets: ["pic": png, "secret": secret])
        XCTAssertTrue(b.px(15, 15).near(pic, 2), "<img src=sprocket-asset://pic>: \(b.px(15, 15))")
        XCTAssertTrue(b.px(55, 15).near(pic, 2), "css url(sprocket-asset://pic): \(b.px(55, 15))")
        XCTAssertTrue(b.px(15, 55).near(RGBA(r: 0, g: 255, b: 0, a: 255)), "a non-image asset must 404: \(b.px(15, 55))")
        XCTAssertTrue(b.px(55, 55).near(RGBA(r: 0, g: 255, b: 0, a: 255)), "an unknown id must 404: \(b.px(55, 55))")
    }

    // MARK: errors and limits

    func assertScriptError(_ source: String, contains: [String], file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let (ex, _) = try exporter(source)
            _ = try await ex.still(frame: 0)
            XCTFail("expected an error", file: file, line: line)
        } catch let e as SprocketError {
            XCTAssertEqual(e.kind, .script, e.message, file: file, line: line)
            XCTAssertTrue(e.message.hasPrefix("html:") || e.message.contains("html"), e.message, file: file, line: line)
            for c in contains { XCTAssertTrue(e.message.contains(c), "\(c) missing from: \(e.message)", file: file, line: line) }
        } catch { XCTFail("\(error)", file: file, line: line) }
    }

    func testPageErrorDuringLoadThrowsScriptError() async {
        await assertScriptError(composition(60, 60, body: "return html('<script>throw new Error(\"kaboom\")</script>');"), contains: ["kaboom", "loading"])
        await assertScriptError(composition(60, 60, body: "return html('<script>var x = ;</script>');"), contains: ["loading"])
    }

    func testPageErrorDuringStepThrowsScriptError() async {
        await assertScriptError(composition(60, 60, body: "return html('<script>window.sprocketFrame = () => { null.boom(); };</script>');"), contains: ["sprocketFrame", "t = 0.000"])
        await assertScriptError(composition(60, 60, body: "return html('<script>window.sprocketFrame = async () => { throw new Error(\"late\"); };</script>');"), contains: ["late"])
        await assertScriptError(composition(60, 60, body: "return html('<script>Promise.reject(new Error(\"nobody catches me\"))</script>');"), contains: ["nobody catches me"])
    }

    func testLimitsAreErrors() async {
        await assertScriptError(composition(60, 60, body: "return html('<p>' + 'x'.repeat(210 * 1024) + '</p>');"), contains: ["200 KB"])
        await assertScriptError(composition(60, 60, body: "return html('<p>hi</p>', { width: 5000, height: 100 });"), contains: ["4096"])
    }

    func testRunawayStepTimesOut() async {
        let started = Date()
        await assertScriptError(composition(60, 60, body: "return html('<script>window.sprocketFrame = () => new Promise(() => {});</script>');"), contains: ["took longer than 1 s"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    func testConsoleLogGoesToTheScriptLogs() async throws {
        let (ex, script) = try exporter(composition(60, 60, body: "return html('<script>console.log(\"hello\", {a: 1}); window.sprocketFrame = (t) => console.warn(\"t=\" + t);</script>');"))
        _ = try await ex.still(frame: 3)
        XCTAssertTrue(script.logs.contains("html: hello {\"a\":1}"), "\(script.logs)")
        XCTAssertTrue(script.logs.contains { $0.hasPrefix("html: t=0.3") }, "\(script.logs)")
    }

    // MARK: composition

    func testHTMLUnderMaskAndOpacity() async throws {
        // A red page, half transparent, masked to the left half: left = 50% red over black, right = black.
        let src = composition(100, 100, body: """
          return html("<div style='width:100px;height:100px;background:#f00'></div>", { opacity: 0.5, mask: rect(0, 0, 50, 100, { color: '#fff' }) });
        """)
        let b = try await still(src)
        XCTAssertTrue(b.px(25, 50).near(RGBA(r: 128, g: 0, b: 0, a: 255), 3), "\(b.px(25, 50))")
        XCTAssertTrue(b.px(75, 50).near(RGBA(r: 0, g: 0, b: 0, a: 255)), "\(b.px(75, 50))")
    }

    func testHTMLUnderTransformClipAndBlend() async throws {
        // multiply: red page over mid grey -> (128, 0, 0)
        let m = try await still(composition(100, 100, bg: "#808080", body: """
          return html("<div style='width:100px;height:100px;background:#f00'></div>", { blend: "multiply" });
        """))
        XCTAssertTrue(m.px(30, 30).near(RGBA(r: 128, g: 0, b: 0, a: 255), 2), "\(m.px(30, 30))")
        let src2 = composition(100, 100, bg: "#000000", body: """
          return html("<div style='width:100px;height:100px;background:#f00'></div>", { clip: { x: 10, y: 10, width: 40, height: 40 }, transform: { translateX: 20, originX: 0, originY: 0 } });
        """)
        let c = try await still(src2)
        XCTAssertTrue(c.px(40, 30).near(red), "inside clip: \(c.px(40, 30))")
        XCTAssertTrue(c.px(5, 30).near(RGBA(r: 0, g: 0, b: 0, a: 255)) && c.px(60, 30).near(RGBA(r: 0, g: 0, b: 0, a: 255)) && c.px(40, 5).near(RGBA(r: 0, g: 0, b: 0, a: 255)))
    }

    func testHTMLOverVideoLikeBackgroundKeepsOtherLayers() async throws {
        let b = try await still(composition(100, 100, body: """
          return [rect(0, 0, 100, 100, { color: '#00f' }), html("<div style='position:absolute;left:50px;top:0;width:50px;height:100px;background:#f00'></div>")];
        """))
        XCTAssertTrue(b.px(25, 50).near(RGBA(r: 0, g: 0, b: 255, a: 255)) && b.px(75, 50).near(red))
    }

    // MARK: cache

    func testCacheReuseAcrossExports() async throws {
        let src = composition(100, 100, fps: 10, frames: 6, body: "return html(`\(Self.slide)`, { height: 100 });")
        let out1 = cacheDir.appendingPathComponent("a.mp4"), out2 = cacheDir.appendingPathComponent("b.mp4")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let (a, _) = try exporter(src)
        try await a.export(to: out1)
        XCTAssertEqual(a.webFramesRendered, 6)
        XCTAssertEqual(a.webPageLoads, 1, "one page load serves every frame")
        let (b, _) = try exporter(src)
        try await b.export(to: out2)
        XCTAssertEqual(b.webFramesRendered, 0, "a second export must not render again")
        XCTAssertEqual(b.webPageLoads, 0)
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: out2.path)[.size] as! NSNumber).intValue, 1000)
    }

    func testStaticPageIsRenderedOnce() async throws {
        let src = composition(100, 100, fps: 10, frames: 8, body: "return html(\"<div style='width:50px;height:50px;background:#f00'></div>\");")
        let (a, _) = try exporter(src)
        try await a.export(to: cacheDir.appendingPathComponent("s.mp4"))
        XCTAssertEqual(a.webFramesRendered, 1)
        XCTAssertEqual(a.webPageLoads, 1)
        let (b, _) = try exporter(src)
        _ = try await b.still(frame: 4)
        XCTAssertEqual(b.webPageLoads, 0, "the static marker file is found")
    }

    func testAnimatedPageRendersEveryDistinctTimeOnce() async throws {
        // Two layers with the same markup and size at the same time share one picture.
        let src = composition(100, 100, fps: 10, frames: 5, body: """
          return [html(`\(Self.slide)`, { height: 100 }), html(`\(Self.slide)`, { height: 100, opacity: 0.5 })];
        """)
        let (a, _) = try exporter(src)
        try await a.export(to: cacheDir.appendingPathComponent("d.mp4"))
        XCTAssertEqual(a.webFramesRendered, 5)
    }

    func testProgressIsReportedAsWeb() async throws {
        final class Box: @unchecked Sendable { var seen: [MatteProgress] = []; let l = NSLock() }
        let box = Box()
        let (ex, _) = try exporter(composition(100, 100, fps: 10, frames: 4, body: "return html(`\(Self.slide)`, { height: 100 });"))
        ex.prepareHandler = { p in box.l.withLock { box.seen.append(p) } }
        try await ex.export(to: cacheDir.appendingPathComponent("p.mp4"))
        let seen = box.l.withLock { box.seen }
        XCTAssertEqual(seen.map(\.kind).filter { $0 == "web" }.count, 4)
        XCTAssertEqual(seen.last?.frame, 4); XCTAssertEqual(seen.last?.total, 4)
        XCTAssertTrue(seen.first?.src.hasPrefix("html:") == true)
    }

    // MARK: validation and tree helpers

    func testValidationMessages() throws {
        func err(_ body: String) -> String {
            do { _ = try SprocketScript(source: composition(100, 100, body: "return \(body);")).node(frame: 0); return "no error" }
            catch let e as SprocketError { return e.message } catch { return "\(error)" }
        }
        XCTAssertTrue(err("html(5)").contains("html(): the first argument must be a string"), err("html(5)"))
        XCTAssertTrue(err("{ type: 'html' }").contains("html is missing \"html\""), err("{ type: 'html' }"))
        XCTAssertTrue(err("{ type: 'html', html: 5 }").contains("html.html must be a string, got number"), err("{ type: 'html', html: 5 }"))
        XCTAssertTrue(err("html('<p>', { width: 'wide' })").contains("html.width must be a number, got string"))
        XCTAssertTrue(err("{ type: 'bogus' }").contains("valid types: group, solid, rect, ellipse, path, gradient, image, video, text, html"))
        XCTAssertEqual(err("html('<p>hi</p>')"), "no error")
    }

    func testResolvingFillsTheDefaults() throws {
        let n = node("{\"type\":\"group\",\"children\":[{\"type\":\"html\",\"html\":\"<p>\"},{\"type\":\"html\",\"html\":\"<b>\",\"x\":5,\"width\":10,\"height\":20,\"time\":2}]}")
        let r = n.resolvingWeb(frame: 15, fps: 30, canvasWidth: 1080, canvasHeight: 1920)
        let a = r.children![0], b = r.children![1]
        XCTAssertEqual([a.x, a.y, a.width, a.height, a.time], [0, 0, 1080, 1920, 0.5])
        XCTAssertEqual([b.x, b.y, b.width, b.height, b.time], [5, 0, 10, 20, 2])
        XCTAssertEqual(try r.webRequests().count, 2)
    }
}

extension RGBA {
    /// Black (or fully transparent): what is left when nothing was drawn there.
    var alpha0orBlack: Bool { (r + g + b) <= 6 }
}
