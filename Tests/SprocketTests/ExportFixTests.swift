import XCTest
import AVFoundation
import CoreImage
import ImageIO
@testable import Sprocket

/// Items 1, 2, 6, 7 at the library level: cancellation leaves no files, bad assets are reported, reverse playback and jump
/// cuts are cheap and bounded, audio is padded to the picture's length.
final class ExportFixTests: XCTestCase {
    static let dir = TestMedia.tempDir("fixes")
    static var codedURL: URL { dir.appendingPathComponent("coded.mov") }

    override class func setUp() {
        super.setUp()
        try? TestMedia.makeCodedMovie(url: codedURL)
    }

    private func freshDir(_ name: String) -> URL {
        let d = Self.dir.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func listing(_ d: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).sorted() }

    private func audioDuration(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio).first
        return try await XCTUnwrap(track).load(.timeRange).duration.seconds
    }

    // MARK: item 1: library-level cancellation

    func testCancelledExportLeavesNoFilesBehind() async throws {
        let dir = freshDir("cancel")
        let tone = dir.appendingPathComponent("tone.wav")
        try TestMedia.makeTone(url: tone, seconds: 5)
        let out = dir.appendingPathComponent("k.mp4")
        let script = try SprocketScript(source: """
        composition({ width: 64, height: 64, fps: 30, durationInFrames: 6000, audio: [{ src: "tone" }] },
          function (frame) { return [solid("#123456"), text("f" + frame, { y: 10, size: 20 })]; });
        """)
        let exporter = SprocketExporter(script: script, assets: ["tone": tone])
        let task = Task { try await exporter.export(to: out) }
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "the export should be running")
        task.cancel()
        let result = await task.result
        switch result {
        case .success: XCTFail("the export finished before it could be cancelled")
        case .failure(let e): XCTAssertEqual((e as? SprocketError)?.kind, .cancelled, "\(e)")
        }
        XCTAssertEqual(listing(dir), ["tone.wav"], "no partial output and no AVAssetWriter temp file may remain")
    }

    func testExportCancelledBeforeItStartsLeavesNothing() async throws {
        let dir = freshDir("cancel0")
        let out = dir.appendingPathComponent("k.mp4")
        let script = try SprocketScript(source: "composition({ width: 64, height: 64, fps: 30, durationInFrames: 3000 }, function (frame) { return solid('#fff'); });")
        let exporter = SprocketExporter(script: script, assets: [:])
        let task = Task { () -> Void in
            while !Task.isCancelled { await Task.yield() }
            try await exporter.export(to: out)
        }
        task.cancel()
        let result = await task.result
        if case .success = result { XCTFail("expected cancellation") }
        XCTAssertEqual(listing(dir), [])
    }

    // MARK: item 2: asset warnings

    private func warnScript(audio: String = "") throws -> SprocketScript {
        try SprocketScript(source: """
        composition({ width: 64, height: 64, fps: 30, durationInFrames: 6\(audio) }, function (frame) {
          return [solid("#224"), video("ok", { time: frame / 30 }), video("zero", { time: 0 }), video("garbage", { time: 0 }),
                  video("gone", { time: 0 }), video("ghost", { time: 0 }), image("garbage"), image("ghost_img")];
        });
        """)
    }

    func testBadAssetsProduceWarningsButStillRender() async throws {
        let dir = freshDir("warn")
        let zero = dir.appendingPathComponent("zero.mp4"); FileManager.default.createFile(atPath: zero.path, contents: Data())
        let garbage = dir.appendingPathComponent("garbage.mp4"); try Data((0..<4000).map { UInt8(($0 * 7 + 3) % 251) }).write(to: garbage)
        let gone = dir.appendingPathComponent("gone.mp4")
        let assets = ["ok": Self.codedURL, "zero": zero, "garbage": garbage, "gone": gone, "unused_bad": dir.appendingPathComponent("nope.png")]
        let exporter = SprocketExporter(script: try warnScript(), assets: assets)
        XCTAssertEqual(exporter.warnings, [])
        let out = dir.appendingPathComponent("o.mp4")
        try await exporter.export(to: out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "a bad asset must not stop the render")
        let w = exporter.warnings
        XCTAssertEqual(w.count, Set(w).count, "no duplicates over 6 frames: \(w)")
        XCTAssertTrue(w.contains("asset zero: file is not a readable video (\(zero.path)); the file is empty"), "\(w)")
        XCTAssertTrue(w.contains("asset garbage: file is not a readable video (\(garbage.path))"), "\(w)")
        XCTAssertTrue(w.contains("asset garbage: file is not a readable image (\(garbage.path))"), "\(w)")
        XCTAssertTrue(w.contains("asset gone: file does not exist (\(gone.path))"), "\(w)")
        XCTAssertTrue(w.contains("asset ghost is used by the script but was not provided"), "\(w)")
        XCTAssertTrue(w.contains("asset ghost_img is used by the script but was not provided"), "\(w)")
        XCTAssertFalse(w.contains { $0.contains("asset ok") }, "the good clip must not warn: \(w)")
        XCTAssertFalse(w.contains { $0.contains("unused_bad") }, "assets the script does not use must not warn: \(w)")
        XCTAssertEqual(w.count, 6, "\(w)")
    }

    func testStillCollectsWarningsAndWarningsAreThreadSafe() async throws {
        let dir = freshDir("warn2")
        let exporter = SprocketExporter(script: try warnScript(), assets: ["ok": Self.codedURL])
        _ = try await exporter.still(frame: 2)
        XCTAssertTrue(exporter.warnings.contains("asset zero is used by the script but was not provided"))
        let before = exporter.warnings
        DispatchQueue.concurrentPerform(iterations: 200) { _ in _ = exporter.warnings; exporter.warn("asset x: custom") }
        XCTAssertEqual(exporter.warnings, before + ["asset x: custom"])
        _ = dir
    }

    func testAudioWarnings() async throws {
        let dir = freshDir("warn3")
        let garbage = dir.appendingPathComponent("noise.m4a"); try Data(repeating: 9, count: 3000).write(to: garbage)
        let script = try SprocketScript(source: """
        composition({ width: 64, height: 64, fps: 30, durationInFrames: 6, audio: [{ src: "noise" }, { src: "silentvideo" }, { src: "ghost" }, { src: "gone" }] },
          function (frame) { return solid("#000"); });
        """)
        let exporter = SprocketExporter(script: script, assets: ["noise": garbage, "silentvideo": Self.codedURL, "gone": dir.appendingPathComponent("gone.wav")])
        try await exporter.export(to: dir.appendingPathComponent("o.mp4"))
        let w = exporter.warnings
        XCTAssertTrue(w.contains("asset noise: file is not a readable audio (\(garbage.path))"), "\(w)")
        XCTAssertTrue(w.contains("asset silentvideo: file has no audio track (\(Self.codedURL.path))"), "\(w)")
        XCTAssertTrue(w.contains("asset ghost is used by the script but was not provided"), "\(w)")
        XCTAssertTrue(w.contains { $0.hasPrefix("asset gone: file does not exist") }, "\(w)")
        let asset = AVURLAsset(url: dir.appendingPathComponent("o.mp4"))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(tracks.isEmpty, "no usable clip: no audio track")
    }

    func testAssetCheckProblems() async throws {
        let dir = freshDir("check")
        let png = dir.appendingPathComponent("p.png")
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: TestMedia.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
        let tone = dir.appendingPathComponent("t.wav"); try TestMedia.makeTone(url: tone, seconds: 0.2)
        let a = ["v": Self.codedURL, "p": png, "t": tone]
        let v = await AssetCheck.problem(id: "v", kind: .video, assets: a)
        let p = await AssetCheck.problem(id: "p", kind: .image, assets: a)
        let t = await AssetCheck.problem(id: "t", kind: .audio, assets: a)
        XCTAssertNil(v); XCTAssertNil(p); XCTAssertNil(t)
        let vAsImage = await AssetCheck.problem(id: "v", kind: .image, assets: a)
        XCTAssertEqual(vAsImage, "asset v: file is not a readable image (\(Self.codedURL.path))")
        let tAsVideo = await AssetCheck.problem(id: "t", kind: .video, assets: a)
        XCTAssertEqual(tAsVideo, "asset t: file is not a readable video (\(tone.path))")
        let missing = await AssetCheck.problem(id: "zz", kind: .video, assets: a)
        XCTAssertEqual(missing, "asset zz is used by the script but was not provided")
    }

    // MARK: item 7: audio padded to the composition length

    func testAudioShorterThanVideoIsPaddedWithSilence() async throws {
        let dir = freshDir("pad")
        let tone = dir.appendingPathComponent("tone.wav"); try TestMedia.makeTone(url: tone, seconds: 0.5)
        for (label, clip) in [("starts at 0", "{ src: 'tone', volume: 0.8 }"), ("starts late", "{ src: 'tone', startFrame: 30 }"),
                              ("shorter by duration", "{ src: 'tone', durationInFrames: 6 }")] {
            let script = try SprocketScript(source: "composition({ width: 64, height: 64, fps: 30, durationInFrames: 90, audio: [\(clip)] }, function (frame) { return solid('#345'); });")
            let out = dir.appendingPathComponent("pad.mp4")
            try await SprocketExporter(script: script, assets: ["tone": tone]).export(to: out)
            let video = try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first
            let vDur = try await XCTUnwrap(video).load(.timeRange).duration.seconds
            let aDur = try await audioDuration(out)
            XCTAssertEqual(vDur, 3.0, accuracy: 0.05, label)
            XCTAssertEqual(aDur, 3.0, accuracy: 0.06, "\(label): audio \(aDur) s vs video \(vDur) s")
            let rms = try await TestMedia.rmsProfile(of: AVURLAsset(url: out), window: 0.25, seconds: 3.0)
            XCTAssertLessThan(rms[11], 0.005, "\(label): the padding is silent")
            XCTAssertLessThan(rms[8], 0.005, label)
        }
    }

    func testAudioLongerThanVideoIsStillCut() async throws {
        let dir = freshDir("pad2")
        let tone = dir.appendingPathComponent("tone.wav"); try TestMedia.makeTone(url: tone, seconds: 4)
        let script = try SprocketScript(source: "composition({ width: 64, height: 64, fps: 30, durationInFrames: 30, audio: [{ src: 'tone' }] }, function (frame) { return solid('#345'); });")
        let out = dir.appendingPathComponent("o.mp4")
        try await SprocketExporter(script: script, assets: ["tone": tone]).export(to: out)
        let aDur = try await audioDuration(out)
        XCTAssertEqual(aDur, 1.0, accuracy: 0.06)
    }

    // MARK: item 6: reverse playback, jump cuts, bounded memory

    private func table() async throws -> [(r: Int, g: Int, b: Int)] {
        let s = MediaVideoStore(assets: ["v": Self.codedURL]); await s.prepare(["v"])
        return try TestMedia.codedTable(store: s, id: "v")
    }
    private func number(_ s: MediaVideoStore, _ t: Double, _ table: [(r: Int, g: Int, b: Int)]) throws -> Int {
        TestMedia.classify(TestMedia.sampleCentre(try XCTUnwrap(try s.frame(src: "v", time: t))), in: table)
    }
    private func expected(_ t: Double) -> Int { min(59, max(0, Int((t * 30 + 1e-6).rounded(.down)))) }

    func testReversePlaybackDecodesEachGroupOnce() async throws {
        let table = try await table()
        let s = MediaVideoStore(assets: ["v": Self.codedURL]); await s.prepare(["v"])
        var t = 59.0 / 30
        while t >= 0 { XCTAssertEqual(try number(s, t, table), expected(t), "reverse at \(t)"); t -= 1.0 / 30 }
        // 60 frames in groups of 15: a handful of readers, not one per frame
        XCTAssertLessThanOrEqual(s.readerOpenCount, 8, "reader opens: \(s.readerOpenCount)")
        // and again, backwards at half speed, and jumping around inside the cached groups
        t = 1.9
        while t >= 0 { XCTAssertEqual(try number(s, t, table), expected(t), "slow reverse at \(t)"); t -= 0.5 / 30 }
    }

    func testRevisitedTimesAreServedFromTheRecentFrames() async throws {
        let table = try await table()
        let s = MediaVideoStore(assets: ["v": Self.codedURL]); await s.prepare(["v"])
        XCTAssertEqual(try number(s, 0.5, table), 15)
        XCTAssertEqual(try number(s, 1.5, table), 45)
        let opens = s.readerOpenCount
        for _ in 0..<5 {
            XCTAssertEqual(try number(s, 0.5, table), 15)
            XCTAssertEqual(try number(s, 1.5, table), 45)
            XCTAssertEqual(try number(s, 0.51, table), 15)     // between frames: same frame
        }
        XCTAssertEqual(s.readerOpenCount, opens, "revisits must not open readers")
        // a freeze (the same time every frame) and slow motion cost nothing either
        for _ in 0..<20 { XCTAssertEqual(try number(s, 1.0, table), 30) }
    }

    func testFrameCachesStayWithinTheirByteBudget() async throws {
        let table = try await table()
        let frameBytes = 128 * 72 * 3 / 2
        let budget = frameBytes * 8                      // room for only a few frames
        let s = MediaVideoStore(assets: ["v": Self.codedURL], cacheBytes: budget); await s.prepare(["v"])
        var t = 59.0 / 30
        var worst = 0
        while t >= 0 {
            XCTAssertEqual(try number(s, t, table), expected(t), "reverse at \(t)")
            worst = max(worst, s.cachedBytes)
            t -= 1.0 / 30
        }
        // pixel buffers can be a little larger than w*h*1.5, so allow a few frames of slack
        XCTAssertLessThanOrEqual(worst, budget + frameBytes * 4, "cached \(worst) bytes against a budget of \(budget)")
        XCTAssertGreaterThan(worst, 0)
        s.closeAll()
        XCTAssertEqual(s.cachedBytes, 0)
        for t in [1.5, 0.1, 1.95, 0.0, 0.9, 0.4, 1.8, 0.33] { XCTAssertEqual(try number(s, t, table), expected(t), "jump to \(t) after closeAll") }
    }

    func testVideoTimeNaNAndInfinity() async throws {
        let table = try await table()
        let s = MediaVideoStore(assets: ["v": Self.codedURL]); await s.prepare(["v"])
        XCTAssertEqual(try number(s, .infinity, table), 59, "+infinity holds the last frame")
        XCTAssertEqual(try number(s, .nan, table), 0, "NaN gives the first frame")
        XCTAssertEqual(try number(s, -.infinity, table), 0)
        XCTAssertEqual(try number(s, .greatestFiniteMagnitude, table), 59)
        XCTAssertEqual(try number(s, 0.5, table), 15)
    }

    func testSeveralTimeStreamsOfOneClipGetTheirOwnReaders() async throws {
        let table = try await table()
        let s = MediaVideoStore(assets: ["v": Self.codedURL]); await s.prepare(["v"])
        for i in 0..<30 {
            let t = Double(i) / 30
            for (name, tt) in [("normal", t), ("2x", min(1.95, t * 2)), ("reverse", 1.9 - t), ("freeze", 1.0), ("slow", t * 0.5)] {
                XCTAssertEqual(try number(s, tt, table), expected(tt), "\(name) at frame \(i)")
            }
        }
        XCTAssertLessThanOrEqual(s.readerOpenCount, 14, "reader opens: \(s.readerOpenCount)")
    }
}
