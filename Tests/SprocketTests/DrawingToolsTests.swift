import XCTest
import CoreImage
import CoreText
@testable import Sprocket

/// The drawing tools: stroke styles and trim, gradient fills, shape helpers, layoutText, skew and 3D tilt, the new
/// effects, fonts. Rendering tests draw tiny canvases and read pixels; script tests go through the JavaScript prelude.
final class DrawingToolsTests: XCTestCase {
    let white = RGBA(r: 255, g: 255, b: 255, a: 255)
    let black = RGBA(r: 0, g: 0, b: 0, a: 255)
    let red = RGBA(r: 255, g: 0, b: 0, a: 255)

    // MARK: helpers

    func assertPx(_ b: Bitmap, _ x: Int, _ y: Int, _ e: RGBA, tol: Int = 3, file: StaticString = #filePath, line: UInt = #line) {
        let p = b.px(x, y)
        XCTAssertTrue(p.near(e, tol), "pixel (\(x),\(y)) is \(p), expected \(e)", file: file, line: line)
    }

    func script(_ body: String, w: Int = 100, h: Int = 100) throws -> SprocketScript {
        try SprocketScript(source: "composition({ width: \(w), height: \(h), fps: 30, durationInFrames: 10 }, function (frame, ctx) {\n  return \(body);\n});")
    }

