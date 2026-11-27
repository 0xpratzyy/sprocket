import XCTest
import CoreImage
@testable import Sprocket

/// Items 3, 4, 5: validation messages, line numbers and the non-finite rule, at the script and renderer level.
final class ValidationTests: XCTestCase {
    static let header = "composition({ width: 100, height: 100, fps: 30, durationInFrames: 60 }, function (frame, ctx) {\n"

    func script(_ body: String) throws -> SprocketScript {
        try SprocketScript(source: Self.header + "  return " + body + ";\n});")
    }

    /// The error thrown by frame 0 of a script returning `body`.
    func frameError(_ body: String, file: StaticString = #filePath, line: UInt = #line) -> SprocketError {
        do {
            let s = try script(body)
            _ = try s.node(frame: 0)
            XCTFail("expected an error for \(body)", file: file, line: line)
        } catch let e as SprocketError { return e } catch { XCTFail("\(error)", file: file, line: line) }
        return SprocketError(.script, "")
    }

    func configError(_ cfg: String, file: StaticString = #filePath, line: UInt = #line) -> SprocketError {
        do {
            _ = try SprocketScript(source: "composition(\(cfg), function () { return null; });")
            XCTFail("expected a config error for \(cfg)", file: file, line: line)
        } catch let e as SprocketError { return e } catch { XCTFail("\(error)", file: file, line: line) }
        return SprocketError(.script, "")
    }

    // MARK: node tree messages (item 3)

