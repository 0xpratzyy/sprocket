import XCTest
import AVFoundation
import CoreImage
import ImageIO
@testable import Sprocket

final class ExportMediaTests: XCTestCase {
    static let dir = TestMedia.tempDir("media")
    static var codedURL: URL { dir.appendingPathComponent("coded.mov") }

    override class func setUp() {
        super.setUp()
        try? TestMedia.makeCodedMovie(url: codedURL)
    }

    private func makeStore(maxReaders: Int = 4) async -> (MediaVideoStore, [(r: Int, g: Int, b: Int)]) {
        let store = MediaVideoStore(assets: ["v": Self.codedURL], maxReaders: maxReaders)
        await store.prepare(["v"])
        let table = try! TestMedia.codedTable(store: store, id: "v")
        store.closeAll()
        return (store, table)
    }

    private func frameNumber(_ store: MediaVideoStore, _ t: Double, _ table: [(r: Int, g: Int, b: Int)]) throws -> Int {
        let img = try XCTUnwrap(try store.frame(src: "v", time: t))
        return TestMedia.classify(TestMedia.sampleCentre(img), in: table)
    }

    /// Expected frame at-or-before t for a 30 fps movie.
    private func expected(_ t: Double) -> Int { min(59, max(0, Int((t * 30 + 1e-6).rounded(.down)))) }

    func testTableMatchesEncodedColours() async throws {
        let (_, table) = await makeStore()
        XCTAssertEqual(table.count, 60)
        for k in 0..<60 {
            let c = TestMedia.color(forFrame: k)
            let d = TestMedia.distance(table[k], (Int(c.r), Int(c.g), Int(c.b)))
            XCTAssertLessThan(d, 24, "frame \(k) decoded as \(table[k]) vs encoded \(c)")
        }
        // all 60 frames are distinguishable
        for k in 0..<60 { XCTAssertEqual(TestMedia.classify(table[k], in: table), k) }
    }

    func testForwardPlaybackAndBetweenFrames() async throws {
        let (store, table) = await makeStore()
        for k in 0..<60 {
            XCTAssertEqual(try frameNumber(store, Double(k) / 30, table), k, "exact time of frame \(k)")
            XCTAssertEqual(try frameNumber(store, Double(k) / 30 + 0.02, table), k, "between frames after \(k)")
        }
        XCTAssertEqual(store.openReaderCount(src: "v"), 1, "plain playback should reuse one reader")
    }

    func testSpedUpAndSlowedRequests() async throws {
        let (store, table) = await makeStore()
        var t = 0.0
        while t < 1.95 { XCTAssertEqual(try frameNumber(store, t, table), expected(t), "2.5x at \(t)"); t += 2.5 / 30 }
        t = 0
        while t < 1.0 { XCTAssertEqual(try frameNumber(store, t, table), expected(t), "0.25x at \(t)"); t += 0.25 / 30 }
    }

    func testBackwardRequests() async throws {
        let (store, table) = await makeStore()
        var t = 1.9
        while t >= 0 { XCTAssertEqual(try frameNumber(store, t, table), expected(t), "reverse at \(t)"); t -= 1.0 / 30 }
        t = 1.9
        while t >= 0 { XCTAssertEqual(try frameNumber(store, t, table), expected(t), "reverse fast at \(t)"); t -= 0.13 }
    }

    func testJumpingRequests() async throws {
        let (store, table) = await makeStore()
        for t in [1.5, 0.1, 1.95, 0.0, 0.9, 0.95, 1.2, 1.21, 0.4, 1.8, 0.33, 1.99, 0.5] {
            XCTAssertEqual(try frameNumber(store, t, table), expected(t), "jump to \(t)")
        }
    }

    func testPastEndAndBeforeStart() async throws {
        let (store, table) = await makeStore()
        XCTAssertEqual(try frameNumber(store, 5.0, table), 59)
        XCTAssertEqual(try frameNumber(store, 5.5, table), 59)
        XCTAssertEqual(try frameNumber(store, 2.0, table), 59)
        XCTAssertEqual(try frameNumber(store, -1.0, table), 0)
        XCTAssertEqual(try frameNumber(store, -0.0001, table), 0)
        XCTAssertEqual(try frameNumber(store, 0, table), 0)
        XCTAssertEqual(store.openReaderCount(src: "v") <= 4, true)
    }

    func testTwoTimesOfOneClipInOneFrame() async throws {
        let (store, table) = await makeStore()
        for i in 0..<30 {
            let a = Double(i) / 30, b = 1.0 + Double(i) / 60
            XCTAssertEqual(try frameNumber(store, a, table), expected(a))
            XCTAssertEqual(try frameNumber(store, b, table), expected(b))
        }
        XCTAssertEqual(store.openReaderCount(src: "v"), 2)
        // crossfading with itself closely: 0.3 s apart, both advance together
        let (s2, t2) = await makeStore()
        for i in 0..<40 {
            let a = Double(i) / 30, b = a + 0.3
            XCTAssertEqual(try frameNumber(s2, a, t2), expected(a), "a \(i)")
            XCTAssertEqual(try frameNumber(s2, b, t2), expected(b), "b \(i)")
        }
        XCTAssertLessThanOrEqual(s2.openReaderCount(src: "v"), 4)
    }

    func testReaderCapRecyclesLeastRecentlyUsed() async throws {
        let (store, table) = await makeStore(maxReaders: 2)
        for t in [0.0, 0.5, 1.0, 1.5, 0.0, 1.0] {
            XCTAssertEqual(try frameNumber(store, t, table), expected(t))
            XCTAssertLessThanOrEqual(store.openReaderCount(src: "v"), 2)
        }
    }