    func frameError(_ body: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try script(body).node(frame: 0)
            XCTFail("expected an error for \(body)", file: file, line: line)
        } catch let e as SprocketError { return e.message } catch { XCTFail("\(error)", file: file, line: line) }
        return ""
    }

    /// Renders what a script returns for frame 0.
    func drawScript(_ body: String, w: Int = 100, h: Int = 100) throws -> Bitmap {
        let s = try script(body, w: w, h: h)
        let img = SprocketRenderer().render(try s.node(frame: 0), config: s.config, resources: TestResources())
        return rasterize(img)
    }

    func inkCount(_ b: Bitmap, _ rows: Range<Int>, _ cols: Range<Int>, luma: Double = 128) -> Int {
        var n = 0
        for y in rows { for x in cols where b.px(x, y).luma > luma { n += 1 } }
        return n
    }

    // MARK: strokes

    func testLineCapSquareExtendsButtDoesNot() {
        // A horizontal line from x=30 to x=70, 20 thick.
        func render(_ cap: String) -> Bitmap {
            draw("{\"type\":\"path\",\"d\":\"M30 50 L70 50\",\"stroke\":\"#fff\",\"strokeWidth\":20,\"lineCap\":\"\(cap)\"}", w: 100, h: 100, bg: "#000")
        }
        let butt = render("butt"), square = render("square"), round = render("round")
        assertPx(butt, 25, 50, black); assertPx(butt, 35, 50, white)
        assertPx(square, 25, 50, white); assertPx(square, 21, 45, white)
        assertPx(round, 25, 50, white)
        assertPx(round, 21, 41, black)      // the round cap leaves the corner empty where square fills it
        assertPx(square, 21, 41, white)
    }

    func testLineJoinBevelCutsTheCorner() {
        func render(_ join: String) -> Bitmap {
            draw("{\"type\":\"path\",\"d\":\"M20 80 L50 20 L80 80\",\"stroke\":\"#fff\",\"strokeWidth\":16,\"lineJoin\":\"\(join)\"}", w: 100, h: 100, bg: "#000")
        }
        // The tip of a miter join pokes above the bevel's cut.
        let miter = render("miter"), bevel = render("bevel")
        XCTAssertGreaterThan(inkCount(miter, 0..<20, 0..<100), inkCount(bevel, 0..<20, 0..<100))
    }

    func testDashLeavesGaps() {
        let b = draw("{\"type\":\"path\",\"d\":\"M0 50 L100 50\",\"stroke\":\"#fff\",\"strokeWidth\":10,\"dash\":[20,20]}", w: 100, h: 100, bg: "#000")
        assertPx(b, 10, 50, white); assertPx(b, 30, 50, black); assertPx(b, 50, 50, white); assertPx(b, 70, 50, black)
        // dashOffset slides the pattern: shifting by 20 swaps on and off
        let c = draw("{\"type\":\"path\",\"d\":\"M0 50 L100 50\",\"stroke\":\"#fff\",\"strokeWidth\":10,\"dash\":[20,20],\"dashOffset\":20}", w: 100, h: 100, bg: "#000")
        assertPx(c, 10, 50, black); assertPx(c, 30, 50, white)
    }

    func testRoundCapDotsFromZeroLengthDashes() {
        let b = draw("{\"type\":\"path\",\"d\":\"M10 50 L90 50\",\"stroke\":\"#fff\",\"strokeWidth\":8,\"dash\":[0,20],\"lineCap\":\"round\"}", w: 100, h: 100, bg: "#000")
        assertPx(b, 10, 50, white); assertPx(b, 30, 50, white); assertPx(b, 20, 50, black)
    }

    func testTrimDrawsPartOfTheLine() {
        func render(_ s: Double, _ e: Double) -> Bitmap {
            draw("{\"type\":\"path\",\"d\":\"M0 50 L100 50\",\"stroke\":\"#fff\",\"strokeWidth\":10,\"trim\":{\"start\":\(s),\"end\":\(e)}}", w: 100, h: 100, bg: "#000")
        }
        let half = render(0, 0.5)
        assertPx(half, 25, 50, white); assertPx(half, 75, 50, black)
        let mid = render(0.25, 0.75)
        assertPx(mid, 10, 50, black); assertPx(mid, 50, 50, white); assertPx(mid, 90, 50, black)
        let none = render(0.5, 0.5)
        assertPx(none, 25, 50, black); assertPx(none, 75, 50, black)
        let all = render(0, 1)
        assertPx(all, 5, 50, white); assertPx(all, 95, 50, white)
    }

    func testTrimLeavesTheFillAlone() {
        let b = draw("{\"type\":\"rect\",\"x\":20,\"y\":20,\"width\":60,\"height\":60,\"color\":\"#00f\",\"stroke\":\"#fff\",\"strokeWidth\":6,\"trim\":{\"start\":0,\"end\":0.1}}", w: 100, h: 100, bg: "#000")
        assertPx(b, 50, 50, RGBA(r: 0, g: 0, b: 255, a: 255))
        // a rect's outline starts at the top-left and runs clockwise: 10% of 240 px = 24 px along the top edge
        assertPx(b, 30, 20, white); assertPx(b, 70, 20, RGBA(r: 0, g: 0, b: 0, a: 255), tol: 255)
        XCTAssertLessThan(b.px(70, 20).luma, 40)
        XCTAssertLessThan(b.px(79, 50).luma, 60)    // the right edge is not drawn
    }

    func testTrimOnRoundedRectStartsOnTheTopEdge() {
        let b = draw("{\"type\":\"rect\",\"x\":20,\"y\":20,\"width\":60,\"height\":60,\"radius\":10,\"stroke\":\"#fff\",\"strokeWidth\":4,\"trim\":{\"start\":0,\"end\":0.2}}", w: 100, h: 100, bg: "#000")
        assertPx(b, 40, 20, white)                  // along the top edge
        assertPx(b, 20, 50, black); assertPx(b, 50, 80, black)
    }

    func testTrimCountsLengthAcrossSubpaths() {
        // Two horizontal lines of 40 px each: trim 0...0.5 draws all of the first and none of the second.
        let d = "M10 30 L50 30 M10 70 L50 70"
        let b = draw("{\"type\":\"path\",\"d\":\"\(d)\",\"stroke\":\"#fff\",\"strokeWidth\":8,\"trim\":{\"start\":0,\"end\":0.5}}", w: 100, h: 100, bg: "#000")
        assertPx(b, 30, 30, white); assertPx(b, 48, 30, white); assertPx(b, 30, 70, black)
        let c = draw("{\"type\":\"path\",\"d\":\"\(d)\",\"stroke\":\"#fff\",\"strokeWidth\":8,\"trim\":{\"start\":0,\"end\":0.75}}", w: 100, h: 100, bg: "#000")
        assertPx(c, 30, 30, white); assertPx(c, 20, 70, white); assertPx(c, 45, 70, black)
    }

    func testTrimOnEllipseStartsAtTheTopAndRunsClockwise() {
        let b = draw("{\"type\":\"ellipse\",\"x\":20,\"y\":20,\"width\":60,\"height\":60,\"stroke\":\"#fff\",\"strokeWidth\":6,\"trim\":{\"start\":0,\"end\":0.25}}", w: 100, h: 100, bg: "#000")
        assertPx(b, 50, 20, white)       // 12 o'clock
        assertPx(b, 80, 45, white)       // just before 3 o'clock, where the quarter ends
        assertPx(b, 50, 80, black); assertPx(b, 20, 50, black)
    }

    func testStrokeStyleValidation() {
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { dash: 'x' })").contains("rect.dash must be an array of numbers, got string"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { dash: [1, 'a'] })").contains("rect.dash[1] must be a number, got string"))
        XCTAssertTrue(frameError("path('M0 0', { trim: 5 })").contains("path.trim must be an object, got number"))
        XCTAssertTrue(frameError("path('M0 0', { trim: { start: 'a' } })").contains("path.trim.start must be a number, got string"))
        XCTAssertTrue(frameError("ellipse(0, 0, 1, 1, { lineCap: 3 })").contains("ellipse.lineCap must be a string, got number"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { dashOffset: '2' })").contains("rect.dashOffset must be a number, got string"))
    }

    // MARK: gradient fills

    func testRectFillGradientReplacesColor() {
        let b = draw("{\"type\":\"rect\",\"x\":0,\"y\":0,\"width\":100,\"height\":100,\"color\":\"#00ff00\",\"fill\":{\"stops\":[{\"at\":0,\"color\":\"#ff0000\"},{\"at\":1,\"color\":\"#0000ff\"}]}}", w: 100, h: 100)
        // default linear: top to bottom of the shape's box
        XCTAssertGreaterThan(b.px(50, 3).r, 230); XCTAssertLessThan(b.px(50, 3).g, 20)
        XCTAssertGreaterThan(b.px(50, 96).b, 230)
        let mid = b.px(50, 50)
        XCTAssertTrue(abs(mid.r - 128) < 12 && abs(mid.b - 127) < 12 && mid.g < 10, "\(mid)")
    }

    func testGradientFillUsesTheShapesOwnBoxAndCanvasPixelPoints() {
        // An ellipse in the lower right; the default gradient runs over ITS box, not the canvas.
        let b = draw("{\"type\":\"ellipse\",\"x\":50,\"y\":50,\"width\":50,\"height\":50,\"fill\":{\"stops\":[{\"at\":0,\"color\":\"#ffffff\"},{\"at\":1,\"color\":\"#000000\"}]}}", w: 100, h: 100)
        XCTAssertGreaterThan(b.px(75, 56).luma, 200)
        XCTAssertLessThan(b.px(75, 94).luma, 60)
        // from/to in canvas pixels: left to right across the whole canvas
        let c = draw("{\"type\":\"rect\",\"fill\":{\"stops\":[{\"at\":0,\"color\":\"#ffffff\"},{\"at\":1,\"color\":\"#000000\"}],\"from\":{\"x\":0,\"y\":0},\"to\":{\"x\":100,\"y\":0}}}", w: 100, h: 100)
        XCTAssertGreaterThan(c.px(5, 50).luma, 220); XCTAssertLessThan(c.px(95, 50).luma, 35)
        XCTAssertTrue(abs(c.px(50, 10).luma - 128) < 15)
    }

    func testRadialPathFillAndStrokeStaySolid() {
        let b = draw("{\"type\":\"path\",\"d\":\"M10 10 L90 10 L90 90 L10 90 Z\",\"stroke\":\"#00ff00\",\"strokeWidth\":4,\"fill\":{\"kind\":\"radial\",\"stops\":[{\"at\":0,\"color\":\"#ffffff\"},{\"at\":1,\"color\":\"#000000\"}]}}", w: 100, h: 100)
        XCTAssertGreaterThan(b.px(50, 50).luma, 230)
        XCTAssertLessThan(b.px(15, 15).luma, 150)      // darker toward the corner
        assertPx(b, 50, 10, RGBA(r: 0, g: 255, b: 0, a: 255))
    }

    func testTextFillGradientFillsTheGlyphsOnly() {
        let b = draw("{\"type\":\"text\",\"text\":\"I\",\"x\":0,\"y\":10,\"width\":100,\"size\":80,\"weight\":900,\"fill\":{\"stops\":[{\"at\":0,\"color\":\"#ff0000\"},{\"at\":1,\"color\":\"#0000ff\"}]}}", w: 100, h: 100, bg: "#000")
        // glyph pixels are red-ish near the top and blue-ish near the bottom; the surroundings stay black
        var topRed = 0, bottomBlue = 0, stray = 0
        for y in 0..<100 { for x in 0..<100 {
            let p = b.px(x, y)
            if p.r + p.b > 200 { if p.r > p.b && y < 50 { topRed += 1 }; if p.b > p.r && y > 50 { bottomBlue += 1 } }
        } }
        for x in 0..<20 where b.px(x, 50).luma > 20 { stray += 1 }
        XCTAssertGreaterThan(topRed, 100); XCTAssertGreaterThan(bottomBlue, 100); XCTAssertEqual(stray, 0)
    }

    func testFillValidationAndNonFinite() {
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { fill: 'red' })").contains("rect.fill must be an object, got string"))
        XCTAssertTrue(frameError("text('a', { fill: { kind: 'linear' } })").contains("text.fill is missing \"stops\""))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { fill: { stops: [{ at: 0 }] } })").contains("rect.fill.stops[0] is missing \"color\""))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { fill: { stops: [{ at: 0, color: '#f00' }], from: { x: 1 } } })").contains("rect.fill.from is missing \"y\""))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { fill: { kind: 5, stops: [{ at: 0, color: '#f00' }] } })").contains("rect.fill.kind must be a string, got number"))
        XCTAssertTrue(frameError("text('a', { italic: 'yes' })").contains("text.italic must be true or false, got string"))
        // a non-finite gradient point hides the node, like any geometry
        let b = try! drawScript("rect(0, 0, 100, 100, { fill: { stops: [{ at: 0, color: '#fff' }], from: { x: NaN, y: 0 } } })")
        assertPx(b, 50, 50, black)
    }

    // MARK: shape helpers

    func pathD(_ expr: String) throws -> String {
        let json = try script(expr).json(frame: 0)
        let o = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let kids = o["children"] as? [[String: Any]] ?? [o]
        return kids[0]["d"] as! String
    }

    func testHelpersReturnPathNodesThatDraw() throws {
        for expr in ["line(10, 10, 90, 90, { stroke: '#fff', strokeWidth: 4 })",
                     "polyline([[10, 10], [50, 90], [90, 10]], { stroke: '#fff', strokeWidth: 4 })",
                     "polygon([{ x: 10, y: 10 }, { x: 90, y: 10 }, { x: 50, y: 90 }], { color: '#fff' })",
                     "star(50, 50, 5, 40, 16, { color: '#fff' })",
                     "arc(50, 50, 30, 0, 270, { stroke: '#fff', strokeWidth: 6 })",
                     "heart(50, 50, 80, { color: '#fff' })",
                     "smoothPath([[10, 50], [40, 20], [70, 80], [90, 50]], { stroke: '#fff', strokeWidth: 4 })"] {
            let b = try drawScript(expr)
            XCTAssertGreaterThan(inkCount(b, 0..<100, 0..<100), 30, expr)
        }
        let s = try script("star(50, 50, 5, 40, 16, {})")
        let o = try JSONSerialization.jsonObject(with: Data(try s.json(frame: 0).utf8)) as! [String: Any]
        let n = (o["children"] as? [[String: Any]])?[0] ?? o
        XCTAssertEqual(n["type"] as? String, "path")
    }

    func testStarHasTenCornersAndPointsUp() throws {
        let d = try pathD("star(50, 50, 5, 40, 16, {})")
        XCTAssertEqual(d.filter { $0 == "L" }.count, 9)             // M + 9 L + Z = 10 vertices
        XCTAssertTrue(d.hasPrefix("M50 10"), d)                    // first point straight up, outer radius
        let b = try drawScript("star(50, 50, 5, 40, 16, { color: '#fff' })")
        assertPx(b, 50, 30, white); assertPx(b, 50, 16, white); assertPx(b, 20, 80, black)
    }

    func testArcCoversTheRequestedAngles() throws {
        // 0 to 90 degrees runs from 3 o'clock down to 6 o'clock (clockwise on screen)
        let b = try drawScript("arc(50, 50, 30, 0, 90, { stroke: '#fff', strokeWidth: 6 })")
        assertPx(b, 80, 50, white); assertPx(b, 50, 80, white)
        assertPx(b, 50 + 21, 50 + 21, white)
        assertPx(b, 20, 50, black); assertPx(b, 50, 20, black)
        // a negative sweep goes the other way (up from 3 o'clock)
        let c = try drawScript("arc(50, 50, 30, 0, -90, { stroke: '#fff', strokeWidth: 6 })")
        assertPx(c, 50, 20, white); assertPx(c, 50, 80, black)
    }

    func testSmoothPathPassesThroughItsPointsAndClosedJoins() throws {
        let open = try pathD("smoothPath([[10, 10], [50, 50], [90, 10]], {})")
        XCTAssertTrue(open.hasPrefix("M10 10C"), open)
        XCTAssertTrue(open.hasSuffix(" 90 10"), open)
        XCTAssertFalse(open.hasSuffix("Z"))
        let closed = try pathD("smoothPath([[10, 10], [50, 50], [90, 10]], {}, true)")
        XCTAssertTrue(closed.hasSuffix("Z"))
        XCTAssertEqual(closed.filter { $0 == "C" }.count, 3)
        XCTAssertEqual(open.filter { $0 == "C" }.count, 2)
    }

    func testWobbleIsDeterministicAndBounded() throws {
        let s = try script("group([path('M0 0', {})]) && { type: 'group', children: [], k: [wobble([[10, 10], [50, 50]], 5, 3), wobble([[10, 10], [50, 50]], 5, 3), wobble([{ x: 10, y: 10 }], 5, 4)] }")
        let o = try JSONSerialization.jsonObject(with: Data(try s.json(frame: 0).utf8)) as! [String: Any]
        let k = o["k"] as! [[[Double]]]
        XCTAssertEqual(k[0], k[1])
        XCTAssertNotEqual(k[0][0], k[2][0])
        for (i, p) in k[0].enumerated() {
            let src = i == 0 ? [10.0, 10.0] : [50.0, 50.0]
            XCTAssertLessThanOrEqual(abs(p[0] - src[0]), 5); XCTAssertLessThanOrEqual(abs(p[1] - src[1]), 5)
        }
    }

    func testHelperErrorsNameTheHelper() {
        XCTAssertTrue(frameError("polyline('abc')").contains("polyline(): points must be an array of [x, y] or { x, y }, got string"))
        XCTAssertTrue(frameError("polygon([[1, 2], [3]])").contains("polygon(): point 1 must be [x, y] or { x, y } with numbers"))
        XCTAssertTrue(frameError("smoothPath([[1, 'a']])").contains("smoothPath(): point 0"))
        XCTAssertTrue(frameError("wobble(5, 1, 1)").contains("wobble(): points must be an array"))
    }

    // MARK: layoutText

    func layout(_ source: String) throws -> [[String: Any]] {
        let s = try SprocketScript(source: "composition({ width: 720, height: 400, fps: 30, durationInFrames: 3 }, function () { return { type: 'group', children: [], k: \(source) }; });")
        let o = try JSONSerialization.jsonObject(with: Data(try s.json(frame: 0).utf8)) as! [String: Any]
        return o["k"] as! [[String: Any]]
    }

    func testLayoutTextOneEntryPerCharacterWithLinesAndMonotonicX() throws {
        let g = try layout("layoutText('Hi there\\nbye', { x: 0, width: 720, size: 60, align: 'left' })")
        XCTAssertEqual(g.count, 11)                                      // 8 + 3, the newline has no entry
        XCTAssertEqual(g.map { $0["char"] as! String }.joined(), "Hi therebye")
        XCTAssertEqual(g.map { $0["index"] as! Int }, [0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 11])   // indices count the newline
        XCTAssertEqual(g.map { $0["line"] as! Int }, [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1])
        let xs = g.prefix(8).map { $0["x"] as! Double }
        XCTAssertEqual(xs[0], 0, accuracy: 0.01)
        for i in 1..<xs.count { XCTAssertGreaterThan(xs[i], xs[i - 1]) }
        let y0 = g[0]["y"] as! Double, y1 = g[8]["y"] as! Double
        XCTAssertEqual(y1 - y0, 72, accuracy: 0.01)                      // size 60 * lineHeight 1.2
        XCTAssertEqual(g[0]["height"] as! Double, 72, accuracy: 0.01)
        XCTAssertTrue((g[0]["width"] as! Double) > 20)
    }

    func testLayoutTextRespectsLetterSpacingAlignAndWrap() throws {
        let tight = try layout("layoutText('abcd', { x: 0, width: 700, size: 50, align: 'left' })")
        let wide = try layout("layoutText('abcd', { x: 0, width: 700, size: 50, align: 'left', letterSpacing: 10 })")
        XCTAssertEqual((wide[3]["x"] as! Double) - (tight[3]["x"] as! Double), 30, accuracy: 0.5)
        XCTAssertEqual(wide[0]["width"] as! Double, tight[0]["width"] as! Double, accuracy: 0.01)   // width is the glyph, not the spacing
        let left = try layout("layoutText('abcd', { x: 0, width: 700, size: 50, align: 'left' })")
        let centre = try layout("layoutText('abcd', { x: 0, width: 700, size: 50 })")
        let right = try layout("layoutText('abcd', { x: 0, width: 700, size: 50, align: 'right' })")
        let l = left[0]["x"] as! Double, c = centre[0]["x"] as! Double, r = right[0]["x"] as! Double
        XCTAssertTrue(l < c && c < r, "\(l) \(c) \(r)")
        let total = (left[3]["x"] as! Double) + (left[3]["width"] as! Double)
        XCTAssertEqual(c, (700 - total) / 2, accuracy: 1.0)
        // narrow box: the words wrap onto more lines
        let wrapped = try layout("layoutText('one two three four', { x: 0, width: 200, size: 40, align: 'left' })")
        XCTAssertGreaterThan(wrapped.map { $0["line"] as! Int }.max()!, 0)
    }

    func testLayoutTextDefaultsToTheCanvasWidth() throws {
        // centred in the 720-wide canvas by default, like text()
        let g = try layout("layoutText('I', { size: 50 })")
        let x = g[0]["x"] as! Double, w = g[0]["width"] as! Double
        XCTAssertEqual(x + w / 2, 360, accuracy: 1.5)
    }

    func testPerLetterRenderingMatchesWholeString() throws {
        // Draw "Sprocket made, per letter." both ways on a 400x200 canvas and compare the pictures.
        let props = "x: 20, width: 360, size: 44, weight: 700, letterSpacing: 1.5, align: 'center', lineHeight: 1.15, y: 20"
        let s = "Sprocket made,\\nper letter."
        let whole = try drawScript("text('\(s)', { \(props), color: '#ffffff' })", w: 400, h: 200)
        let letters = try drawScript("layoutText('\(s)', { \(props) }).map(function (g) { return text(g.char, { \(props), x: g.x, y: g.y, width: 300, align: 'left', color: '#ffffff' }); })", w: 400, h: 200)
        var maxDiff = 0, sum = 0, ink = 0
        for y in 0..<200 { for x in 0..<400 {
            let a = whole.px(x, y).luma, b = letters.px(x, y).luma
            let d = Int(abs(a - b)); maxDiff = max(maxDiff, d); sum += d
            if a > 10 { ink += 1 }
        } }
        XCTAssertGreaterThan(ink, 1500)
        // anti-aliasing may differ by a hair; the letters must land on the same pixels
        XCTAssertLessThan(Double(sum) / Double(ink), 2.5, "mean difference per ink pixel (max \(maxDiff))")
        XCTAssertLessThan(maxDiff, 90)
    }

    func testLayoutTextValidatesPropsLikeText() {
        XCTAssertTrue(frameError("layoutText('a', { size: 'big' })").contains("text.size must be a number, got string"))
        XCTAssertTrue(frameError("layoutText(null)").contains("text(): the first argument must be a string"))
        XCTAssertEqual((try? layout("layoutText('', {})"))?.count, 0)
        XCTAssertEqual((try? layout("layoutText('abc', { size: NaN })"))?.count, 0)        // non-finite geometry: nothing
        XCTAssertEqual((try? layout("layoutText('abc', { size: 5000 })"))?.count, 0)        // outside 1...4000
    }

    // MARK: skew and 3D tilt

    func testSkewXShiftsTheBottomRight() {
        // A 20x40 bar, centred; skewX 45 moves the bottom 20 px to the right relative to the middle, the top 20 px left.
        let base = "\"type\":\"rect\",\"x\":40,\"y\":30,\"width\":20,\"height\":40,\"color\":\"#fff\""
        let plain = draw("{\(base)}", w: 100, h: 100, bg: "#000")
        assertPx(plain, 50, 32, white); assertPx(plain, 50, 68, white)
        let skew = draw("{\(base),\"transform\":{\"skewX\":45}}", w: 100, h: 100, bg: "#000")
        assertPx(skew, 50 - 17, 32, white)        // top shifted left
        assertPx(skew, 50 + 17, 68, white)        // bottom shifted right
        assertPx(skew, 50, 32, black); assertPx(skew, 50, 68, black)
        let skewY = draw("{\(base),\"transform\":{\"skewY\":45}}", w: 100, h: 100, bg: "#000")
        assertPx(skewY, 42, 50 - 8, white)        // left edge moved up, right edge down
        assertPx(skewY, 58, 50 + 8, white)
    }

    func testTiltIsPerspectiveNotASquash() {
        // A 80x80 square tilted about the vertical axis with rotateY: the far side (right) shrinks, the near side stays.
        let base = "\"type\":\"rect\",\"x\":10,\"y\":10,\"width\":80,\"height\":80,\"color\":\"#fff\""
        let b = draw("{\(base),\"transform\":{\"rotateY\":50,\"perspective\":200}}", w: 100, h: 100, bg: "#000")
        func column(_ x: Int) -> Int { (0..<100).filter { b.px(x, $0).luma > 128 }.count }
        let left = column(28), right = column(72)
        XCTAssertGreaterThan(left, right + 8, "near edge \(left) px tall vs far edge \(right)")
        // the picture got narrower (cos 50 = 0.64 of 80 = 51 px) and stays centred on the origin
        let row = (0..<100).filter { b.px($0, 50).luma > 128 }
        XCTAssertLessThan(row.count, 62); XCTAssertGreaterThan(row.count, 40)
        // rotateX: top is the far side
        let c = draw("{\(base),\"transform\":{\"rotateX\":50,\"perspective\":200}}", w: 100, h: 100, bg: "#000")
        let topRow = (0..<100).filter { c.px($0, 24).luma > 128 }.count, botRow = (0..<100).filter { c.px($0, 76).luma > 128 }.count
        XCTAssertGreaterThan(botRow, topRow + 6, "top \(topRow) vs bottom \(botRow)")
    }

    func testPerspectiveDistanceChangesTheStrength() {
        let base = "\"type\":\"rect\",\"x\":10,\"y\":10,\"width\":80,\"height\":80,\"color\":\"#fff\""
        func farHeight(_ p: Int) -> Int {
            let b = draw("{\(base),\"transform\":{\"rotateY\":60,\"perspective\":\(p)}}", w: 100, h: 100, bg: "#000")
            return (0..<100).filter { b.px(62, $0).luma > 128 }.count
        }
        XCTAssertLessThan(farHeight(150), farHeight(5000))     // close camera: stronger foreshortening on the far side
    }

    func testTiltWithZeroAnglesIsTheIdentityAndNonFiniteHides() {
        let base = "\"type\":\"rect\",\"x\":10,\"y\":10,\"width\":80,\"height\":80,\"color\":\"#fff\""
        let a = draw("{\(base)}", w: 100, h: 100, bg: "#000")
        let b = draw("{\(base),\"transform\":{\"rotateX\":0,\"rotateY\":0,\"skewX\":0,\"perspective\":300}}", w: 100, h: 100, bg: "#000")
        XCTAssertEqual(a.data, b.data)
        let c = try! drawScript("rect(10, 10, 80, 80, { color: '#fff', transform: { rotateX: NaN } })")
        assertPx(c, 50, 50, black)
        let d = try! drawScript("rect(10, 10, 80, 80, { color: '#fff', transform: { skewX: Infinity } })")
        assertPx(d, 50, 50, black)
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { transform: { rotateY: 'a' } })").contains("transform.rotateY must be a number, got string"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { transform: { perspective: {} } })").contains("transform.perspective must be a number, got object"))
    }

    func testOrderIsScaleSkewTiltRotateTranslate() {
        // scale 2 then translate 20: a skewed, scaled bar ends up 20 px right of where scale alone puts it.
        let base = "\"type\":\"rect\",\"x\":45,\"y\":40,\"width\":10,\"height\":20,\"color\":\"#fff\""
        let a = draw("{\(base),\"transform\":{\"scale\":2,\"skewX\":30}}", w: 100, h: 100, bg: "#000")
        let b = draw("{\(base),\"transform\":{\"scale\":2,\"skewX\":30,\"translateX\":20}}", w: 100, h: 100, bg: "#000")
        for y in [35, 50, 65] {
            let xa = (0..<100).filter { a.px($0, y).luma > 128 }, xb = (0..<100).filter { b.px($0, y).luma > 128 }
            XCTAssertEqual((xb.first ?? 0) - (xa.first ?? 0), 20, accuracy: 1, "row \(y)")
        }
        // skew measured after the scale: y offset 20*2/2 = 20 -> shift 20 * tan 30 = 11.5 at the bar's bottom, relative to the middle
        let rowTop = (0..<100).filter { a.px($0, 33).luma > 128 }, rowBottom = (0..<100).filter { a.px($0, 67).luma > 128 }
        XCTAssertEqual(Double((rowBottom.first ?? 0) - (rowTop.first ?? 0)), 2 * 17 * tan(30 * .pi / 180), accuracy: 3)
    }

    // MARK: effects

    /// A 100x100 test picture: red left half, blue right half, a white 20 px square in the middle.
    func pic(_ fx: String, extra: String = "") -> Bitmap {
        let tree = group(
            "{\"type\":\"rect\",\"x\":0,\"y\":0,\"width\":50,\"height\":100,\"color\":\"#ff0000\"}",
            "{\"type\":\"rect\",\"x\":50,\"y\":0,\"width\":50,\"height\":100,\"color\":\"#0000ff\"}",
            "{\"type\":\"rect\",\"x\":40,\"y\":40,\"width\":20,\"height\":20,\"color\":\"#ffffff\"}",
            props: "\"effects\":[\(fx)]\(extra)")
        return draw(tree, w: 100, h: 100, bg: "#000")
    }

    func differs(_ a: Bitmap, _ b: Bitmap) -> Bool { a.data != b.data }

    func testDropShadowIsDrawnUnderTheNode() {
        let tree = group("{\"type\":\"rect\",\"x\":30,\"y\":30,\"width\":30,\"height\":30,\"color\":\"#ffffff\"}",
                         props: "\"effects\":[{\"name\":\"dropShadow\",\"color\":\"#ff0000\",\"radius\":0,\"x\":20,\"y\":20}]")
        let b = draw(tree, w: 100, h: 100, bg: "#000")
        assertPx(b, 40, 40, white)                                          // the node itself on top
        assertPx(b, 75, 75, red)                                            // shadow offset 20,20, no blur
        assertPx(b, 15, 15, black)
        let soft = draw(group("{\"type\":\"rect\",\"x\":30,\"y\":30,\"width\":30,\"height\":30,\"color\":\"#ffffff\"}",
                              props: "\"effects\":[{\"name\":\"dropShadow\",\"color\":\"#ff0000\",\"radius\":12,\"x\":0,\"y\":0}]"), w: 100, h: 100, bg: "#000")
        XCTAssertGreaterThan(soft.px(26, 45).r, 20); XCTAssertLessThan(soft.px(26, 45).r, 250)   // a blurred halo outside the box
    }

    func testWaveMovesPixelsAndZeroAmountDoesNot() {
        let base = pic("")
        XCTAssertFalse(differs(base, pic("{\"name\":\"wave\",\"amount\":0,\"wavelength\":20}")))
        let w = pic("{\"name\":\"wave\",\"amount\":8,\"wavelength\":40,\"angle\":0,\"phase\":0}")
        XCTAssertTrue(differs(base, w))
        // the white square's top edge (y=40) now varies with x; measure two columns a half wavelength apart
        func top(_ x: Int) -> Int { (0..<100).first { w.px(x, $0).luma > 200 } ?? -1 }
        XCTAssertGreaterThan(abs(top(50) - top(58)), 3)
        // angle 90: the wave travels down, pixels slide sideways: the left edge of the square (x=40) varies with y
        let v = pic("{\"name\":\"wave\",\"amount\":8,\"wavelength\":40,\"angle\":90,\"phase\":0}")
        func left(_ y: Int) -> Int { (0..<100).first { v.px($0, y).luma > 200 } ?? -1 }
        XCTAssertGreaterThan(abs(left(50) - left(58)), 3)
    }

    func testTwirlAndBulgeChangeTheCentreOnly() {
        let base = pic("")
        let t = pic("{\"name\":\"twirl\",\"radius\":30,\"angle\":180}")
        XCTAssertTrue(differs(base, t))
        assertPx(t, 5, 5, base.px(5, 5), tol: 1); assertPx(t, 95, 95, base.px(95, 95), tol: 1)    // outside the radius: untouched
        let bu = pic("{\"name\":\"bulge\",\"radius\":30,\"amount\":0.9}")
        XCTAssertTrue(differs(base, bu))
        assertPx(bu, 5, 5, base.px(5, 5), tol: 1)
        let pinch = pic("{\"name\":\"bulge\",\"radius\":30,\"amount\":-0.9}")
        XCTAssertTrue(differs(bu, pinch))
        // a bulge magnifies the white square, a pinch shrinks it
        func whites(_ b: Bitmap) -> Int { inkCount(b, 0..<100, 0..<100, luma: 200) }
        XCTAssertGreaterThan(whites(bu), whites(base)); XCTAssertLessThan(whites(pinch), whites(base))
    }

    func testDisplaceIsSeededAndSmooth() {
        let a = pic("{\"name\":\"displace\",\"amount\":6,\"scale\":30,\"seed\":1}")
        let a2 = pic("{\"name\":\"displace\",\"amount\":6,\"scale\":30,\"seed\":1}")
        let b = pic("{\"name\":\"displace\",\"amount\":6,\"scale\":30,\"seed\":2}")
        XCTAssertEqual(a.data, a2.data)
        XCTAssertTrue(differs(a, b)); XCTAssertTrue(differs(a, pic("")))
        // no pixel is further than `amount` from where it came from: the red/blue seam stays within 6 px of x=50 (+1 for edges)
        for y in stride(from: 0, to: 100, by: 7) where y < 36 || y > 64 {
            let seam = (0..<100).first { a.px($0, y).b > a.px($0, y).r } ?? 100
            XCTAssertTrue(abs(seam - 50) <= 8, "row \(y): seam at \(seam)")
        }
    }

    func testGlitchIsDeterministicSeededAndVisible() {
        let fx = { (seed: Int, amount: Double) in "{\"name\":\"glitch\",\"amount\":\(amount),\"seed\":\(seed),\"slices\":8}" }
        let a = pic(fx(4, 0.8)), a2 = pic(fx(4, 0.8)), b = pic(fx(5, 0.8))
        XCTAssertEqual(a.data, a2.data)
        XCTAssertTrue(differs(a, b)); XCTAssertTrue(differs(a, pic("")))
        XCTAssertFalse(differs(pic(""), pic(fx(4, 0))))
        // slices slide sideways: some rows have their red/blue seam away from x=50
        var moved = 0
        for y in 0..<100 { let seam = (0..<100).first { a.px($0, y).b > a.px($0, y).r + 100 } ?? 50; if abs(seam - 50) > 6 { moved += 1 } }
        XCTAssertGreaterThan(moved, 8)
    }

    func testScanlinesDarkenEveryOtherBand() {
        let b = draw("{\"type\":\"solid\",\"color\":\"#ffffff\",\"effects\":[{\"name\":\"scanlines\",\"amount\":1,\"spacing\":10}]}", w: 100, h: 100, bg: "#000")
        var dark = 0, light = 0
        for y in 0..<100 { if b.px(50, y).luma < 40 { dark += 1 } else if b.px(50, y).luma > 215 { light += 1 } }
        XCTAssertGreaterThan(dark, 35); XCTAssertGreaterThan(light, 35)
        // period 10: pixel rows y and y+10 agree
        for y in 5..<80 { XCTAssertEqual(b.px(50, y).luma, b.px(50, y + 10).luma, accuracy: 30, "row \(y)") }
    }

    func testPosterizeThresholdDuotoneMirrorEdges() {
        // posterize 2: every channel is 0 or 255
        let p = draw("{\"type\":\"solid\",\"color\":\"#6699cc\",\"effects\":[{\"name\":\"posterize\",\"levels\":2}]}", w: 20, h: 20)
        let pp = p.px(10, 10)
        XCTAssertTrue([0, 255].contains(pp.r) && [0, 255].contains(pp.g) && [0, 255].contains(pp.b), "\(pp)")
        // threshold: luma above the level is white, below is black
        let th = pic("{\"name\":\"threshold\",\"amount\":0.3}")
        assertPx(th, 55, 5, black)                  // blue luma 0.07 is below 0.3
        assertPx(th, 50, 50, white)
        let th2 = draw("{\"type\":\"solid\",\"color\":\"#808080\",\"effects\":[{\"name\":\"threshold\",\"amount\":0.2}]}", w: 20, h: 20)
        assertPx(th2, 10, 10, white)
        // duotone: black maps to dark, white to light
        let du = draw(group("{\"type\":\"rect\",\"x\":0,\"y\":0,\"width\":10,\"height\":20,\"color\":\"#000000\"}",
                            "{\"type\":\"rect\",\"x\":10,\"y\":0,\"width\":10,\"height\":20,\"color\":\"#ffffff\"}",
                            props: "\"effects\":[{\"name\":\"duotone\",\"dark\":\"#102030\",\"light\":\"#ffe0a0\"}]"), w: 20, h: 20)
        assertPx(du, 5, 10, RGBA(r: 16, g: 32, b: 48, a: 255)); assertPx(du, 15, 10, RGBA(r: 255, g: 224, b: 160, a: 255))
        // mirror x: the left half (red) is reflected onto the right half
        let mx = pic("{\"name\":\"mirror\",\"axis\":\"x\"}")
        assertPx(mx, 90, 10, red); assertPx(mx, 10, 10, red)
        let my = draw(group("{\"type\":\"rect\",\"x\":0,\"y\":0,\"width\":100,\"height\":50,\"color\":\"#00ff00\"}",
                            "{\"type\":\"rect\",\"x\":0,\"y\":50,\"width\":100,\"height\":50,\"color\":\"#0000ff\"}",
                            props: "\"effects\":[{\"name\":\"mirror\",\"axis\":\"y\"}]"), w: 100, h: 100)
        assertPx(my, 50, 90, RGBA(r: 0, g: 255, b: 0, a: 255))
        // edges: a flat area goes black, the seam lights up
        let ed = pic("{\"name\":\"edges\",\"amount\":4}")
        assertPx(ed, 10, 90, black)
        XCTAssertGreaterThan((46...53).map { ed.px($0, 90).luma }.max()!, 60)
    }

    func testHalftoneKeepsAlphaAndExtent() {
        // a node with a transparent area stays transparent there
        let b = draw(group("{\"type\":\"rect\",\"x\":0,\"y\":0,\"width\":50,\"height\":100,\"color\":\"#ff8800\"}",
                           props: "\"effects\":[{\"name\":\"halftone\",\"radius\":3,\"angle\":15}]"), w: 100, h: 100, bg: "#000")
        assertPx(b, 80, 50, black)
        XCTAssertGreaterThan(inkCount(b, 0..<100, 0..<50, luma: 10), 300)
    }

    func testEffectParameterTypesAreChecked() {
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { effects: [{ name: 'posterize', levels: 'a' }] })").contains("effects[0].levels must be a number, got string"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { effects: [{ name: 'wave', wavelength: {} }] })").contains("effects[0].wavelength must be a number, got object"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { effects: [{ name: 'duotone', dark: 5 }] })").contains("effects[0].dark must be a string, got number"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { effects: [{ name: 'mirror', axis: 1 }] })").contains("effects[0].axis must be a string, got number"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { effects: [{ name: 'glitch', slices: 'x' }] })").contains("effects[0].slices must be a number, got string"))
        XCTAssertTrue(frameError("rect(0, 0, 1, 1, { effects: [{ name: 'dropShadow', color: 3 }] })").contains("effects[0].color must be a string, got number"))
    }

    func testEffectsKeepTheCanvasExtent() {
        let names = ["dropShadow", "wave", "twirl", "bulge", "displace", "glitch", "scanlines", "posterize", "threshold", "halftone", "duotone", "mirror", "edges"]
        for name in names {
            // draw() asserts the output extent is exactly the canvas
            _ = pic("{\"name\":\"\(name)\",\"amount\":0.5,\"radius\":20,\"x\":50,\"y\":50}")
        }
    }

    // MARK: fonts

    func testFamilyNamesSortedAndWithoutHiddenFamilies() {
        let names = SprocketFonts.familyNames()
        XCTAssertFalse(names.isEmpty)
        XCTAssertFalse(names.contains { $0.hasPrefix(".") })
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertTrue(names.contains("Helvetica"))
    }

    func testMissingFontIsReportedOnceThroughWarnings() async throws {
        let s = try SprocketScript(source: """
        composition({ width: 100, height: 100, fps: 30, durationInFrames: 3 }, function (frame) {
          return [text("hi", { font: "Nonexistent Display Face", size: 30 }), text("ok", { font: "Helvetica", y: 50 }),
                  layoutText("x", { font: "Another Missing Font" }).length ? null : null];
        });
        """)
        let ex = SprocketExporter(script: s, assets: [:])
        _ = try await ex.still(frame: 0)
        _ = try await ex.still(frame: 1)
        XCTAssertEqual(ex.warnings.filter { $0.contains("Nonexistent Display Face") }, ["font \"Nonexistent Display Face\" is not installed; drew the system font"])
        XCTAssertEqual(ex.warnings.filter { $0.contains("Another Missing Font") }.count, 1)
        XCTAssertFalse(ex.warnings.contains { $0.contains("\"Helvetica\"") })
    }

    func testItalicChangesTheDrawing() {
        func render(_ italic: Bool) -> Bitmap {
            draw("{\"type\":\"text\",\"text\":\"l\",\"x\":0,\"y\":10,\"width\":100,\"size\":80,\"weight\":700,\"italic\":\(italic)}", w: 100, h: 100, bg: "#000")
        }
        let up = render(false), it = render(true)
        func centreOfInk(_ b: Bitmap, rows: Range<Int>) -> Double {
            var sum = 0.0, n = 0.0
            for y in rows { for x in 0..<100 { let l = b.px(x, y).luma; sum += Double(x) * l; n += l } }
            return sum / max(n, 1)
        }
        // an italic "l" leans right: its top is further right than its bottom; the upright one is vertical
        let upLean = centreOfInk(up, rows: 20..<40) - centreOfInk(up, rows: 60..<80)
        let itLean = centreOfInk(it, rows: 20..<40) - centreOfInk(it, rows: 60..<80)
        XCTAssertLessThan(abs(upLean), 1.5)
        XCTAssertGreaterThan(itLean, 3)
    }
}
