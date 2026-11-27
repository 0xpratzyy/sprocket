import XCTest
import CoreImage
import CoreGraphics
import ImageIO
@testable import Sprocket

// MARK: helpers

struct RGBA: Equatable, CustomStringConvertible {
    var r: Int, g: Int, b: Int, a: Int
    var description: String { "(\(r),\(g),\(b),\(a))" }
    func near(_ o: RGBA, _ tol: Int = 2) -> Bool { abs(r - o.r) <= tol && abs(g - o.g) <= tol && abs(b - o.b) <= tol && abs(a - o.a) <= tol }
    var luma: Double { 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b) }
}

struct Bitmap {
    let w: Int, h: Int
    var data: [UInt8]
    /// Pixel with (0,0) at the top left of the picture.
    func px(_ x: Int, _ y: Int) -> RGBA {
        let i = (y * w + x) * 4
        return RGBA(r: Int(data[i]), g: Int(data[i + 1]), b: Int(data[i + 2]), a: Int(data[i + 3]))
    }
}

struct TestResources: FrameResources, @unchecked Sendable {
    var videos: [String: CIImage] = [:]
    var images: [String: CIImage] = [:]
    func videoFrame(src: String, time: Double) -> CIImage? { videos[src] }
    func image(src: String) -> CIImage? { images[src] }
}

func node(_ json: String) -> Node {
    try! JSONDecoder().decode(Node.self, from: Data(json.utf8))
}

func group(_ children: String..., props: String = "") -> String {
    "{\"type\":\"group\",\"children\":[\(children.joined(separator: ","))]\(props.isEmpty ? "" : "," + props)}"
}

