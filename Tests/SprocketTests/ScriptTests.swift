import XCTest
@testable import Sprocket

final class ScriptTests: XCTestCase {
    static let header = "composition({ width: 100, height: 100, fps: 30, durationInFrames: 60 }, function (frame, ctx) {\n"

    /// A script whose render function returns `body` (a JS expression).
    func script(_ body: String) throws -> SprocketScript {
        try SprocketScript(source: Self.header + "  return " + body + ";\n});")
    }

    /// Evaluates a JS expression and returns it as JSON-decoded Foundation value.
    func value(_ expr: String) throws -> Any {
        let s = try script("text(JSON.stringify(\(expr)))")
        let n = try s.node(frame: 0)
        let data = Data((n.text ?? "null").utf8)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    func number(_ expr: String) throws -> Double { try XCTUnwrap(value(expr) as? Double, expr) }

    func expectError(_ source: String, kind: SprocketError.Kind, line: Int? = nil, file: StaticString = #filePath, lineNo: UInt = #line,
                     frame: Int? = nil) {
        do {
            let s = try SprocketScript(source: source)
            if let frame { _ = try s.node(frame: frame) }
            XCTFail("expected \(kind) error", file: file, line: lineNo)
        } catch let e as SprocketError {
            XCTAssertEqual(e.kind, kind, e.message, file: file, line: lineNo)
            if let line { XCTAssertEqual(e.line, line, e.message, file: file, line: lineNo) }
        } catch { XCTFail("wrong error \(error)", file: file, line: lineNo) }
    }

    // MARK: API.md example

    func testAPIExample() throws {
        let src = """
        composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 90,
                      audio: [{ src: "music", volume: 0.9, fadeOut: 0.3 }] },
          function (frame, ctx) {
            const p = interpolate(frame, [20, 50], [0, 1], { easing: Easing.inOutCubic });
            return [
              video("c1", { time: frame / ctx.fps }),
              video("c2", { time: 2 + frame / ctx.fps, opacity: p }),
              text("LISBON", { y: 1500, size: 120, weight: 800, color: "#fff" }),
            ];
          });
        """
        let s = try SprocketScript(source: src)
        XCTAssertEqual(s.config.width, 1080)
        XCTAssertEqual(s.config.height, 1920)
        XCTAssertEqual(s.config.fps, 30)
        XCTAssertEqual(s.config.durationInFrames, 90)
        XCTAssertEqual(s.config.audio?.first?.src, "music")
        XCTAssertEqual(s.config.audio?.first?.volume, 0.9)
        XCTAssertEqual(s.config.audio?.first?.fadeOut, 0.3)
        let n = try s.node(frame: 45)
        XCTAssertEqual(n.type, "group")
        let kids = try XCTUnwrap(n.children)
        XCTAssertEqual(kids.count, 3)
        XCTAssertEqual(kids[0].type, "video"); XCTAssertEqual(kids[0].src, "c1"); XCTAssertEqual(kids[0].time ?? -1, 1.5, accuracy: 1e-9)
        XCTAssertEqual(kids[1].src, "c2"); XCTAssertEqual(kids[1].time ?? -1, 3.5, accuracy: 1e-9)
        XCTAssertEqual(kids[1].opacity ?? -1, 1 - pow(1.0 / 3.0, 3) / 2, accuracy: 1e-9)
        XCTAssertEqual(kids[2].type, "text"); XCTAssertEqual(kids[2].text, "LISBON")
        XCTAssertEqual(kids[2].y, 1500); XCTAssertEqual(kids[2].size, 120); XCTAssertEqual(kids[2].weight, 800); XCTAssertEqual(kids[2].color, "#fff")
        XCTAssertEqual(try s.node(frame: 0).children?[1].opacity, 0)
    }

    func testConstructors() throws {
        let s = try script("""
        group([solid("red"), rect(1, 2, 3, 4, { radius: 2 }), ellipse(5, 6, 7, 8), path("M0 0L1 1", { stroke: "#000", strokeWidth: 2 }),
               gradient([{ at: 0, color: "#000" }, { at: 1, color: "#fff" }], { kind: "radial", from: { x: 1, y: 2 }, to: { x: 3, y: 4 } }),
               image("pic", { fit: "contain" }), video("v", { time: 1, focusX: 0.2 }), text("hi", { shadow: { color: "#000", blur: 3, x: 1, y: 2 } })],
              { opacity: 0.5, transform: { scale: 2, rotate: 10 }, blend: "screen", clip: { x: 0, y: 0, width: 10, height: 10, radius: 2 },
                effects: [{ name: "blur", radius: 4 }, { name: "colorMatrix", matrix: [1,0,0,0,0, 0,1,0,0,0, 0,0,1,0,0, 0,0,0,1,0] }],
                mask: [rect(0, 0, 5, 5)], maskMode: "luma" })
        """)
        let n = try s.node(frame: 0)
        XCTAssertEqual(n.opacity, 0.5); XCTAssertEqual(n.transform?.scale, 2); XCTAssertEqual(n.blend, "screen")
        XCTAssertEqual(n.clip?.radius, 2); XCTAssertEqual(n.effects?.count, 2); XCTAssertEqual(n.effects?[1].matrix?.count, 20)
        XCTAssertEqual(n.mask?.first?.type, "rect"); XCTAssertEqual(n.maskMode, "luma")
        let k = try XCTUnwrap(n.children)
        XCTAssertEqual(k.map(\.type), ["solid", "rect", "ellipse", "path", "gradient", "image", "video", "text"])
        XCTAssertEqual(k[1].width, 3); XCTAssertEqual(k[2].height, 8); XCTAssertEqual(k[3].d, "M0 0L1 1")
        XCTAssertEqual(k[4].stops?.count, 2); XCTAssertEqual(k[4].to, Node.Point(x: 3, y: 4))
        XCTAssertEqual(k[7].shadow?.blur, 3)
    }

    // MARK: helpers

    func testInterpolate() throws {
        XCTAssertEqual(try number("interpolate(5, [0, 10], [0, 100])"), 50)
        XCTAssertEqual(try number("interpolate(-5, [0, 10], [0, 100])"), 0)
        XCTAssertEqual(try number("interpolate(15, [0, 10], [0, 100])"), 100)
        XCTAssertEqual(try number("interpolate(15, [0, 10], [0, 100], { extrapolateRight: 'extend' })"), 150)
        XCTAssertEqual(try number("interpolate(-5, [0, 10], [0, 100], { extrapolateLeft: 'extend' })"), -50)
        XCTAssertEqual(try number("interpolate(5, [0, 10], [0, 100], { easing: Easing.inQuad })"), 25)
        XCTAssertEqual(try number("interpolate(15, [0, 10, 20], [0, 100, 50])"), 75)
        XCTAssertEqual(try number("interpolate(25, [0, 10, 20], [0, 100, 50])"), 50)
        XCTAssertEqual(try number("interpolate(25, [0, 10, 20], [0, 100, 50], { extrapolateRight: 'extend' })"), 25)
        XCTAssertEqual(try number("interpolate(10, [0, 10, 10, 20], [0, 1, 5, 6])"), 5)
        XCTAssertEqual(try number("interpolate(50, [0, 100], [10, 20])"), 15)
        expectError(Self.header + "return interpolate(1, [0], [1]);\n});", kind: .script, line: 2, frame: 0)
    }

    func testEasing() throws {
        let names = ["linear", "inQuad", "outQuad", "inOutQuad", "inCubic", "outCubic", "inOutCubic", "inQuart", "outQuart", "inOutQuart",
                     "inExpo", "outExpo", "inOutExpo", "inBack", "outBack", "inOutBack", "outElastic", "outBounce"]
        for name in names {
            XCTAssertEqual(try number("Easing.\(name)(0)"), 0, accuracy: 1e-3, name)
            XCTAssertEqual(try number("Easing.\(name)(1)"), 1, accuracy: 1e-9, name)
        }
        XCTAssertEqual(try number("Easing.inOutQuad(0.5)"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try number("Easing.outCubic(0.5)"), 0.875, accuracy: 1e-12)
        XCTAssertGreaterThan(try number("Easing.outBack(0.8)"), 1)
        XCTAssertLessThan(try number("Easing.inBack(0.2)"), 0)
        XCTAssertEqual(try number("Easing.outBounce(0.5)"), 0.765625, accuracy: 1e-9)
        // bezier(0.25, 0.1, 0.25, 1) is CSS "ease"; ease(0.5) is about 0.8024
        XCTAssertEqual(try number("Easing.bezier(0.25, 0.1, 0.25, 1)(0.5)"), 0.8024, accuracy: 1e-3)
        XCTAssertEqual(try number("Easing.bezier(0, 0, 1, 1)(0.3)"), 0.3, accuracy: 1e-5)
        XCTAssertEqual(try number("Easing.bezier(0.42, 0, 0.58, 1)(0.5)"), 0.5, accuracy: 1e-5)
    }

    func testSpring() throws {
        XCTAssertEqual(try number("spring({ frame: 0, fps: 30 })"), 0)
        XCTAssertEqual(try number("spring({ frame: 5, fps: 30, delay: 10 })"), 0)
        XCTAssertEqual(try number("spring({ frame: 600, fps: 30 })"), 1, accuracy: 1e-6)
        XCTAssertEqual(try number("spring({ frame: 600, fps: 30, from: 10, to: 20 })"), 20, accuracy: 1e-5)
        XCTAssertEqual(try number("spring({ frame: 600, fps: 30, from: 1, to: 0, stiffness: 200, damping: 30 })"), 0, accuracy: 1e-6)
        // underdamped (default) overshoots, heavily damped does not
        XCTAssertGreaterThan(try number("Math.max.apply(null, Array.from({length: 60}, (_, i) => spring({frame: i, fps: 30})))"), 1.05)
        XCTAssertLessThanOrEqual(try number("Math.max.apply(null, Array.from({length: 300}, (_, i) => spring({frame: i, fps: 30, damping: 100})))"), 1.0000001)
        XCTAssertEqual(try number("spring({ frame: 600, fps: 30, damping: 2 * Math.sqrt(100) })"), 1, accuracy: 1e-6)  // critically damped
    }

    func testClampLerpMix() throws {
        XCTAssertEqual(try number("clamp(5, 0, 3)"), 3)
        XCTAssertEqual(try number("clamp(-5, 0, 3)"), 0)
        XCTAssertEqual(try number("lerp(10, 20, 0.25)"), 12.5)
        XCTAssertEqual(try value("mix('#000000', '#ffffff', 0.5)") as? String, "#808080")
        XCTAssertEqual(try value("mix('red', 'blue', 0)") as? String, "#ff0000")
        XCTAssertEqual(try value("mix('red', 'blue', 1)") as? String, "#0000ff")
        XCTAssertEqual(try value("mix('#f00', 'rgb(0, 0, 255)', 0.5)") as? String, "#800080")
        XCTAssertEqual(try value("mix('hsl(0, 100%, 50%)', 'white', 0)") as? String, "#ff0000")
        XCTAssertEqual(try value("mix('#ffffff', 'transparent', 0.5)") as? String, "rgba(128,128,128,0.5)")
        XCTAssertEqual(try value("mix('#ff000080', '#ff000080', 0.3)") as? String, "rgba(255,0,0,0.502)")
        expectError(Self.header + "return text(mix('nope', 'red', 0.5));\n});", kind: .script, line: 2, frame: 0)
    }

    func testRandomAndNoise() throws {
        let a = try number("random(1)"), b = try number("random(1)")
        XCTAssertEqual(a, b)
        XCTAssertTrue((0..<1).contains(a))
        XCTAssertNotEqual(try number("random(1)"), try number("random(2)"))
        XCTAssertNotEqual(try number("random('a')"), try number("random('b')"))
        XCTAssertEqual(try number("random('hello')"), try number("random('hello')"))
        let spread = try number("(function(){ var s = 0; for (var i = 0; i < 2000; i++) s += random(i); return s / 2000; })()")
        XCTAssertEqual(spread, 0.5, accuracy: 0.05)
        XCTAssertEqual(try number("noise(3.3, 1.7)"), try number("noise(3.3, 1.7)"))
        let range = try number("(function(){ var lo = 9, hi = -9; for (var i = 0; i < 2000; i++) { var n = noise(i * 0.37, i * 0.11); lo = Math.min(lo, n); hi = Math.max(hi, n); } return lo >= -1 && hi <= 1 && hi - lo > 0.5 ? 1 : 0; })()")
        XCTAssertEqual(range, 1)
        // smooth: close inputs give close outputs
        XCTAssertEqual(try number("noise(2.5) - noise(2.501)"), 0, accuracy: 0.02)
    }

    func testSequence() throws {
        let items = "[{ durationInFrames: 10, render: (f, i) => ({ f: f, i: i }) }, { durationInFrames: 20, render: (f, i) => ({ f: f, i: i }) }]"
        XCTAssertEqual(try value("sequence(5, \(items))") as? [String: Int], ["f": 5, "i": 0])
        XCTAssertEqual(try value("sequence(9, \(items))") as? [String: Int], ["f": 9, "i": 0])
        XCTAssertEqual(try value("sequence(10, \(items))") as? [String: Int], ["f": 0, "i": 1])
        XCTAssertEqual(try value("sequence(12, \(items))") as? [String: Int], ["f": 2, "i": 1])
        XCTAssertTrue(try value("sequence(30, \(items))") is NSNull)
    }

    func testSeries() throws {
        let items = "[{ id: 'A', durationInFrames: 30 }, { id: 'B', durationInFrames: 30 }, { id: 'C', durationInFrames: 30 }]"
        func call(_ f: Int) throws -> [String: Any] {
            let v = try value("series(\(f), \(items), 10, (a, b, p, ia, ib) => ({ a: a.id, b: b ? b.id : null, p: p, ia: ia, ib: ib }))")
            return try XCTUnwrap(v as? [String: Any])
        }
        var r = try call(10)
        XCTAssertEqual(r["a"] as? String, "A"); XCTAssertTrue(r["b"] is NSNull); XCTAssertEqual(r["p"] as? Double, 0)
        r = try call(19)
        XCTAssertTrue(r["b"] is NSNull)
        r = try call(20)
        XCTAssertEqual(r["b"] as? String, "B"); XCTAssertEqual(r["p"] as? Double, 0); XCTAssertEqual(r["ib"] as? Int, 1)
        r = try call(25)
        XCTAssertEqual(r["a"] as? String, "A"); XCTAssertEqual(r["b"] as? String, "B")
        XCTAssertEqual(r["p"] as? Double ?? -1, 0.5, accuracy: 1e-12); XCTAssertEqual(r["ia"] as? Int, 0)
        r = try call(30)
        XCTAssertEqual(r["a"] as? String, "B"); XCTAssertTrue(r["b"] is NSNull); XCTAssertEqual(r["ia"] as? Int, 1)
        r = try call(55)
        XCTAssertEqual(r["a"] as? String, "B"); XCTAssertEqual(r["b"] as? String, "C"); XCTAssertEqual(r["p"] as? Double ?? -1, 0.5, accuracy: 1e-12)
        r = try call(85)
        XCTAssertEqual(r["a"] as? String, "C"); XCTAssertTrue(r["b"] is NSNull)  // last item has no next
        XCTAssertTrue(try value("series(90, \(items), 10, () => 1)") is NSNull)
    }

    func testSecondsFrames() throws {
        XCTAssertEqual(try number("secondsToFrames(1.5, 30)"), 45)
        XCTAssertEqual(try number("framesToSeconds(45, 30)"), 1.5)
    }

    // MARK: determinism

    func testDeterminism() throws {
        let src = Self.header + """
          var r = Math.random();
          return [rect(r * 50, Date.now(), 10, 10), text(String(new Date().getTime()) + ":" + Math.random(), {}), solid("red", { opacity: random(frame) })];
        });
        """
        let a = try SprocketScript(source: src), b = try SprocketScript(source: src)
        let j3 = try a.json(frame: 3), j7 = try a.json(frame: 7)
        XCTAssertNotEqual(j3, j7)
        XCTAssertEqual(try a.json(frame: 3), j3)
        XCTAssertEqual(try a.json(frame: 7), j7)
        XCTAssertEqual(try b.json(frame: 7), j7)   // other order, other instance
        XCTAssertEqual(try b.json(frame: 3), j3)
        let n = try a.node(frame: 30)               // Date.now() is the frame time in ms
        XCTAssertEqual(n.children?[0].y, 1000)
        XCTAssertTrue(n.children?[1].text?.hasPrefix("1000:") == true)
    }

    func testConcurrentCalls() throws {
        let s = try script("[rect(Math.random() * 100, frame, 10, 10)]")
        let expected = try (0..<60).map { try s.json(frame: $0) }
        let failures = NSLock(); var bad = 0
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            let f = (i * 7) % 60
            if (try? s.json(frame: f)) != expected[f] { failures.lock(); bad += 1; failures.unlock() }
        }
        XCTAssertEqual(bad, 0)
    }

    func testFrameClamping() throws {
        let s = try script("rect(frame, 0, 1, 1)")
        XCTAssertEqual(try s.json(frame: -5), try s.json(frame: 0))
        XCTAssertEqual(try s.json(frame: 1000), try s.json(frame: 59))
        XCTAssertEqual(try s.node(frame: 1000).x, 59)
    }

    // MARK: normalisation

    func testNestedArraysAndNulls() throws {
        let s = try script("[null, [rect(1, 1, 1, 1), [false, undefined, solid('red', { opacity: 0.5 }), [[null]]]], false, group([null, [text('x')]])]")
        let n = try s.node(frame: 0)
        XCTAssertEqual(n.type, "group")
        XCTAssertEqual(n.children?.map(\.type), ["rect", "solid", "group"])
        XCTAssertEqual(n.children?[2].children?.map(\.type), ["text"])
    }

    func testTopLevelShapes() throws {
        for body in ["null", "undefined", "false", "[]", "[null, [false]]"] {
            let n = try script(body).node(frame: 0)
            XCTAssertEqual(n.type, "group", body); XCTAssertEqual(n.children?.count, 0, body)
        }
        let single = try script("rect(0, 0, 5, 5)").node(frame: 0)
        XCTAssertEqual(single.type, "rect")
        expectError(Self.header + "return 42;\n});", kind: .script, frame: 0)
        expectError(Self.header + "return [{ nope: 1 }];\n});", kind: .script, frame: 0)
    }

    func testNaNAndInfinity() throws {
        // A non-finite geometry value hides the node (see ValidationTests); other non-finite values are dropped or clamped.
        let s = try script("[rect(NaN, Infinity, 10, -Infinity, { opacity: NaN }), rect(1, 2, 10, 20, { opacity: NaN, effects: [{ name: 'colorMatrix', matrix: [1, NaN, Infinity] }], transform: { scale: 3, rotate: 5 } })]")
        let hidden = try XCTUnwrap(s.node(frame: 0).children?.first)
        XCTAssertEqual(hidden.type, "group"); XCTAssertEqual(hidden.children?.count, 0)
        let n = try XCTUnwrap(s.node(frame: 0).children?.last)
        XCTAssertEqual(n.type, "rect"); XCTAssertEqual(n.width, 10)
        XCTAssertNil(n.opacity); XCTAssertEqual(n.transform?.scale, 3); XCTAssertEqual(n.transform?.rotate, 5)
        XCTAssertEqual(n.effects?.first?.matrix, [1, 0, 0])
        XCTAssertFalse(try s.json(frame: 0).contains("null"))
    }

    func testBadPropTypeIsScriptError() {
        expectError(Self.header + "return rect(0, 0, 1, 1, { color: 12 });\n});", kind: .script, frame: 0)
    }

    // MARK: errors

    func testSyntaxErrorLine() {
        expectError("// one\n\ncomposition({ width: 100 }, function () {\n  var x = ;\n});", kind: .script, line: 4)
    }

    func testRuntimeErrorAtLoadLine() {
        expectError("// one\n// two\n// three\nthrow new Error('boom');", kind: .script, line: 4)
        expectError("var a = 1;\nundefinedFunction();", kind: .script, line: 2)
    }

    func testRuntimeErrorInRenderLine() {
        let src = "composition({ width: 100, height: 100, fps: 30, durationInFrames: 10 }, function (frame) {\n\n  if (frame > 2) {\n    throw new Error('late');\n  }\n  return null;\n});"
        do {
            let s = try SprocketScript(source: src)
            _ = try s.node(frame: 1)
            _ = try s.node(frame: 5)
            XCTFail("expected error")
        } catch let e as SprocketError {
            XCTAssertEqual(e.kind, .script); XCTAssertEqual(e.line, 4); XCTAssertTrue(e.message.contains("late"), e.message)
        } catch { XCTFail("\(error)") }
    }

    func testCompositionCallCount() {
        expectError("var x = 1;", kind: .script)
        expectError("composition({ width: 100, height: 100, fps: 30, durationInFrames: 10 }, function () { return null; });\n" +
                    "composition({ width: 100, height: 100, fps: 30, durationInFrames: 10 }, function () { return null; });", kind: .script, line: 2)
        expectError("composition({ width: 100, height: 100, fps: 30, durationInFrames: 10 });", kind: .script, line: 1)
    }

    func testInvalidConfig() {
        func src(_ cfg: String) -> String { "composition(\(cfg), function () { return null; });" }
        expectError(src("{ width: 8, height: 100, fps: 30, durationInFrames: 10 }"), kind: .script)
        expectError(src("{ width: 100, height: 5000, fps: 30, durationInFrames: 10 }"), kind: .script)
        expectError(src("{ width: 100, height: 100, fps: 0, durationInFrames: 10 }"), kind: .script)
        expectError(src("{ width: 100, height: 100, fps: 121, durationInFrames: 10 }"), kind: .script)
        expectError(src("{ width: 100, height: 100, fps: 30, durationInFrames: 0 }"), kind: .script)
        expectError(src("{ width: 100, height: 100, fps: 30, durationInFrames: 36001 }"), kind: .script)
        expectError(src("{ width: 100, height: 100, fps: 30 }"), kind: .script)
        expectError(src("{ width: 'wide', height: 100, fps: 30, durationInFrames: 10 }"), kind: .script)
        XCTAssertNoThrow(try SprocketScript(source: src("{ width: 16, height: 4096, fps: 120, durationInFrames: 36000, background: '#000' }")))
    }

    // MARK: limits

    func testInfiniteLoopAtLoadTimesOut() {
        let t0 = Date()
        expectError("while (true) {}", kind: .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 6)
    }

    func testInfiniteLoopInRenderTimesOut() throws {
        let s = try SprocketScript(source: "composition({ width: 100, height: 100, fps: 30, durationInFrames: 10 }, function (frame) {\n  if (frame === 1) { for (;;) { try { } catch (e) {} } }\n  return rect(frame, 0, 1, 1);\n});")
        XCTAssertEqual(try s.node(frame: 0).x, 0)
        let t0 = Date()
        XCTAssertThrowsError(try s.node(frame: 1)) { e in XCTAssertEqual((e as? SprocketError)?.kind, .timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
        XCTAssertEqual(try s.node(frame: 2).x, 2)   // the context still works afterwards
        XCTAssertThrowsError(try s.node(frame: 1)) { e in XCTAssertEqual((e as? SprocketError)?.kind, .timeout) }
    }

    func testNodeCap() throws {
        let s = try SprocketScript(source: "composition({ width: 100, height: 100, fps: 30, durationInFrames: 10 }, function (frame) {\n  var n = frame === 0 ? 5000 : 5001;\n  var out = [];\n  for (var i = 0; i < n; i++) out.push(solid('red'));\n  return out;\n});")
        XCTAssertEqual(try s.node(frame: 0).children?.count, 5000)
        XCTAssertThrowsError(try s.node(frame: 1)) { e in
            XCTAssertEqual((e as? SprocketError)?.kind, .script)
            XCTAssertTrue((e as? SprocketError)?.message.contains("5000") == true)
        }
        // nested children count too
        let t = try SprocketScript(source: "composition({ width: 100, height: 100, fps: 30, durationInFrames: 10 }, function () {\n  var kids = []; for (var i = 0; i < 5000; i++) kids.push(solid('red'));\n  return group(kids);\n});")
        XCTAssertThrowsError(try t.node(frame: 0))
    }

    // MARK: safety and logs

    func testNoOutsideAPIs() throws {
        let names = ["setTimeout", "setInterval", "setImmediate", "clearTimeout", "fetch", "XMLHttpRequest", "WebSocket", "require", "process",
                     "performance", "document", "window", "navigator", "localStorage", "importScripts", "Worker", "module", "Buffer", "XMLHttpRequestUpload",
                     "__motionLog", "queueMicrotask", "readFile", "print", "load", "read"]
        for n in names {
            XCTAssertEqual(try value("typeof \(n)") as? String, "undefined", n)
        }
    }

    func testConsoleLogCollects() throws {
        let s = try SprocketScript(source: "console.log('load', 1, { a: 2 });\n" + Self.header + "  console.log('frame', frame);\n  return null;\n});")
        XCTAssertEqual(s.logs, ["load 1 {\"a\":2}"])
        _ = try s.node(frame: 4)
        XCTAssertEqual(s.logs.last, "frame 4")
        for i in 0..<300 { _ = try s.node(frame: i % 60) }
        XCTAssertEqual(s.logs.count, 200)
        XCTAssertEqual(s.logs.first, "load 1 {\"a\":2}")
    }

    func testPreludeLinesDoNotOffsetUserLines() {
        expectError("null.x;", kind: .script, line: 1)
    }
}