    func testUnknownAndNonVideoAssets() async throws {
        let store = MediaVideoStore(assets: [:])
        await store.prepare(["nope"])
        XCTAssertNil(try store.frame(src: "nope", time: 0))
        let tone = Self.dir.appendingPathComponent("tone-only.wav")
        try TestMedia.makeTone(url: tone, seconds: 0.5)
        let s2 = MediaVideoStore(assets: ["a": tone])
        await s2.prepare(["a"])
        XCTAssertNil(try s2.frame(src: "a", time: 0))
    }

    func testPortraitTransformIsAppliedUpright() async throws {
        // Landscape 128x64 frames, left half red, right half blue, tagged as rotated 90 degrees clockwise (a portrait iPhone clip).
        let url = Self.dir.appendingPathComponent("rotated.mov")
        let w = 128, h = 64
        try TestMedia.makeMovie(url: url, width: w, height: h, frames: 10,
                                transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0)) { _, base, bpr in
            for y in 0..<h { for x in 0..<w {
                let p = base + y * bpr + x * 4
                if x < w / 2 { p[0] = 0; p[1] = 0; p[2] = 255 } else { p[0] = 255; p[1] = 0; p[2] = 0 }
                p[3] = 255
            } }
        }
        let store = MediaVideoStore(assets: ["r": url])
        await store.prepare(["r"])
        let img = try XCTUnwrap(try store.frame(src: "r", time: 0.1))
        XCTAssertEqual(img.extent.width, 64); XCTAssertEqual(img.extent.height, 128)
        XCTAssertEqual(img.extent.origin, .zero)
        let top = TestMedia.sample(img, x: 32, y: 10), bottom = TestMedia.sample(img, x: 32, y: 118)
        XCTAssertGreaterThan(top.r, 200, "left half of the raw frame should end up on top: \(top)")
        XCTAssertGreaterThan(bottom.b, 200, "right half should end up at the bottom: \(bottom)")
    }

    func testImageStore() throws {
        let url = Self.dir.appendingPathComponent("img.png")
        let ctx = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: TestMedia.srgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let store = MediaImageStore(assets: ["i": url])
        let img = try XCTUnwrap(store.image(src: "i"))
        XCTAssertEqual(img.extent.width, 16); XCTAssertEqual(img.extent.height, 32)   // orientation 6 swaps the sides
        XCTAssertEqual(img.extent.origin, .zero)
        XCTAssertGreaterThan(TestMedia.sampleCentre(img).r, 240)
        XCTAssertTrue(store.image(src: "i") === img || store.image(src: "i")!.extent == img.extent)
        XCTAssertNil(store.image(src: "missing"))
    }

    func testAudioMixLevelsAndFades() async throws {
        let tone = Self.dir.appendingPathComponent("tone.wav")
        try TestMedia.makeTone(url: tone, seconds: 2.0, amplitude: 0.8)
        // clip: starts at 0.5 s, 1.5 s long, volume 0.5, 0.5 s fades each side
        let config = CompositionConfig(width: 64, height: 64, fps: 30, durationInFrames: 90, audio: [
            .init(src: "t", startFrame: 15, offset: 0, durationInFrames: 45, volume: 0.5, fadeIn: 0.5, fadeOut: 0.5),
            .init(src: "missing", startFrame: 0, offset: nil, durationInFrames: nil, volume: 1, fadeIn: nil, fadeOut: nil),
        ], background: nil)
        let built = await MediaAudioMix.build(config: config, assets: ["t": tone])
        let mix = try XCTUnwrap(built)
        let (reader, out) = try mix.makeReader()
        XCTAssertTrue(reader.startReading())
        let rms = try TestMedia.readRMS(from: out, reader: reader, window: 0.1, seconds: 2.0)
        // bins: 0.1 s each. Full level = 0.5 * 0.8 / sqrt(2) = 0.283
        let full = 0.5 * 0.8 / 2.0.squareRoot()
        XCTAssertLessThan(rms[2], 0.01, "silent before the clip starts")
        XCTAssertLessThan(rms[5], full * 0.35, "start of the fade-in is quiet: \(rms[5])")
        XCTAssertEqual(rms[8], full * 0.7, accuracy: full * 0.05, "mid fade-in about 0.7: \(rms[8])")
        XCTAssertEqual(rms[12], full, accuracy: full * 0.05, "full level: \(rms[12])")
        XCTAssertEqual(rms[14], full, accuracy: full * 0.05)
        XCTAssertLessThan(rms[19], full * 0.35, "end of the fade-out is quiet: \(rms[19])")
        XCTAssertGreaterThan(rms[18], rms[19])
        XCTAssertEqual(mix.composition.duration.seconds, 2.0, accuracy: 0.01)
    }

    func testNoUsableAudioGivesNoMix() async throws {
        let config = CompositionConfig(width: 64, height: 64, fps: 30, durationInFrames: 30, audio: [
            .init(src: "missing", startFrame: nil, offset: nil, durationInFrames: nil, volume: nil, fadeIn: nil, fadeOut: nil)], background: nil)
        let none = await MediaAudioMix.build(config: config, assets: [:])
        XCTAssertNil(none)
        var c2 = config; c2.audio = nil
        let none2 = await MediaAudioMix.build(config: c2, assets: [:])
        XCTAssertNil(none2)
    }
}