    func testWrongPropTypeNamesNodeAndPath() {
        let e = frameError("[solid('#000'), rect(0, 0, 1, 1), group([rect(0, 0, 1, 1), rect(0, 0, 1, 1), rect(0, 0, 1, 1, { color: 5 })])]")
        XCTAssertEqual(e.kind, .script)
        XCTAssertEqual(e.message, "frame 0: rect.color must be a string, got number (at root > group[2] > rect[2])")
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { opacity: 'half' })").message.contains("rect.opacity must be a number, got string"))
        XCTAssertTrue(frameError("rect('a', 0, 1, 1)").message.contains("rect.x must be a number, got string"))
        XCTAssertTrue(frameError("text('x', { size: {} })").message.contains("text.size must be a number, got object"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { transform: { scale: '2' } })").message.contains("transform.scale must be a number, got string"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { transform: 5 })").message.contains("transform must be an object, got number"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { blend: 5 })").message.contains("rect.blend must be a string, got number"))
        XCTAssertTrue(frameError("text('x', { shadow: { blur: 'a' } })").message.contains("shadow.blur must be a number, got string"))
    }

    func testStructuredPropMessages() {
        XCTAssertTrue(frameError("gradient([{ at: 0, color: '#f00' }, { color: '#00f' }])").message
            .contains("gradient stops[1] is missing \"at\""))
        XCTAssertTrue(frameError("gradient([{ at: 0 }])").message.contains("gradient stops[0] is missing \"color\""))
        XCTAssertTrue(frameError("gradient([{ at: 'a', color: '#f00' }])").message.contains("gradient stops[0].at must be a number, got string"))
        XCTAssertTrue(frameError("gradient([])").message.contains("gradient stops is empty"))
        XCTAssertTrue(frameError("gradient('red')").message.contains("gradient stops must be an array"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { clip: { x: 0, y: 0, width: 5 } })").message.contains("clip is missing \"height\""))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { clip: { x: 0, y: 0, width: 5, height: 'a' } })").message.contains("clip.height must be a number, got string"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { effects: 'blur' })").message.contains("effects must be an array"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { effects: [{ radius: 4 }] })").message.contains("effects[0] is missing \"name\""))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { effects: [{ name: 'blur', radius: 'big' }] })").message.contains("effects[0].radius must be a number, got string"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { mask: 'x' })").message.contains("mask must be a node or array of nodes, got string"))
        XCTAssertTrue(frameError("group('notarray')").message.contains("group.children must be a node or an array of nodes, got string"))
        XCTAssertTrue(frameError("gradient([{ at: 0, color: '#f00' }], { from: { x: 1 } })").message.contains("from is missing \"y\""))
    }

    func testUnknownNodeTypeListsValidTypes() {
        let e = frameError("{ type: 'bogus' }")
        XCTAssertTrue(e.message.contains("unknown node type \"bogus\""), e.message)
        for t in ["group", "solid", "rect", "ellipse", "path", "gradient", "image", "video", "text", "html"] {
            XCTAssertTrue(e.message.contains(t), "\(t) missing from: \(e.message)")
        }
        XCTAssertTrue(e.message.contains("(at root > bogus)"), e.message)
        XCTAssertTrue(frameError("[solid('#000'), {}]").message.contains("has no string \"type\""))
        XCTAssertTrue(frameError("[solid('#000'), 7]").message.contains("not a node: 7"))
    }

    func testRequiredProps() {
        XCTAssertTrue(frameError("video()").message.contains("video is missing \"src\""))
        XCTAssertTrue(frameError("image(undefined)").message.contains("image is missing \"src\""))
        XCTAssertTrue(frameError("path()").message.contains("path is missing \"d\""))
        XCTAssertTrue(frameError("solid()").message.contains("solid is missing \"color\""))
    }

    func testTextNullIsAnErrorWithLine() {
        for bad in ["null", "undefined", "{}", "[1]"] {
            let e = frameError("text(\(bad))")
            XCTAssertTrue(e.message.contains("text(): the first argument must be a string"), e.message)
            XCTAssertEqual(e.line, 2, "text(\(bad)): \(e.message)")
        }
        // numbers and the empty string are fine
        XCTAssertEqual(try script("text(12345)").node(frame: 0).text, "12345")
        XCTAssertEqual(try script("text('')").node(frame: 0).text, "")
    }

    func testNullAndUndefinedPropsAreUnset() throws {
        let n = try script("rect(0, 0, 5, 5, { color: null, stroke: undefined, mask: null, effects: null, transform: undefined, clip: null })").node(frame: 0)
        XCTAssertNil(n.color); XCTAssertNil(n.mask); XCTAssertNil(n.effects); XCTAssertNil(n.transform); XCTAssertNil(n.clip)
        XCTAssertEqual(try script("rect(0, 0, 5, 5, { mask: [] })").node(frame: 0).mask?.count, 0)
    }

    func testValidTreeStillRoundTrips() throws {
        let src = "[solid('#000'), gradient([{ at: 0, color: '#f00' }, { at: 1, color: '#00f' }], { from: { x: 0, y: 0 }, to: { x: 0, y: 100 } }), " +
            "group([rect(1, 2, 3, 4, { color: '#fff', radius: 2, stroke: '#000', strokeWidth: 2 })], { opacity: 0.5, blend: 'screen', transform: { translateX: 3, rotate: 10 }, " +
            "clip: { x: 0, y: 0, width: 50, height: 50, radius: 4 }, effects: [{ name: 'blur', radius: 3 }, { name: 'tint', color: '#f00', amount: 0.5 }] }), " +
            "text('hi', { size: 20, shadow: { color: '#000', blur: 4, x: 1, y: 1 } }), path('M 0 0 L 5 5', { stroke: '#fff' }), image('a'), video('b', { time: 1 })]"
        let n = try script(src).node(frame: 0)
        XCTAssertEqual(n.children?.map(\.type), ["solid", "gradient", "group", "text", "path", "image", "video"])
        XCTAssertEqual(n.children?[1].stops?.count, 2)
        XCTAssertEqual(n.children?[2].clip?.radius, 4)
        XCTAssertEqual(n.children?[2].effects?.count, 2)
        XCTAssertEqual(n.children?[3].shadow?.blur, 4)
    }

    // MARK: config messages (item 3)

    func testConfigMessagesNameFieldAndRule() {
        func cfg(w: String = "100", h: String = "100", fps: String = "30", d: String = "10") -> String {
            "{ width: \(w), height: \(h), fps: \(fps), durationInFrames: \(d) }"
        }
        let frac = configError(cfg(w: "540.5"))
        XCTAssertTrue(frac.message.contains("width must be an integer, got 540.5"), frac.message)
        XCTAssertTrue(frac.message.contains("even integer 16...4096"), frac.message)
        XCTAssertEqual(frac.line, 1)
        XCTAssertTrue(configError(cfg(fps: "29.97")).message.contains("fps must be an integer, got 29.97"))
        XCTAssertTrue(configError(cfg(d: "10.5")).message.contains("durationInFrames must be an integer, got 10.5"))
        XCTAssertTrue(configError(cfg(h: "'100'")).message.contains("height must be a number, got string \"100\""))
        XCTAssertTrue(configError(cfg(w: "NaN")).message.contains("width must be an integer, got NaN"))
        XCTAssertTrue(configError(cfg(w: "541")).message.contains("width must be an even number, got 541"))
        XCTAssertTrue(configError(cfg(h: "961")).message.contains("height must be an even number, got 961"))
        XCTAssertTrue(configError(cfg(w: "14")).message.contains("width must be in 16...4096, got 14"))
        XCTAssertTrue(configError(cfg(w: "4098")).message.contains("width must be in 16...4096"))
        XCTAssertTrue(configError(cfg(fps: "0")).message.contains("fps must be in 1...120, got 0"))
        XCTAssertTrue(configError(cfg(fps: "121")).message.contains("fps must be in 1...120"))
        XCTAssertTrue(configError(cfg(d: "0")).message.contains("durationInFrames must be in 1...36000, got 0"))
        XCTAssertTrue(configError(cfg(d: "36001")).message.contains("durationInFrames must be in 1...36000"))
        XCTAssertTrue(configError("{ width: 100, fps: 30, durationInFrames: 10 }").message.contains("height is required"))
        XCTAssertTrue(configError("{ width: 100, height: 100, fps: 30, durationInFrames: 10, background: 5 }").message.contains("background must be a string"))
        XCTAssertNoThrow(try SprocketScript(source: "composition(\(cfg(w: "16", h: "4096", fps: "120", d: "36000")), function () { return null; });"))
    }

    func testAudioConfigMessages() {
        func audio(_ a: String) -> SprocketError {
            configError("{ width: 100, height: 100, fps: 30, durationInFrames: 10, audio: \(a) }")
        }
        XCTAssertTrue(audio("'music'").message.contains("audio must be an array"))
        XCTAssertTrue(audio("[{ volume: 1 }]").message.contains("audio[0] is missing \"src\""))
        XCTAssertTrue(audio("[{ src: 5 }]").message.contains("audio[0].src must be a string"))
        XCTAssertTrue(audio("[{ src: 'm' }, { src: 'm', startFrame: 1.5 }]").message.contains("audio[1].startFrame must be an integer"))
        XCTAssertTrue(audio("[{ src: 'm', volume: 'loud' }]").message.contains("audio[0].volume must be a finite number"))
        XCTAssertTrue(audio("[{ src: 'm', durationInFrames: -3 }]").message.contains("audio[0].durationInFrames must not be negative"))
    }

    // MARK: line numbers and timeouts (item 4)

    func testThrownStringExplainsMissingLine() throws {
        let s = try SprocketScript(source: "composition({ width: 100, height: 100, fps: 30, durationInFrames: 10 }, function (frame) {\n  if (frame === 5) throw 'just a string';\n  return null;\n});")
        XCTAssertNoThrow(try s.node(frame: 4))
        XCTAssertThrowsError(try s.node(frame: 5)) { e in
            let m = e as? SprocketError
            XCTAssertEqual(m?.kind, .script)
            XCTAssertNil(m?.line, "no line is available for a thrown string, so none is invented")
            XCTAssertTrue(m?.message.contains("frame 5: the script threw a string, not an Error: \"just a string\"") == true, m?.message ?? "")
            XCTAssertTrue(m?.message.contains("new Error") == true)
        }
        XCTAssertThrowsError(try SprocketScript(source: "\n\nthrow 'load string';")) { e in
            XCTAssertTrue((e as? SprocketError)?.message.contains("threw a string") == true)
        }
        // an Error object still reports its line
        let t = try SprocketScript(source: "composition({ width: 100, height: 100, fps: 30, durationInFrames: 10 }, function (frame) {\n\n  throw new Error('with line');\n});")
        XCTAssertThrowsError(try t.node(frame: 0)) { XCTAssertEqual(($0 as? SprocketError)?.line, 3) }
    }

    func testTimeoutMessagesNamePhaseFrameAndLimit() throws {
        XCTAssertThrowsError(try SprocketScript(source: "while (true) {}")) { e in
            let m = e as! SprocketError
            XCTAssertEqual(m.kind, .timeout)
            XCTAssertTrue(m.message.contains("while loading the script"), m.message)
            XCTAssertTrue(m.message.contains("2 s load limit"), m.message)
            XCTAssertNil(m.line)
        }
        let s = try SprocketScript(source: "composition({ width: 100, height: 100, fps: 30, durationInFrames: 10 }, function (frame) {\n  if (frame === 3) { for (;;) {} }\n  return null;\n});")
        XCTAssertThrowsError(try s.node(frame: 3)) { e in
            let m = e as! SprocketError
            XCTAssertEqual(m.kind, .timeout)
            XCTAssertTrue(m.message.contains("while rendering frame 3"), m.message)
            XCTAssertTrue(m.message.contains("250 ms"), m.message)
            XCTAssertNil(m.line)
        }
    }

    // MARK: non-finite and out-of-range values (item 5)

    func testNonFiniteGeometryHidesTheNode() throws {
        for geom in ["rect(10, 10, NaN, 50, { color: '#fff' })", "rect(10, 10, Infinity, 50)", "rect(NaN, 10, 5, 5)", "ellipse(0, -Infinity, 5, 5)",
                     "text('x', { size: NaN })", "rect(0, 0, 5, 5, { radius: NaN })", "rect(0, 0, 5, 5, { strokeWidth: Infinity })",
                     "rect(0, 0, 5, 5, { transform: { scale: NaN } })", "rect(0, 0, 5, 5, { transform: { rotate: Infinity } })",
                     "rect(0, 0, 5, 5, { clip: { x: 0, y: 0, width: NaN, height: 5 } })",
                     "gradient([{ at: 0, color: '#f00' }], { from: { x: NaN, y: 0 } })"] {
            let n = try script("[\(geom)]").node(frame: 0)
            XCTAssertEqual(n.children?.count, 1, geom)
            XCTAssertEqual(n.children?.first?.type, "group", geom)
            XCTAssertEqual(n.children?.first?.children?.count, 0, geom)
        }
        // a hidden mask node still masks (everything disappears), it does not turn the mask off
        let masked = try script("group([solid('#fff')], { mask: [rect(0, 0, NaN, 50)] })").node(frame: 0)
        XCTAssertEqual(masked.mask?.count, 1)
        XCTAssertEqual(masked.mask?.first?.children?.count, 0)
    }

    func testNonGeometryNonFiniteValuesKeepTheirMeaning() throws {
        let n = try XCTUnwrap(script("[rect(1, 2, 10, 20, { opacity: NaN, effects: [{ name: 'colorMatrix', matrix: [1, NaN, Infinity] }, { name: 'blur', radius: NaN }], transform: { scale: 2 } })]").node(frame: 0).children?.first)
        XCTAssertEqual(n.width, 10)
        XCTAssertNil(n.opacity, "opacity NaN counts as 1 (unset)")
        XCTAssertEqual(n.effects?.first?.matrix, [1, 0, 0])
        XCTAssertNil(n.effects?[1].radius)
        XCTAssertEqual(n.transform?.scale, 2)
    }

    func testOpacityIsClampedToUnitRange() throws {
        func opacity(_ expr: String) throws -> Double? { try script("rect(0, 0, 5, 5, { opacity: \(expr) })").node(frame: 0).opacity }
        XCTAssertEqual(try opacity("99"), 1)
        XCTAssertEqual(try opacity("-5"), 0)
        XCTAssertEqual(try opacity("Infinity"), 1)
        XCTAssertEqual(try opacity("-Infinity"), 0)
        XCTAssertEqual(try opacity("0.25"), 0.25)
        XCTAssertNil(try opacity("NaN"))
    }

    func testVideoTimeNonFinite() throws {
        func time(_ expr: String) throws -> Double? { try script("video('v', { time: \(expr) })").node(frame: 0).time }
        XCTAssertEqual(try time("Infinity"), Double.greatestFiniteMagnitude)
        XCTAssertEqual(try time("-Infinity"), 0)
        XCTAssertEqual(try time("NaN"), 0)
        XCTAssertEqual(Node.videoTime(nil), 0)
        XCTAssertEqual(Node.videoTime(.nan), 0)
        XCTAssertEqual(Node.videoTime(-3), 0)
        XCTAssertEqual(Node.videoTime(-.infinity), 0)
        XCTAssertEqual(Node.videoTime(.infinity), Double.greatestFiniteMagnitude)
        XCTAssertEqual(Node.videoTime(2.5), 2.5)
        var n = Node(type: "video"); n.src = "v"; n.time = .infinity
        XCTAssertEqual(n.videoRequests.first?.time, Double.greatestFiniteMagnitude)
    }

    // MARK: renderer (items 5)

    private func render(_ n: Node, w: Int = 100, h: Int = 100, bg: String? = "#000000") -> Bitmap {
        let cfg = CompositionConfig(width: w, height: h, fps: 30, durationInFrames: 1, audio: nil, background: bg)
        return rasterize(SprocketRenderer().render(n, config: cfg, resources: TestResources()))
    }

    private func rect(_ x: Double, _ y: Double, _ w: Double?, _ h: Double?) -> Node {
        var n = Node(type: "rect"); n.x = x; n.y = y; n.width = w; n.height = h; n.color = "#ffffff"; return n
    }

    func testRendererDrawsNothingForNonFiniteGeometry() {
        for (w, h) in [(Double.nan, 50.0), (.infinity, 50), (50, .infinity), (-.infinity, 50), (-100, -100)] as [(Double, Double)] {
            let bm = render(rect(10, 10, w, h))
            XCTAssertTrue(bm.px(50, 30).near(RGBA(r: 0, g: 0, b: 0, a: 255)), "rect \(w)x\(h) must draw nothing, got \(bm.px(50, 30))")
        }
        XCTAssertTrue(render(rect(10, 10, 50, 50)).px(30, 30).near(RGBA(r: 255, g: 255, b: 255, a: 255)))
        var nanX = rect(10, 10, 50, 50); nanX.x = .nan
        XCTAssertTrue(render(nanX).px(30, 30).near(RGBA(r: 0, g: 0, b: 0, a: 255)))
        var group = Node(type: "group"); group.children = [rect(0, 0, 100, 100)]
        var t = Node.Transform(); t.scale = .nan; group.transform = t
        XCTAssertTrue(render(group).px(50, 50).near(RGBA(r: 0, g: 0, b: 0, a: 255)), "NaN transform draws nothing")
        var img = Node(type: "image"); img.src = "x"; img.width = .infinity
        XCTAssertTrue(render(img).px(50, 50).near(RGBA(r: 0, g: 0, b: 0, a: 255)))
    }

    func testRendererClampsOpacity() {
        var full = rect(0, 0, 100, 100)
        full.opacity = 1
        var over = full; over.opacity = 99
        var under = full; under.opacity = -5
        var nan = full; nan.opacity = .nan
        var inf = full; inf.opacity = .infinity
        XCTAssertEqual(render(over).data, render(full).data)
        XCTAssertEqual(render(nan).data, render(full).data)
        XCTAssertEqual(render(inf).data, render(full).data)
        XCTAssertTrue(render(under).px(50, 50).near(RGBA(r: 0, g: 0, b: 0, a: 255)))
        var wrap = Node(type: "group"); var inner = full; inner.opacity = 5
        wrap.children = [inner]; wrap.opacity = 0.5
        XCTAssertTrue(render(wrap).px(50, 50).near(RGBA(r: 128, g: 128, b: 128, a: 255), 3), "\(render(wrap).px(50, 50))")
    }

    func testStrokeWidthIsClampedToTheCanvasDiagonal() {
        func line(_ width: Double) -> Node {
            var n = Node(type: "path"); n.d = "M 10 50 L 90 50"; n.stroke = "#ffffff"; n.strokeWidth = width; return n
        }
        let diagonal = (100.0 * 100.0 + 100.0 * 100.0).squareRoot()
        XCTAssertEqual(render(line(1e9)).data, render(line(diagonal)).data)
        XCTAssertEqual(render(line(.greatestFiniteMagnitude)).data, render(line(diagonal)).data)
        // below the clamp nothing changes
        XCTAssertTrue(render(line(4)).px(50, 0).near(RGBA(r: 0, g: 0, b: 0, a: 255)))
        var text = Node(type: "text"); text.text = "A"; text.size = 40; text.stroke = "#ff0000"; text.strokeWidth = 1e9
        XCTAssertNoThrow(render(text))
    }

    // MARK: API.md claims (item 8)

    func testSeriesLocalFramesAsDocumented() throws {
        let src = """
        const items = [{ durationInFrames: 10, from: 0 }, { durationInFrames: 10, from: 5 }];
        composition({ width: 100, height: 100, fps: 30, durationInFrames: 20 }, function (frame, ctx) {
          return series(frame, items, 4, function (a, b, progress, ia, ib, local) {
            return text(JSON.stringify({ ia: ia, ib: ib, hasB: b !== null, p: progress, f: local.frame, fb: local.frameB, s: local.start }));
          });
        });
        """
        let s = try SprocketScript(source: src)
        func info(_ f: Int) throws -> [String: Any] {
            let t = try XCTUnwrap(s.node(frame: f).text)
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any])
        }
        let before = try info(5)
        XCTAssertEqual(before["hasB"] as? Bool, false); XCTAssertEqual(before["p"] as? Double, 0); XCTAssertTrue(before["fb"] is NSNull)
        var progress: [Double] = [], frameB: [Int] = []
        for f in 6...9 {
            let i = try info(f)
            XCTAssertEqual(i["hasB"] as? Bool, true); XCTAssertEqual(i["ia"] as? Int, 0); XCTAssertEqual(i["ib"] as? Int, 1)
            progress.append(try XCTUnwrap(i["p"] as? Double)); frameB.append(try XCTUnwrap(i["fb"] as? Int))
        }
        XCTAssertEqual(frameB, [-4, -3, -2, -1], "negative during the lead-in, counting up")
        XCTAssertEqual(progress, [0, 0.25, 0.5, 0.75], "progress never reaches 1")
        let next = try info(10)
        XCTAssertEqual(next["ia"] as? Int, 1); XCTAssertEqual(next["hasB"] as? Bool, false)
        XCTAssertEqual(next["f"] as? Int, 0, "b's own segment starts at its frame 0"); XCTAssertEqual(next["s"] as? Int, 10)
        // the documented incoming-clip time: at b's own frame 0 it is b.from; during the lead-in it is earlier
        let t = try SprocketScript(source: """
        const items = [{ durationInFrames: 30, from: 0 }, { durationInFrames: 30, from: 5 }];
        composition({ width: 100, height: 100, fps: 30, durationInFrames: 60 }, function (frame, ctx) {
          return series(frame, items, 6, function (a, b, progress, ia, ib, local) {
            return b ? video("b", { time: Math.max(0, b.from + local.frameB / ctx.fps), opacity: progress }) : video("a", { time: a.from + local.frame / ctx.fps });
          });
        });
        """)
        XCTAssertEqual(try t.node(frame: 24).time ?? -1, 5 - 6.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(try t.node(frame: 29).time ?? -1, 5 - 1.0 / 30, accuracy: 1e-9)
        XCTAssertEqual(try t.node(frame: 30).time ?? -1, 5, accuracy: 1e-9)
    }

    func testConsoleLogDoesNotAffectTheTree() throws {
        let s = try SprocketScript(source: Self.header + "  console.log('a', frame); console.warn('w'); return null;\n});")
        _ = try s.node(frame: 3)
        XCTAssertEqual(s.logs, ["a 3", "w"])
    }
}