func rasterize(_ image: CIImage) -> Bitmap {
    let w = Int(image.extent.width), h = Int(image.extent.height)
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    SprocketRenderer.context.render(image, toBitmap: &buf, rowBytes: w * 4, bounds: image.extent, format: .RGBA8,
                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    return Bitmap(w: w, h: h, data: buf)
}

func draw(_ json: String, w: Int = 200, h: Int = 200, bg: String? = nil, res: TestResources = TestResources()) -> Bitmap {
    let cfg = CompositionConfig(width: w, height: h, fps: 30, durationInFrames: 1, audio: nil, background: bg)
    let img = SprocketRenderer().render(node(json), config: cfg, resources: res)
    XCTAssertEqual(img.extent, CGRect(x: 0, y: 0, width: w, height: h))
    return rasterize(img)
}

func solidImage(_ color: CIColor, _ r: CGRect) -> CIImage { CIImage(color: color).cropped(to: r) }

/// Left half red, right half blue.
func halfRedBlue(_ w: Int, _ h: Int) -> CIImage {
    let red = solidImage(CIColor(red: 1, green: 0, blue: 0), CGRect(x: 0, y: 0, width: w / 2, height: h))
    let blue = solidImage(CIColor(red: 0, green: 0, blue: 1), CGRect(x: 0, y: 0, width: w, height: h))
    return red.composited(over: blue)
}

/// Top half red, bottom half blue (picture orientation).
func topRedBottomBlue(_ w: Int, _ h: Int) -> CIImage {
    // Core Image y is up: the red part is the upper rows, y in [h/2, h).
    let red = solidImage(CIColor(red: 1, green: 0, blue: 0), CGRect(x: 0, y: h / 2, width: w, height: h / 2))
    let blue = solidImage(CIColor(red: 0, green: 0, blue: 1), CGRect(x: 0, y: 0, width: w, height: h))
    return red.composited(over: blue)
}

final class RenderTests: XCTestCase {
    let red = RGBA(r: 255, g: 0, b: 0, a: 255)
    let green = RGBA(r: 0, g: 255, b: 0, a: 255)
    let blue = RGBA(r: 0, g: 0, b: 255, a: 255)
    let black = RGBA(r: 0, g: 0, b: 0, a: 255)
    let white = RGBA(r: 255, g: 255, b: 255, a: 255)

    func assertPx(_ b: Bitmap, _ x: Int, _ y: Int, _ e: RGBA, tol: Int = 2, file: StaticString = #filePath, line: UInt = #line) {
        let p = b.px(x, y)
        XCTAssertTrue(p.near(e, tol), "pixel (\(x),\(y)) is \(p), expected \(e)", file: file, line: line)
    }

    // MARK: colour

    func testColorParserTable() {
        func c(_ s: String) -> (Double, Double, Double, Double)? { SprocketColor.parse(s).map { ($0.r, $0.g, $0.b, $0.a) } }
        func eq(_ s: String, _ r: Double, _ g: Double, _ b: Double, _ a: Double, file: StaticString = #filePath, line: UInt = #line) {
            guard let v = c(s) else { return XCTFail("\(s) did not parse", file: file, line: line) }
            XCTAssertEqual(v.0, r, accuracy: 0.003, "\(s) r", file: file, line: line)
            XCTAssertEqual(v.1, g, accuracy: 0.003, "\(s) g", file: file, line: line)
            XCTAssertEqual(v.2, b, accuracy: 0.003, "\(s) b", file: file, line: line)
            XCTAssertEqual(v.3, a, accuracy: 0.003, "\(s) a", file: file, line: line)
        }
        eq("#fff", 1, 1, 1, 1)
        eq("#f00", 1, 0, 0, 1)
        eq("#f008", 1, 0, 0, 136.0 / 255)
        eq("#ff8000", 1, 128.0 / 255, 0, 1)
        eq("#ff800080", 1, 128.0 / 255, 0, 128.0 / 255)
        eq("  #FF8000 ", 1, 128.0 / 255, 0, 1)
        eq("rgb(255, 0, 0)", 1, 0, 0, 1)
        eq("rgb(0 128 255)", 0, 128.0 / 255, 1, 1)
        eq("rgb(100%, 0%, 50%)", 1, 0, 0.5, 1)
        eq("rgba(0, 0, 255, 0.5)", 0, 0, 1, 0.5)
        eq("rgba(0,0,255,50%)", 0, 0, 1, 0.5)
        eq("rgb(300, -5, 0)", 1, 0, 0, 1)
        eq("hsl(0, 100%, 50%)", 1, 0, 0, 1)
        eq("hsl(120, 100%, 50%)", 0, 1, 0, 1)
        eq("hsl(240deg, 100%, 50%)", 0, 0, 1, 1)
        eq("hsl(-120, 100%, 50%)", 0, 0, 1, 1)
        eq("hsl(0, 0%, 50%)", 0.5, 0.5, 0.5, 1)
        eq("hsla(60, 100%, 50%, 0.25)", 1, 1, 0, 0.25)
        eq("white", 1, 1, 1, 1)
        eq("Black", 0, 0, 0, 1)
        eq("red", 1, 0, 0, 1)
        eq("blue", 0, 0, 1, 1)
        eq("yellow", 1, 1, 0, 1)
        eq("orange", 1, 165.0 / 255, 0, 1)
        eq("purple", 128.0 / 255, 0, 128.0 / 255, 1)
        eq("pink", 1, 192.0 / 255, 203.0 / 255, 1)
        eq("gray", 128.0 / 255, 128.0 / 255, 128.0 / 255, 1)
        eq("green", 0, 128.0 / 255, 0, 1)
        eq("transparent", 0, 0, 0, 0)
        for bad in ["", "   ", "#", "#ff", "#fffff", "#ggg", "rgb(1,2)", "rgb(a,b,c)", "rgb(1,2,3", "hsl(1,2,3)", "blorp", "rgb(nan,0,0)", "foo(1,2,3)"] {
            XCTAssertNil(SprocketColor.parse(bad), "\(bad) should be invalid")
        }
    }

    func testInvalidColourDrawsNothing() {
        let b = draw(##"{"type":"solid","color":"nonsense"}"##)
        assertPx(b, 100, 100, black)
    }

    // MARK: context / background

    func testSolidGreyRoundTrips() {
        let b = draw(##"{"type":"solid","color":"#808080"}"##)
        assertPx(b, 10, 10, RGBA(r: 128, g: 128, b: 128, a: 255), tol: 1)
        assertPx(b, 190, 190, RGBA(r: 128, g: 128, b: 128, a: 255), tol: 1)
    }

    func testBackgroundAndOpaqueOutput() {
        let b = draw(##"{"type":"group","children":[]}"##, bg: "#336699")
        assertPx(b, 5, 5, RGBA(r: 0x33, g: 0x66, b: 0x99, a: 255), tol: 1)
        let t = draw(##"{"type":"group","children":[]}"##, bg: "rgba(255,255,255,0.5)")
        XCTAssertEqual(t.px(5, 5).a, 255)
        assertPx(t, 5, 5, RGBA(r: 128, g: 128, b: 128, a: 255), tol: 2)
        let none = draw(##"{"type":"group"}"##)
        assertPx(none, 5, 5, black)
    }

    func testVideoFramesPassThroughUnchanged() {
        let colour = CIColor(red: 0.2, green: 0.5, blue: 0.8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        var res = TestResources()
        res.videos["v"] = solidImage(colour, CGRect(x: 0, y: 0, width: 200, height: 200))
        let b = draw(##"{"type":"video","src":"v","time":0}"##, res: res)
        assertPx(b, 100, 100, RGBA(r: 51, g: 128, b: 204, a: 255), tol: 1)
    }

    // MARK: shapes and coordinates

    func testRectTopLeftLandsTopLeft() {
        let b = draw(##"{"type":"rect","x":0,"y":0,"width":50,"height":50,"color":"#ff0000"}"##)
        assertPx(b, 25, 25, red)
        assertPx(b, 25, 175, black)     // bottom-left stays background
        assertPx(b, 175, 25, black)
        assertPx(b, 75, 25, black)
        assertPx(b, 25, 75, black)
    }

    func testRectBottomRight() {
        let b = draw(##"{"type":"rect","x":150,"y":150,"width":50,"height":50,"color":"#00ff00"}"##)
        assertPx(b, 175, 175, green)
        assertPx(b, 25, 25, black)
    }

    func testRectRadiusAndStroke() {
        let b = draw(##"{"type":"rect","x":20,"y":20,"width":100,"height":100,"radius":40,"color":"#ffffff"}"##)
        assertPx(b, 70, 70, white)
        assertPx(b, 21, 21, black)      // rounded corner is empty
        assertPx(b, 70, 21, white)
        let s = draw(##"{"type":"rect","x":50,"y":50,"width":100,"height":100,"stroke":"#ff0000","strokeWidth":10}"##)
        assertPx(s, 100, 100, black)    // no fill
        assertPx(s, 100, 50, red)       // on the edge
        assertPx(s, 100, 46, red)       // stroke is centred on the edge
        assertPx(s, 100, 53, red)
        assertPx(s, 100, 70, black)
    }

    func testEllipse() {
        let b = draw(##"{"type":"ellipse","x":20,"y":20,"width":160,"height":100,"color":"#0000ff"}"##)
        assertPx(b, 100, 70, blue)
        assertPx(b, 22, 22, black)
        assertPx(b, 100, 130, black)
        assertPx(b, 100, 25, blue)
    }

    func testPathFillAndStroke() {
        let tri = draw(##"{"type":"path","d":"M 100 20 L 180 180 L 20 180 Z","color":"#ff0000"}"##)
        assertPx(tri, 100, 120, red)
        assertPx(tri, 100, 190, black)
        assertPx(tri, 25, 40, black)
        // relative commands, H V, closed square
        let sq = draw(##"{"type":"path","d":"m 50 50 h 100 v 100 h -100 z","color":"#00ff00"}"##)
        assertPx(sq, 100, 100, green)
        assertPx(sq, 40, 40, black)
        assertPx(sq, 160, 160, black)
        // stroke only
        let line = draw(##"{"type":"path","d":"M 20 100 L 180 100","stroke":"#ffffff","strokeWidth":10}"##)
        assertPx(line, 100, 100, white)
        assertPx(line, 100, 120, black)
        assertPx(line, 100, 80, black)
    }

    func testPathCurvesAndArcs() {
        // cubic, smooth cubic, quad, smooth quad; each must produce ink and must not crash.
        for d in ["M 20 100 C 20 20 100 20 100 100 S 180 180 180 100 Z",
                  "M 20 100 Q 100 0 180 100 T 180 180 L 20 180 Z",
                  "M 20 100 c 0 -80 80 -80 80 0 s 80 80 80 0 z",
                  "M 20 100 q 80 -100 160 0 t 0 80 z"] {
            let b = draw("{\"type\":\"path\",\"d\":\"\(d)\",\"color\":\"#ffffff\"}")
            var ink = 0
            for y in stride(from: 0, to: 200, by: 4) { for x in stride(from: 0, to: 200, by: 4) where b.px(x, y).r > 128 { ink += 1 } }
            XCTAssertGreaterThan(ink, 20, d)
        }
        // semicircle by arc: from (20,100) to (180,100), radius 80, sweep through the top (sweep flag 1 = clockwise on screen)
        let half = draw(##"{"type":"path","d":"M 20 100 A 80 80 0 0 1 180 100 Z","color":"#ffffff"}"##)
        assertPx(half, 100, 60, white)      // inside the upper half disc
        assertPx(half, 100, 140, black)     // lower half empty
        let low = draw(##"{"type":"path","d":"M 20 100 A 80 80 0 0 0 180 100 Z","color":"#ffffff"}"##)
        assertPx(low, 100, 140, white)
        assertPx(low, 100, 60, black)
        // compact arc flags ("a1 1 0 00-2 0") and radius too small get scaled up rather than failing
        let small = draw(##"{"type":"path","d":"M 20 100 A 10 10 0 0 1 180 100 Z","color":"#ffffff"}"##)
        assertPx(small, 100, 60, white)
        let compact = draw(##"{"type":"path","d":"M50 100a50 50 0 1 1 100 0a50 50 0 1 1-100 0z","color":"#ffffff"}"##)
        assertPx(compact, 100, 100, white)
    }

    func testGradientLinearEndpoints() {
        let b = draw(##"{"type":"gradient","kind":"linear","from":{"x":0,"y":0},"to":{"x":200,"y":0},"stops":[{"at":0,"color":"#ff0000"},{"at":1,"color":"#0000ff"}]}"##)
        assertPx(b, 0, 100, red, tol: 4)
        assertPx(b, 199, 100, blue, tol: 4)
        assertPx(b, 100, 100, RGBA(r: 128, g: 0, b: 128, a: 255), tol: 4)
        assertPx(b, 100, 0, b.px(100, 199), tol: 1)   // constant along y
    }

    func testGradientMultiStopVerticalAndBox() {
        let b = draw(##"{"type":"gradient","from":{"x":0,"y":0},"to":{"x":0,"y":200},"stops":[{"at":0,"color":"#ff0000"},{"at":0.5,"color":"#00ff00"},{"at":1,"color":"#0000ff"}]}"##)
        assertPx(b, 100, 1, red, tol: 6)
        assertPx(b, 100, 100, green, tol: 6)
        assertPx(b, 100, 198, blue, tol: 6)
        // box: only inside the box
        let box = draw(##"{"type":"gradient","x":50,"y":50,"width":100,"height":100,"from":{"x":50,"y":50},"to":{"x":150,"y":50},"stops":[{"at":0,"color":"#ffffff"},{"at":1,"color":"#ffffff"}]}"##)
        assertPx(box, 100, 100, white)
        assertPx(box, 25, 100, black)
        assertPx(box, 100, 175, black)
    }

    func testGradientRadial() {
        let b = draw(##"{"type":"gradient","kind":"radial","from":{"x":100,"y":100},"to":{"x":180,"y":100},"stops":[{"at":0,"color":"#ffffff"},{"at":1,"color":"#000000"}]}"##)
        assertPx(b, 100, 100, white, tol: 6)
        assertPx(b, 100, 190, black, tol: 2)
        XCTAssertGreaterThan(b.px(120, 100).luma, b.px(160, 100).luma)
    }

    // MARK: media

    func fitScene(_ fit: String, extra: String = "", w: Int = 200, h: Int = 100) -> Bitmap {
        var res = TestResources()
        res.images["pic"] = halfRedBlue(w, h)
        // 100x100 box at the top-left of a 200x200 canvas, picture is 200x100 (wider)
        return draw("{\"type\":\"image\",\"src\":\"pic\",\"x\":0,\"y\":0,\"width\":100,\"height\":100,\"fit\":\"\(fit)\"\(extra)}", res: res)
    }

    func testFitCoverCentered() {
        let b = fitScene("cover")
        assertPx(b, 10, 50, red, tol: 3)
        assertPx(b, 90, 50, blue, tol: 3)
        assertPx(b, 10, 5, red, tol: 3)       // fills the full box height
        assertPx(b, 10, 95, red, tol: 3)
        assertPx(b, 150, 50, black)           // outside the box
        assertPx(b, 50, 150, black)
    }

    func testFitCoverFocus() {
        let left = fitScene("cover", extra: ",\"focusX\":0")
        assertPx(left, 10, 50, red, tol: 3)
        assertPx(left, 90, 50, red, tol: 3)
        let right = fitScene("cover", extra: ",\"focusX\":1")
        assertPx(right, 10, 50, blue, tol: 3)
        assertPx(right, 90, 50, blue, tol: 3)
    }

    func testFitCoverFocusY() {
        var res = TestResources()
        res.images["tall"] = topRedBottomBlue(100, 200)   // 100x200 picture, top half red
        // 100x100 box: cover crops vertically. focusY 0 keeps the top (red); 1 keeps the bottom (blue).
        let top = draw(##"{"type":"image","src":"tall","x":0,"y":0,"width":100,"height":100,"focusY":0}"##, res: res)
        assertPx(top, 50, 20, red, tol: 3); assertPx(top, 50, 80, red, tol: 3)
        let bottom = draw(##"{"type":"image","src":"tall","x":0,"y":0,"width":100,"height":100,"focusY":1}"##, res: res)
        assertPx(bottom, 50, 20, blue, tol: 3); assertPx(bottom, 50, 80, blue, tol: 3)
        let mid = draw(##"{"type":"image","src":"tall","x":0,"y":0,"width":100,"height":100}"##, res: res)
        assertPx(mid, 50, 20, red, tol: 3); assertPx(mid, 50, 80, blue, tol: 3)
    }

    func testFitContain() {
        let b = fitScene("contain")
        // 200x100 into 100x100 -> 100x50, centred vertically: rows 25..75
        assertPx(b, 10, 50, red, tol: 3)
        assertPx(b, 90, 50, blue, tol: 3)
        assertPx(b, 10, 10, black)
        assertPx(b, 90, 90, black)
    }

    func testFitFill() {
        let b = fitScene("fill")
        assertPx(b, 10, 5, red, tol: 3)
        assertPx(b, 10, 95, red, tol: 3)
        assertPx(b, 90, 5, blue, tol: 3)
        assertPx(b, 90, 95, blue, tol: 3)
    }

    func testImageDefaultBoxIsCanvasAndUprightOrientation() {
        var res = TestResources()
        res.images["tall"] = topRedBottomBlue(200, 200)
        let b = draw(##"{"type":"image","src":"tall"}"##, res: res)
        assertPx(b, 100, 20, red, tol: 2)      // the picture's top stays on top
        assertPx(b, 100, 180, blue, tol: 2)
    }

    func testMissingAssetDrawsNothing() {
        let b = draw(group(##"{"type":"video","src":"nope","time":1}"##, ##"{"type":"image","src":"nope"}"##, ##"{"type":"image"}"##))
        assertPx(b, 100, 100, black)
    }

    // MARK: common props

    func testOpacity() {
        let b = draw(##"{"type":"solid","color":"#ffffff","opacity":0.5}"##)
        assertPx(b, 100, 100, RGBA(r: 128, g: 128, b: 128, a: 255), tol: 2)
        let zero = draw(##"{"type":"solid","color":"#ffffff","opacity":0}"##)
        assertPx(zero, 100, 100, black)
        let over = draw(group(##"{"type":"solid","color":"#ff0000"}"##, ##"{"type":"solid","color":"#0000ff","opacity":0.25}"##))
        assertPx(over, 100, 100, RGBA(r: 191, g: 0, b: 64, a: 255), tol: 2)
    }

    func testBlendModes() {
        func blended(_ below: String, _ above: String, _ mode: String) -> Bitmap {
            draw(group("{\"type\":\"solid\",\"color\":\"\(below)\"}", "{\"type\":\"solid\",\"color\":\"\(above)\",\"blend\":\"\(mode)\"}"))
        }
        // multiply: 0.5 * 0.5 = 0.25 -> 64
        assertPx(blended("#808080", "#808080", "multiply"), 50, 50, RGBA(r: 64, g: 64, b: 64, a: 255), tol: 2)
        assertPx(blended("#ff0000", "#00ff00", "multiply"), 50, 50, black)
        assertPx(blended("#ff8040", "#ffffff", "multiply"), 50, 50, RGBA(r: 255, g: 128, b: 64, a: 255), tol: 2)
        // screen: 1 - 0.5*0.5 = 0.75 -> 191
        assertPx(blended("#808080", "#808080", "screen"), 50, 50, RGBA(r: 191, g: 191, b: 191, a: 255), tol: 2)
        assertPx(blended("#ff0000", "#00ff00", "screen"), 50, 50, RGBA(r: 255, g: 255, b: 0, a: 255))
        // add
        assertPx(blended("#400000", "#002000", "add"), 50, 50, RGBA(r: 64, g: 32, b: 0, a: 255), tol: 2)
        assertPx(blended("#c0c0c0", "#c0c0c0", "add"), 50, 50, white)
        // darken / lighten / difference
        assertPx(blended("#ff8000", "#80ff00", "darken"), 50, 50, RGBA(r: 128, g: 128, b: 0, a: 255), tol: 2)
        assertPx(blended("#ff8000", "#80ff00", "lighten"), 50, 50, RGBA(r: 255, g: 255, b: 0, a: 255), tol: 2)
        assertPx(blended("#ffffff", "#404040", "difference"), 50, 50, RGBA(r: 191, g: 191, b: 191, a: 255), tol: 2)
        // overlay / softLight / hardLight on mid grey stay sensible
        assertPx(blended("#808080", "#808080", "overlay"), 50, 50, RGBA(r: 128, g: 128, b: 128, a: 255), tol: 3)
        assertPx(blended("#808080", "#808080", "softLight"), 50, 50, RGBA(r: 128, g: 128, b: 128, a: 255), tol: 3)
        assertPx(blended("#808080", "#808080", "hardLight"), 50, 50, RGBA(r: 128, g: 128, b: 128, a: 255), tol: 3)
        XCTAssertGreaterThan(blended("#808080", "#c0c0c0", "overlay").px(50, 50).r, 160)
        XCTAssertLessThan(blended("#808080", "#404040", "hardLight").px(50, 50).r, 100)
        // unknown blend is normal
        assertPx(blended("#ff0000", "#00ff00", "bogus"), 50, 50, green)
    }

    func testBlendOnlyWhereLayerExists() {
        let b = draw(group(##"{"type":"solid","color":"#808080"}"##, ##"{"type":"rect","x":0,"y":0,"width":100,"height":100,"color":"#ffffff","blend":"multiply"}"##))
        assertPx(b, 50, 50, RGBA(r: 128, g: 128, b: 128, a: 255), tol: 2)
        assertPx(b, 150, 150, RGBA(r: 128, g: 128, b: 128, a: 255), tol: 2)
    }

    func testTransformTranslate() {
        let b = draw(##"{"type":"rect","x":0,"y":0,"width":50,"height":50,"color":"#ff0000","transform":{"translateX":100,"translateY":60}}"##)
        assertPx(b, 125, 85, red)
        assertPx(b, 25, 25, black)
        assertPx(b, 25, 85, black)
    }

    func testTransformScaleAboutCentre() {
        // a rect around the centre scaled 2x grows symmetrically about (100,100)
        let b = draw(##"{"type":"rect","x":75,"y":75,"width":50,"height":50,"color":"#ffffff","transform":{"scale":2}}"##)
        assertPx(b, 55, 100, white); assertPx(b, 145, 100, white)
        assertPx(b, 100, 55, white); assertPx(b, 100, 145, white)
        assertPx(b, 45, 100, black); assertPx(b, 155, 100, black)
        // explicit origin: scale about the top-left corner of the rect
        let o = draw(##"{"type":"rect","x":50,"y":50,"width":20,"height":20,"color":"#ffffff","transform":{"scale":3,"originX":50,"originY":50}}"##)
        assertPx(o, 100, 100, white)
        assertPx(o, 120, 120, black)
        assertPx(o, 45, 45, black)
        // non uniform
        let nu = draw(##"{"type":"rect","x":90,"y":90,"width":20,"height":20,"color":"#ffffff","transform":{"scaleX":4,"scaleY":1}}"##)
        assertPx(nu, 66, 100, white); assertPx(nu, 100, 60, black)
    }

    func testTransformRotateClockwise() {
        // a bar to the right of centre; rotating 90 degrees clockwise on screen puts it below the centre
        let bar = ##"{"type":"rect","x":120,"y":90,"width":60,"height":20,"color":"#ffffff","transform":{"rotate":90}}"##
        let b = draw(bar)
        assertPx(b, 100, 150, white)
        assertPx(b, 150, 100, black)
        assertPx(b, 100, 50, black)
        let ccw = draw(bar.replacingOccurrences(of: "\"rotate\":90", with: "\"rotate\":-90"))
        assertPx(ccw, 100, 50, white)
        assertPx(ccw, 100, 150, black)
        let half = draw(bar.replacingOccurrences(of: "\"rotate\":90", with: "\"rotate\":180"))
        assertPx(half, 50, 100, white)
    }

    func testTransformOrderScaleRotateTranslate() {
        // rect at the centre-right; scale 1 + rotate 90 + translate 50,0 -> below centre, shifted right by 50
        let b = draw(##"{"type":"rect","x":120,"y":90,"width":60,"height":20,"color":"#ffffff","transform":{"rotate":90,"translateX":50}}"##)
        assertPx(b, 150, 150, white)
        assertPx(b, 100, 150, black)
    }

    func testClipWithRadius() {
        let b = draw(##"{"type":"solid","color":"#ffffff","clip":{"x":50,"y":50,"width":100,"height":100,"radius":30}}"##)
        assertPx(b, 100, 100, white)
        assertPx(b, 100, 52, white)
        assertPx(b, 52, 52, black)           // clipped by the corner radius
        assertPx(b, 20, 100, black)
        assertPx(b, 100, 170, black)
        let sq = draw(##"{"type":"solid","color":"#ffffff","clip":{"x":50,"y":50,"width":100,"height":100}}"##)
        assertPx(sq, 52, 52, white)
        assertPx(sq, 40, 40, black)
    }

    func testClipAppliesAfterTransform() {
        let b = draw(##"{"type":"solid","color":"#ffffff","transform":{"translateX":100},"clip":{"x":0,"y":0,"width":200,"height":100}}"##)
        assertPx(b, 150, 50, white)
        assertPx(b, 50, 50, black)    // moved away
        assertPx(b, 150, 150, black)  // outside the clip
    }

    func testMaskAlpha() {
        let b = draw(##"{"type":"solid","color":"#ff0000","mask":[{"type":"rect","x":0,"y":0,"width":100,"height":200,"color":"#000000"}]}"##)
        assertPx(b, 50, 100, red)         // black but opaque shows
        assertPx(b, 150, 100, black)
        let half = draw(##"{"type":"solid","color":"#ffffff","mask":[{"type":"solid","color":"#ffffff","opacity":0.5}]}"##)
        assertPx(half, 100, 100, RGBA(r: 128, g: 128, b: 128, a: 255), tol: 2)
    }

    func testMaskLuma() {
        let mask = ##"[{"type":"rect","x":0,"y":0,"width":100,"height":200,"color":"#ffffff"},{"type":"rect","x":100,"y":0,"width":50,"height":200,"color":"#808080"}]"##
        let b = draw("{\"type\":\"solid\",\"color\":\"#ff0000\",\"maskMode\":\"luma\",\"mask\":\(mask)}")
        assertPx(b, 50, 100, red)
        assertPx(b, 125, 100, RGBA(r: 128, g: 0, b: 0, a: 255), tol: 6)     // luma 0.5 -> half strength (blend happens in sRGB space)
        assertPx(b, 175, 100, black)      // nothing there = black = hidden
        // black opaque hides in luma mode but shows in alpha mode
        let blackMask = ##"[{"type":"solid","color":"#000000"}]"##
        assertPx(draw("{\"type\":\"solid\",\"color\":\"#ff0000\",\"maskMode\":\"luma\",\"mask\":\(blackMask)}"), 100, 100, black)
        assertPx(draw("{\"type\":\"solid\",\"color\":\"#ff0000\",\"mask\":\(blackMask)}"), 100, 100, red)
    }

    func testMaskIsRenderedOnItsOwnTransparentCanvas() {
        // a background-coloured canvas must not leak into the mask
        let b = draw(##"{"type":"solid","color":"#ff0000","mask":[{"type":"ellipse","x":50,"y":50,"width":100,"height":100,"color":"#fff"}]}"##, bg: "#0000ff")
        assertPx(b, 100, 100, red)
        assertPx(b, 10, 10, blue)
    }

    func testNestedGroups() {
        let inner = group(##"{"type":"rect","x":0,"y":0,"width":100,"height":100,"color":"#ff0000"}"##, props: ##""opacity":0.5"##)
        let outer = group(inner, ##"{"type":"rect","x":100,"y":100,"width":100,"height":100,"color":"#00ff00"}"##,
                          props: ##""transform":{"translateX":0,"translateY":0}"##)
        let b = draw(outer)
        assertPx(b, 50, 50, RGBA(r: 128, g: 0, b: 0, a: 255), tol: 2)
        assertPx(b, 150, 150, green)
        // group props apply to the flattened result: two overlapping opaque rects at 50% -> still 50% (not compounded)
        let g = draw(group(##"{"type":"rect","x":0,"y":0,"width":120,"height":120,"color":"#ffffff"}"##,
                           ##"{"type":"rect","x":60,"y":60,"width":120,"height":120,"color":"#ffffff"}"##, props: ##""opacity":0.5"##))
        assertPx(g, 90, 90, RGBA(r: 128, g: 128, b: 128, a: 255), tol: 2)
        // a group translated moves all children; a group clip clips all children
        let moved = draw(group(##"{"type":"rect","x":0,"y":0,"width":20,"height":20,"color":"#fff"}"##, props: ##""transform":{"translateX":100,"translateY":100}"##))
        assertPx(moved, 110, 110, white)
        assertPx(moved, 10, 10, black)
        let clipped = draw(group(##"{"type":"solid","color":"#fff"}"##, props: ##""clip":{"x":0,"y":0,"width":50,"height":50}"##))
        assertPx(clipped, 25, 25, white)
        assertPx(clipped, 75, 75, black)
    }

    func testBlendInsideGroupIsIsolated() {
        // a multiply child inside a group multiplies against siblings in that group, not the canvas behind the group
        let g = group(##"{"type":"rect","x":0,"y":0,"width":100,"height":100,"color":"#ffffff"}"##,
                      ##"{"type":"rect","x":0,"y":0,"width":100,"height":100,"color":"#808080","opacity":0.99,"blend":"multiply"}"##)
        let b = draw(group(##"{"type":"solid","color":"#ff0000"}"##, g))
        assertPx(b, 50, 50, RGBA(r: 128, g: 128, b: 128, a: 255), tol: 4)
        assertPx(b, 150, 150, red)
    }

    // MARK: effects

    func baseScene(_ effect: String, _ extra: String = "") -> String {
        // white square on mid-grey with a coloured strip, full canvas group + effect
        group(##"{"type":"solid","color":"#404040"}"##, ##"{"type":"rect","x":70,"y":70,"width":60,"height":60,"color":"#ffffff"}"##,
              props: "\"effects\":[{\"name\":\"\(effect)\"\(extra)}]")
    }

    func testBlurSoftensAndKeepsEdgesOpaque() {
        let plain = draw(baseScene("none"))
        let blur = draw(baseScene("blur", ",\"radius\":8"))
        XCTAssertGreaterThan(plain.px(70, 100).luma, blur.px(66, 100).luma + 0) // sanity
        XCTAssertGreaterThan(blur.px(66, 100).luma, plain.px(66, 100).luma + 5)   // light spreads outward
        XCTAssertLessThan(blur.px(76, 100).luma, plain.px(76, 100).luma - 5)      // and eats the inside edge
        for p in [(0, 0), (199, 0), (0, 199), (199, 199), (100, 0), (0, 100), (199, 100), (100, 199)] {
            let v = blur.px(p.0, p.1)
            XCTAssertEqual(v.a, 255, "alpha at \(p)")
            XCTAssertEqual(Double(v.r), 64, accuracy: 3, "border colour at \(p)")
        }
        // full-canvas white layer must stay white at the borders
        let w = draw(##"{"type":"solid","color":"#ffffff","effects":[{"name":"blur","radius":30}]}"##)
        assertPx(w, 0, 0, white); assertPx(w, 199, 199, white); assertPx(w, 0, 199, white)
    }

    func testMotionBlurDirectional() {
        let h = draw(baseScene("motionBlur", ",\"radius\":20,\"angle\":0"))
        // horizontal blur smears left/right of the square but leaves rows above untouched
        XCTAssertGreaterThan(h.px(60, 100).luma, 80)
        XCTAssertEqual(Double(h.px(100, 60).r), 64, accuracy: 4)
        let v = draw(baseScene("motionBlur", ",\"radius\":20,\"angle\":90"))
        XCTAssertGreaterThan(v.px(100, 60).luma, 80)
        XCTAssertEqual(Double(v.px(60, 100).r), 64, accuracy: 4)
    }

    func testZoomBlur() {
        let stripes = group(##"{"type":"rect","x":0,"y":0,"width":200,"height":20,"color":"#fff"}"##, ##"{"type":"rect","x":0,"y":40,"width":200,"height":20,"color":"#fff"}"##,
                            props: ##""effects":[{"name":"zoomBlur","amount":30}]"##)
        let plain = draw(group(##"{"type":"rect","x":0,"y":0,"width":200,"height":20,"color":"#fff"}"##, ##"{"type":"rect","x":0,"y":40,"width":200,"height":20,"color":"#fff"}"##))
        let z = draw(stripes)
        XCTAssertNotEqual(plain.px(100, 30).luma, z.px(100, 30).luma, accuracy: 3)
        XCTAssertEqual(z.px(100, 100).luma, plain.px(100, 100).luma, accuracy: 6)   // centre barely changes
    }

    func testColourEffectsDirection() {
        let plain = draw(group(##"{"type":"solid","color":"#806040"}"##))
        func fx(_ name: String, _ extra: String) -> RGBA {
            draw(group(##"{"type":"solid","color":"#806040"}"##, props: "\"effects\":[{\"name\":\"\(name)\"\(extra)}]")).px(50, 50)
        }
        let base = plain.px(50, 50)
        XCTAssertGreaterThan(fx("brightness", ",\"amount\":0.2").r, base.r + 20)
        XCTAssertLessThan(fx("brightness", ",\"amount\":-0.2").r, base.r - 20)
        XCTAssertGreaterThan(fx("contrast", ",\"amount\":2").r, base.r)       // above mid goes up
        XCTAssertLessThan(fx("contrast", ",\"amount\":2").b, base.b)          // below mid goes down
        XCTAssertEqual(fx("contrast", ",\"amount\":1").r, base.r, accuracy: 1)
        let desat = fx("saturation", ",\"amount\":0")
        XCTAssertEqual(desat.r, desat.b, accuracy: 2)
        let sat = fx("saturation", ",\"amount\":2")
        XCTAssertGreaterThan(sat.r - sat.b, base.r - base.b)
        XCTAssertGreaterThan(fx("exposure", ",\"amount\":1").r, base.r + 20)
        XCTAssertLessThan(fx("exposure", ",\"amount\":-1").r, base.r - 20)
        let hue = fx("hue", ",\"angle\":120")
        XCTAssertNotEqual(hue, base)
        XCTAssertGreaterThan(hue.g, hue.r)    // orange-ish moved toward green
        let inv = fx("invert", "")
        XCTAssertEqual(inv.r, 255 - base.r, accuracy: 2); XCTAssertEqual(inv.b, 255 - base.b, accuracy: 2)
        let sep = fx("sepia", ",\"amount\":1")
        XCTAssertGreaterThan(sep.r, sep.b)
        let gray = fx("grayscale", ",\"amount\":1")
        XCTAssertEqual(gray.r, gray.g, accuracy: 2); XCTAssertEqual(gray.g, gray.b, accuracy: 2)
        let halfGray = fx("grayscale", ",\"amount\":0.5")
        XCTAssertLessThan(abs(halfGray.r - halfGray.b), abs(base.r - base.b))
        XCTAssertGreaterThan(abs(halfGray.r - halfGray.b), 0)
    }

    func testVignette() {
        let b = draw(group(##"{"type":"solid","color":"#ffffff"}"##, props: ##""effects":[{"name":"vignette","amount":1,"radius":1}]"##))
        XCTAssertGreaterThan(b.px(100, 100).luma, 240)
        XCTAssertLessThan(b.px(2, 2).luma, b.px(100, 100).luma - 60)
        XCTAssertEqual(b.px(2, 2).a, 255)
        let strong = draw(group(##"{"type":"solid","color":"#ffffff"}"##, props: ##""effects":[{"name":"vignette","amount":2,"radius":1}]"##))
        XCTAssertLessThanOrEqual(strong.px(2, 2).luma, b.px(2, 2).luma)
    }

    func testPixellate() {
        let src = ##"{"type":"rect","x":0,"y":0,"width":15,"height":200,"color":"#fff"}"##
        let plain = draw(group(src))
        let b = draw(group(src, props: ##""effects":[{"name":"pixellate","radius":20}]"##))
        // unpixellated: a hard edge at x=15; pixellated: one flat block across x 0..19
        XCTAssertNotEqual(plain.px(2, 50), plain.px(18, 50))
        XCTAssertEqual(b.px(2, 50), b.px(18, 50))
        XCTAssertEqual(b.px(2, 50), b.px(2, 190))
        XCTAssertEqual(b.px(2, 50), b.px(8, 55))
        XCTAssertNotEqual(b.px(2, 50), b.px(22, 50).luma == b.px(2, 50).luma ? RGBA(r: -1, g: 0, b: 0, a: 0) : b.px(22, 50))
    }

    func testSharpenIncreasesEdgeContrast() {
        let scene = group(##"{"type":"rect","x":0,"y":0,"width":100,"height":200,"color":"#606060"}"##,
                          ##"{"type":"rect","x":100,"y":0,"width":100,"height":200,"color":"#a0a0a0"}"##)
        let soft = draw(group(scene, props: ##""effects":[{"name":"blur","radius":3}]"##))
        let sharp = draw(group(scene, props: ##""effects":[{"name":"blur","radius":3},{"name":"sharpen","amount":2}]"##))
        XCTAssertGreaterThan(sharp.px(103, 100).luma - sharp.px(96, 100).luma, soft.px(103, 100).luma - soft.px(96, 100).luma)
    }

    func testGlowAddsLightAroundBrightShapes() {
        let plain = draw(baseScene("none"))
        let glow = draw(baseScene("glow", ",\"radius\":15,\"amount\":1"))
        XCTAssertGreaterThan(glow.px(62, 100).luma, plain.px(62, 100).luma + 10)
        XCTAssertGreaterThanOrEqual(glow.px(100, 100).luma, plain.px(100, 100).luma - 1)
        XCTAssertEqual(glow.px(5, 5).luma, plain.px(5, 5).luma, accuracy: 8)   // far corner stays
        XCTAssertEqual(glow.px(100, 100).a, 255)
    }

    func testGrainDeterministicAndSeeded() {
        let scene = { (seed: Int) in draw(group(##"{"type":"solid","color":"#808080"}"##, props: "\"effects\":[{\"name\":\"grain\",\"amount\":0.8,\"seed\":\(seed)}]")) }
        let a = scene(1), a2 = scene(1), c = scene(2)
        XCTAssertEqual(a.data, a2.data, "same seed, same pixels")
        XCTAssertNotEqual(a.data, c.data, "different seed, different pixels")
        var sum = 0.0, sq = 0.0
        for y in 0..<200 { for x in 0..<200 { let l = a.px(x, y).luma; sum += l; sq += l * l } }
        let mean = sum / 40000, sd = (sq / 40000 - mean * mean).squareRoot()
        XCTAssertGreaterThan(sd, 5, "grain has visible variance")
        XCTAssertEqual(mean, 128, accuracy: 20)
        let none = draw(group(##"{"type":"solid","color":"#808080"}"##, props: ##""effects":[{"name":"grain","amount":0}]"##))
        assertPx(none, 50, 50, RGBA(r: 128, g: 128, b: 128, a: 255), tol: 1)
    }

    func testRgbSplitOffsetsRedAndBlueOppositely() {
        let scene = group(##"{"type":"solid","color":"#000000"}"##, ##"{"type":"rect","x":80,"y":80,"width":40,"height":40,"color":"#ffffff"}"##,
                          props: ##""effects":[{"name":"rgbSplit","amount":10,"angle":0}]"##)
        let b = draw(scene)
        // red moves right (+10), blue moves left (-10): to the right of the square only red remains, to the left only blue
        let right = b.px(125, 100), left = b.px(75, 100)
        XCTAssertGreaterThan(right.r, 200); XCTAssertLessThan(right.b, 40); XCTAssertLessThan(right.g, 40)
        XCTAssertGreaterThan(left.b, 200); XCTAssertLessThan(left.r, 40); XCTAssertLessThan(left.g, 40)
        assertPx(b, 100, 100, white)
        assertPx(b, 5, 5, black)
        // vertical split: angle 90 is down on screen -> red below, blue above
        let v = draw(scene.replacingOccurrences(of: "\"angle\":0", with: "\"angle\":90"))
        XCTAssertGreaterThan(v.px(100, 125).r, 200); XCTAssertLessThan(v.px(100, 125).b, 40)
        XCTAssertGreaterThan(v.px(100, 75).b, 200); XCTAssertLessThan(v.px(100, 75).r, 40)
    }

    func testTintAndColorMatrix() {
        let t = draw(group(##"{"type":"solid","color":"#000000"}"##, props: ##""effects":[{"name":"tint","color":"#ff0000","amount":0.5}]"##))
        assertPx(t, 50, 50, RGBA(r: 128, g: 0, b: 0, a: 255), tol: 3)
        let full = draw(group(##"{"type":"solid","color":"#336699"}"##, props: ##""effects":[{"name":"tint","color":"#00ff00","amount":1}]"##))
        assertPx(full, 50, 50, green, tol: 2)
        // swap R and B
        let swap = draw(group(##"{"type":"solid","color":"#ff8000"}"##, props: ##""effects":[{"name":"colorMatrix","matrix":[0,0,1,0,0, 0,1,0,0,0, 1,0,0,0,0, 0,0,0,1,0]}]"##))
        assertPx(swap, 50, 50, RGBA(r: 0, g: 128, b: 255, a: 255), tol: 2)
        // bias
        let bias = draw(group(##"{"type":"solid","color":"#000000"}"##, props: ##""effects":[{"name":"colorMatrix","matrix":[1,0,0,0,0.5, 0,1,0,0,0, 0,0,1,0,0, 0,0,0,1,0]}]"##))
        assertPx(bias, 50, 50, RGBA(r: 128, g: 0, b: 0, a: 255), tol: 2)
        // wrong length is ignored
        let bad = draw(group(##"{"type":"solid","color":"#ff8000"}"##, props: ##""effects":[{"name":"colorMatrix","matrix":[1,2,3]}]"##))
        assertPx(bad, 50, 50, RGBA(r: 255, g: 128, b: 0, a: 255), tol: 2)
    }

    func testEffectsApplyInOrder() {
        let a = draw(group(##"{"type":"solid","color":"#808080"}"##, props: ##""effects":[{"name":"brightness","amount":0.3},{"name":"invert"}]"##)).px(10, 10)
        let b = draw(group(##"{"type":"solid","color":"#808080"}"##, props: ##""effects":[{"name":"invert"},{"name":"brightness","amount":0.3}]"##)).px(10, 10)
        XCTAssertLessThan(a.r, 128)
        XCTAssertGreaterThan(b.r, 128)
    }

    func testUnknownEffectIgnored() {
        let b = draw(group(##"{"type":"solid","color":"#808080"}"##, props: ##""effects":[{"name":"warpDrive"}]"##))
        assertPx(b, 50, 50, RGBA(r: 128, g: 128, b: 128, a: 255), tol: 1)
    }

    // MARK: text

    func inkBounds(_ b: Bitmap, bg: RGBA = RGBA(r: 0, g: 0, b: 0, a: 255)) -> CGRect? {
        var minX = b.w, minY = b.h, maxX = -1, maxY = -1
        for y in 0..<b.h { for x in 0..<b.w {
            let p = b.px(x, y)
            if abs(p.r - bg.r) + abs(p.g - bg.g) + abs(p.b - bg.b) > 30 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        } }
        return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func testTextInsideItsBoxOnly() {
        let b = draw(##"{"type":"text","text":"HELLO","x":100,"y":150,"width":400,"size":80,"weight":800,"color":"#ffffff","align":"left"}"##, w: 600, h: 400)
        guard let ink = inkBounds(b) else { return XCTFail("text drew nothing") }
        XCTAssertGreaterThanOrEqual(ink.minX, 95)
        XCTAssertLessThanOrEqual(ink.maxX, 500)
        XCTAssertGreaterThanOrEqual(ink.minY, 150 - 10)
        XCTAssertLessThanOrEqual(ink.maxY, 150 + 80 * 1.2 + 15)
        XCTAssertGreaterThan(ink.width, 120)
        XCTAssertGreaterThan(ink.height, 40)
        // nothing far outside
        assertPx(b, 20, 20, black); assertPx(b, 550, 350, black); assertPx(b, 300, 50, black)
    }

    func testTextAlign() {
        func ink(_ align: String) -> CGRect {
            let b = draw("{\"type\":\"text\",\"text\":\"Hi\",\"x\":100,\"y\":50,\"width\":400,\"size\":60,\"align\":\"\(align)\"}", w: 600, h: 200)
            return inkBounds(b) ?? .zero
        }
        let l = ink("left"), c = ink("center"), r = ink("right")
        XCTAssertLessThan(l.minX, 130)
        XCTAssertEqual(c.midX, 300, accuracy: 12)
        XCTAssertGreaterThan(r.maxX, 470)
        XCTAssertLessThanOrEqual(r.maxX, 505)
    }

    func testTextWrapsAndMultiLine() {
        let one = draw(##"{"type":"text","text":"alpha beta gamma delta","x":0,"y":10,"width":1000,"size":40,"align":"left"}"##, w: 400, h: 400)
        let wrapped = draw(##"{"type":"text","text":"alpha beta gamma delta","x":0,"y":10,"width":160,"size":40,"align":"left"}"##, w: 400, h: 400)
        let nl = draw("{\"type\":\"text\",\"text\":\"one\\ntwo\\nthree\",\"x\":0,\"y\":10,\"width\":300,\"size\":40,\"align\":\"left\"}", w: 400, h: 400)
        let h1 = inkBounds(one)!.height, h2 = inkBounds(wrapped)!.height, h3 = inkBounds(nl)!.height
        XCTAssertGreaterThan(h2, h1 * 1.8)
        XCTAssertGreaterThan(h3, h1 * 2)
        XCTAssertLessThanOrEqual(inkBounds(wrapped)!.maxX, 175)
        // lineHeight spreads lines
        let tight = draw("{\"type\":\"text\",\"text\":\"a\\nb\",\"y\":10,\"size\":40,\"lineHeight\":1}", w: 400, h: 400)
        let loose = draw("{\"type\":\"text\",\"text\":\"a\\nb\",\"y\":10,\"size\":40,\"lineHeight\":2}", w: 400, h: 400)
        XCTAssertGreaterThan(inkBounds(loose)!.height, inkBounds(tight)!.height + 20)
    }

    func testTextStyleOptions() {
        let plain = draw(##"{"type":"text","text":"WIDE","y":50,"size":60,"align":"left"}"##, w: 600, h: 200)
        let spaced = draw(##"{"type":"text","text":"WIDE","y":50,"size":60,"align":"left","letterSpacing":20}"##, w: 600, h: 200)
        XCTAssertGreaterThan(inkBounds(spaced)!.width, inkBounds(plain)!.width + 40)
        let small = draw(##"{"type":"text","text":"WIDE","y":50,"size":30,"align":"left"}"##, w: 600, h: 200)
        XCTAssertLessThan(inkBounds(small)!.width, inkBounds(plain)!.width * 0.7)
        // colour
        let red = draw(##"{"type":"text","text":"MMMM","y":40,"size":100,"color":"#ff0000","weight":900}"##, w: 600, h: 200)
        var found = false
        for y in 0..<200 { for x in 0..<600 where red.px(x, y).near(self.red, 3) { found = true } }
        XCTAssertTrue(found)
        // stroke adds ink around the glyphs in a different colour
        let stroked = draw(##"{"type":"text","text":"I","y":40,"size":100,"color":"#ffffff","stroke":"#ff0000","strokeWidth":8}"##, w: 300, h: 200)
        var strokePx = 0
        for y in 0..<200 { for x in 0..<300 { let p = stroked.px(x, y); if p.r > 150 && p.g < 80 && p.b < 80 { strokePx += 1 } } }
        XCTAssertGreaterThan(strokePx, 50)
        // shadow draws dark-on-light ink offset from the glyphs
        let shadow = draw(##"{"type":"text","text":"I","y":40,"size":100,"color":"#ffffff","shadow":{"color":"#ff0000","blur":0,"x":30,"y":0}}"##, w: 300, h: 200)
        var shadowPx = 0
        for y in 0..<200 { for x in 0..<300 { let p = shadow.px(x, y); if p.r > 150 && p.g < 60 && p.b < 60 { shadowPx += 1 } } }
        XCTAssertGreaterThan(shadowPx, 100)
    }

    func testTextFontFallbackAndEmoji() {
        let b = draw(##"{"type":"text","text":"Fallback","y":50,"size":60,"font":"Definitely Not A Font 123"}"##, w: 600, h: 200)
        XCTAssertNotNil(inkBounds(b))
        let named = draw(##"{"type":"text","text":"Named","y":50,"size":60,"font":"Helvetica Neue"}"##, w: 600, h: 200)
        XCTAssertNotNil(inkBounds(named))
        let emoji = draw(##"{"type":"text","text":"Hi 🎬🔥 مرحبا 日本","y":50,"size":60}"##, w: 800, h: 200)
        XCTAssertNotNil(inkBounds(emoji))
        let heavy = inkBounds(draw(##"{"type":"text","text":"Weight","y":50,"size":70,"weight":900,"align":"left"}"##, w: 600, h: 200))!
        let light = inkBounds(draw(##"{"type":"text","text":"Weight","y":50,"size":70,"weight":100,"align":"left"}"##, w: 600, h: 200))!
        XCTAssertGreaterThan(heavy.width, light.width, "weights are different faces")
    }

    // MARK: garbage

    func testGarbageInputDoesNotCrash() {
        let garbage = [
            ##"{"type":"nonsense"}"##,
            ##"{"type":""}"##,
            ##"{"type":"rect","x":0,"y":0,"width":-50,"height":-50,"color":"#fff"}"##,
            ##"{"type":"rect","width":0,"height":0,"color":"#fff"}"##,
            ##"{"type":"rect","x":1e308,"y":-1e308,"width":1e308,"height":1e308,"color":"#fff","radius":1e308,"stroke":"#f00","strokeWidth":1e308}"##,
            ##"{"type":"ellipse","width":-1,"height":10,"color":"#fff"}"##,
            ##"{"type":"path","d":"","color":"#fff"}"##,
            ##"{"type":"path","d":"M","color":"#fff"}"##,
            ##"{"type":"path","d":"L 10 10 M q q q Z Z 1e999 A 0 0 0 0 0 5 5","color":"#fff","stroke":"#fff"}"##,
            ##"{"type":"path","d":"M 0 0 L nan inf","color":"#fff"}"##,
            ##"{"type":"path","color":"#fff"}"##,
            ##"{"type":"gradient"}"##,
            ##"{"type":"gradient","stops":[]}"##,
            ##"{"type":"gradient","stops":[{"at":0,"color":"zzz"}]}"##,
            ##"{"type":"gradient","kind":"radial","from":{"x":5,"y":5},"to":{"x":5,"y":5},"stops":[{"at":0,"color":"#fff"},{"at":1,"color":"#000"}]}"##,
            ##"{"type":"gradient","from":{"x":5,"y":5},"to":{"x":5,"y":5},"stops":[{"at":5,"color":"#fff"},{"at":-3,"color":"#000"}]}"##,
            ##"{"type":"image"}"##,
            ##"{"type":"video"}"##,
            ##"{"type":"video","src":"x","time":-5}"##,
            ##"{"type":"text"}"##,
            ##"{"type":"text","text":""}"##,
            ##"{"type":"text","text":"x","size":-10}"##,
            ##"{"type":"text","text":"x","size":0}"##,
            ##"{"type":"text","text":"x","size":1e300}"##,
            ##"{"type":"text","text":"x","width":-5}"##,
            ##"{"type":"text","text":"x","width":0.0001,"size":50}"##,
            ##"{"type":"text","text":"🎬🎬🎬🎬","width":1,"size":50,"letterSpacing":-1e9}"##,
            ##"{"type":"solid","color":"nope","opacity":-3}"##,
            ##"{"type":"solid","color":"#fff","opacity":1e300}"##,
            ##"{"type":"solid","color":"#fff","transform":{"scale":0}}"##,
            ##"{"type":"solid","color":"#fff","transform":{"scale":1e300,"rotate":1e300,"translateX":-1e300}}"##,
            ##"{"type":"solid","color":"#fff","transform":{"scaleX":-1e-300}}"##,
            ##"{"type":"solid","color":"#fff","blend":"wat"}"##,
            ##"{"type":"solid","color":"#fff","mask":[]}"##,
            ##"{"type":"solid","color":"#fff","mask":[{"type":"zzz"}]}"##,
            ##"{"type":"solid","color":"#fff","maskMode":"???","mask":[{"type":"solid","color":"#fff"}]}"##,
            ##"{"type":"solid","color":"#fff","clip":{"x":0,"y":0,"width":-1,"height":-1}}"##,
            ##"{"type":"solid","color":"#fff","clip":{"x":0,"y":0,"width":50,"height":50,"radius":-9}}"##,
            ##"{"type":"solid","color":"#fff","clip":{"x":0,"y":0,"width":50,"height":50,"radius":1e300}}"##,
            ##"{"type":"group","children":[]}"##,
            ##"{"type":"group","children":[{"type":"group","children":[]}]}"##,
            ##"{"type":"solid","color":"#fff","effects":[{"name":"blur","radius":-5},{"name":"blur","radius":1e300},{"name":"motionBlur","radius":-1},{"name":"zoomBlur","amount":1e300},{"name":"vignette","amount":-5,"radius":-5},{"name":"pixellate","radius":0},{"name":"pixellate","radius":-4},{"name":"sharpen","amount":9e9},{"name":"glow","radius":-1,"amount":-1},{"name":"grain","amount":9,"seed":1e300},{"name":"rgbSplit","amount":1e300,"angle":1e300},{"name":"tint"},{"name":"tint","color":"bad"},{"name":"colorMatrix"},{"name":"colorMatrix","matrix":[]},{"name":"hue","angle":1e300},{"name":"exposure","amount":1e300},{"name":"contrast","amount":-1e300},{"name":"saturation","amount":-5},{"name":"sepia","amount":-1},{"name":"grayscale","amount":9},{"name":"","amount":1},{"name":"x"}]}"##,
        ]
        for json in garbage {
            let b = draw(json)
            XCTAssertEqual(b.w, 200, json)
        }
        // degenerate canvases
        for (w, h) in [(0, 0), (-5, 10), (1, 1), (7, 3)] {
            let cfg = CompositionConfig(width: w, height: h, fps: 30, durationInFrames: 1, audio: nil, background: "bogus")
            let img = SprocketRenderer().render(node(##"{"type":"solid","color":"#fff"}"##), config: cfg, resources: TestResources())
            XCTAssertGreaterThanOrEqual(img.extent.width, 1)
            _ = rasterize(img)
        }
        // deep nesting does not blow the stack
        var deep = ##"{"type":"solid","color":"#fff"}"##
        for _ in 0..<200 { deep = group(deep) }
        _ = draw(deep)
    }

    func testBadSiblingsDoNotStopOthers() {
        let b = draw(group(##"{"type":"zzz"}"##, ##"{"type":"rect","width":-1,"height":5,"color":"#f00"}"##, ##"{"type":"rect","x":0,"y":0,"width":50,"height":50,"color":"#00ff00"}"##))
        assertPx(b, 25, 25, green)
    }

    // MARK: pictures and performance

    func writePNG(_ image: CIImage, to url: URL) {
        guard let cg = SprocketRenderer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    func testWritesCompositeScenePNGs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprocket-render-png-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("MOTION RENDER PNG FOLDER: \(dir.path)")
        var res = TestResources()
        res.videos["v"] = halfRedBlue(540, 960)
        res.images["pic"] = topRedBottomBlue(300, 200)

        let scenes: [(String, String)] = [
            ("1-shapes-gradient-text", group(
                ##"{"type":"gradient","from":{"x":0,"y":0},"to":{"x":0,"y":960},"stops":[{"at":0,"color":"#141e30"},{"at":1,"color":"#e94560"}]}"##,
                ##"{"type":"rect","x":60,"y":80,"width":200,"height":120,"radius":30,"color":"#ffffff","stroke":"#000","strokeWidth":6}"##,
                ##"{"type":"ellipse","x":300,"y":80,"width":180,"height":120,"color":"rgba(255,200,0,0.8)"}"##,
                ##"{"type":"path","d":"M 270 400 C 270 300 470 300 470 400 S 270 500 270 400 Z","color":"#00d4ff","stroke":"#fff","strokeWidth":5}"##,
                ##"{"type":"path","d":"M 60 600 A 100 100 0 0 1 260 600 L 160 700 Z","color":"#7cff6b"}"##,
                ##"{"type":"text","text":"Sprocket\nRenderer 🎬","y":740,"size":70,"weight":800,"color":"#fff","stroke":"#000","strokeWidth":4,"shadow":{"color":"rgba(0,0,0,0.6)","blur":12,"x":0,"y":8}}"##)),
            ("2-blend-mask-clip", group(
                ##"{"type":"solid","color":"#203a43"}"##,
                ##"{"type":"image","src":"pic","x":40,"y":60,"width":460,"height":300,"clip":{"x":40,"y":60,"width":460,"height":300,"radius":50}}"##,
                ##"{"type":"rect","x":40,"y":400,"width":460,"height":200,"color":"#ff7a00","blend":"multiply"}"##,
                ##"{"type":"video","src":"v","x":40,"y":640,"width":460,"height":260,"maskMode":"luma","mask":[{"type":"gradient","from":{"x":40,"y":0},"to":{"x":500,"y":0},"stops":[{"at":0,"color":"#000"},{"at":1,"color":"#fff"}]}]}"##,
                ##"{"type":"rect","x":200,"y":300,"width":140,"height":140,"color":"#fff","transform":{"rotate":30,"scale":1.2},"opacity":0.8}"##)),
            ("3-effects", group(
                group(##"{"type":"video","src":"v"}"##, ##"{"type":"text","text":"GLITCH","y":420,"size":110,"weight":900,"color":"#fff"}"##,
                      props: ##""effects":[{"name":"rgbSplit","amount":14,"angle":0},{"name":"grain","amount":0.3,"seed":3},{"name":"vignette","amount":1,"radius":1},{"name":"saturation","amount":1.4}]"##))),
        ]
        for (name, json) in scenes {
            let cfg = CompositionConfig(width: 540, height: 960, fps: 30, durationInFrames: 1, audio: nil, background: "#000")
            let img = SprocketRenderer().render(node(json), config: cfg, resources: res)
            writePNG(img, to: dir.appendingPathComponent("\(name).png"))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, scenes.count)
    }

    func testPerformanceFullHDFrame() throws {
        let W = 1080, H = 1920
        // Realistic video-like content: an uploaded bitmap, not a constant colour.
        func texture(_ seed: Int) -> CIImage {
            let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [CGColor(red: 0.9, green: 0.3, blue: CGFloat(seed) * 0.5, alpha: 1), CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: W, y: H), options: [])
            return CIImage(cgImage: ctx.makeImage()!)
        }
        var res = TestResources()
        res.videos["a"] = texture(0); res.videos["b"] = texture(1)
        var rects: [String] = []
        for i in 0..<100 {
            rects.append("{\"type\":\"rect\",\"x\":\((i % 10) * 100 + 5),\"y\":\((i / 10) * 190 + 5),\"width\":90,\"height\":180,\"radius\":20,\"color\":\"#fff\"}")
        }
        let tree = group(
            ##"{"type":"video","src":"a","time":0}"##,
            ##"{"type":"video","src":"b","time":0,"mask":[\##(rects.joined(separator: ","))]}"##,
            ##"{"type":"text","text":"LISBON","y":1500,"size":160,"weight":800,"color":"#fff"}"##,
            props: ##""effects":[{"name":"blur","radius":6}]"##)
        let n = node(tree)
        let cfg = CompositionConfig(width: W, height: H, fps: 30, durationInFrames: 1, audio: nil, background: nil)
        let renderer = SprocketRenderer()
        var buf = [UInt8](repeating: 0, count: W * H * 4)
        func once(_ t: Node) -> (Double, Double) {
            let t0 = CFAbsoluteTimeGetCurrent()
            let img = renderer.render(t, config: cfg, resources: res)
            let t1 = CFAbsoluteTimeGetCurrent()
            SprocketRenderer.context.render(img, toBitmap: &buf, rowBytes: W * 4, bounds: img.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let t2 = CFAbsoluteTimeGetCurrent()
            return ((t1 - t0) * 1000, (t2 - t0) * 1000)
        }
        let cold = once(n)
        var totals: [Double] = [], builds: [Double] = []
        for _ in 0..<15 { let r = once(n); builds.append(r.0); totals.append(r.1) }
        totals.sort(); builds.sort()
        print("MOTION RENDER PERF 1080x1920 (2 video layers, 100-rect mask, blur, text): cold \(Int(cold.1)) ms; warm median \(String(format: "%.1f", totals[7])) ms (tree build \(String(format: "%.1f", builds[7])) ms), min \(String(format: "%.1f", totals[0])), max \(String(format: "%.1f", totals[14]))")
        // animated: text changes every frame so nothing is cached
        var anim: [Double] = []
        for i in 0..<10 {
            let t = tree.replacingOccurrences(of: "LISBON", with: "LISBON \(i)")
            anim.append(once(node(t)).1)
        }
        anim.sort()
        print("MOTION RENDER PERF uncached text per frame: median \(String(format: "%.1f", anim[5])) ms")
        XCTAssertLessThan(totals[7], 100)
        XCTAssertGreaterThan(Int(buf[(1000 * W + 540) * 4 + 3]), 0)
    }
}
