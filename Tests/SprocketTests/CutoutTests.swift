import XCTest
import AVFoundation
import CoreImage
@testable import Sprocket

/// `cutout(src, { time, kind })`: authoring form, validator, tree, the needed-range scan, the on-disk cache, and an end-to-end
/// export where a mask recolours a region. Vision finds no person in synthetic colour bars, so these tests inject a mask maker.
final class CutoutTests: XCTestCase {
    static let dir = TestMedia.tempDir("cutout")

    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        private var rangesSeen: [[ClosedRange<Double>]] = []
        func hit(_ r: [ClosedRange<Double>]) { lock.withLock { n += 1; rangesSeen.append(r) } }
        var count: Int { lock.withLock { n } }
        var ranges: [[ClosedRange<Double>]] { lock.withLock { rangesSeen } }
    }

    /// White on the left half of the (upright) mask, black on the right.
    static let leftHalf: MatteFrameMasker = { _, _, size, _ in
        let bounds = CGRect(origin: .zero, size: size)
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
        return white.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(to: bounds)
    }

    func maker(_ counter: Counter, masker: @escaping MatteFrameMasker = CutoutTests.leftHalf, maxSide: Int? = 64) -> MatteMakerFunction {
        { input, output, kind, ranges, progress in
            counter.hit(ranges)
            return try await MatteMaker.make(input: input, output: output, kind: kind, ranges: ranges, maxSide: maxSide,
                                             masker: masker, progress: progress)
        }
    }

    func freshCache(_ name: String) -> URL {
        let d = Self.dir.appendingPathComponent("cache-" + name, isDirectory: true)
        try? FileManager.default.removeItem(at: d)
        return d
    }

    func clip(_ name: String = "clip.mov", frames: Int = 60) throws -> URL {
        let url = Self.dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try TestMedia.makeCodedMovie(url: url, width: 128, height: 72, frames: frames) }
        return url
    }

    static func source(_ extra: String = "") -> String {
        """
        composition({ width: 128, height: 72, fps: 30, durationInFrames: 30 }, function (frame, ctx) {
          const t = frame / ctx.fps;
          return [video("c1", { time: t }), solid("#ff0000", { mask: cutout("c1", { time: t \(extra) }), maskMode: "luma" })];
        });
        """
    }

    func pixel(_ cg: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        TestMedia.sample(CIImage(cgImage: cg), x: x, y: y)
    }

    // MARK: authoring form and validator

    func testCutoutBuildsAVideoNodeWithAMatte() throws {
        let s = try SprocketScript(source: """
        composition({ width: 100, height: 100, fps: 30, durationInFrames: 3 }, function () {
          return [cutout("a", { time: 1 }), cutout("b", { time: 2, kind: "subject", x: 5, fit: "contain" }), video("a", { time: 1 })];
        });
        """)
        let n = try s.node(frame: 0)
        let kids = try XCTUnwrap(n.children)
        XCTAssertEqual(kids.map(\.type), ["video", "video", "video"])
        XCTAssertEqual(kids.map(\.matte), ["person", "subject", nil])
        XCTAssertEqual(kids[1].fit, "contain"); XCTAssertEqual(kids[1].x, 5)
        XCTAssertFalse(try s.json(frame: 0).contains("\"kind\""), "the kind travels as matte, not as a stray prop")
    }

    func testValidatorRejectsOtherKinds() {
        func err(_ body: String) -> String {
            do {
                let s = try SprocketScript(source: "composition({ width: 100, height: 100, fps: 30, durationInFrames: 3 }, function () { return \(body); });")
                _ = try s.node(frame: 0); XCTFail("expected an error for \(body)"); return ""
            } catch { return (error as? SprocketError)?.message ?? "\(error)" }
        }
        XCTAssertTrue(err("cutout('a', { kind: 'banana' })").contains("cutout kind must be \"person\" or \"subject\", got \"banana\""))
        XCTAssertTrue(err("cutout('a', { kind: 5 })").contains("cutout kind must be \"person\" or \"subject\", got 5"))
        XCTAssertTrue(err("cutout('a', { kind: 'Person' })").contains("got \"Person\""))
        XCTAssertTrue(err("video('a', { matte: 'face' })").contains("cutout kind must be"))
    }

    func testValidatorAcceptsBothKindsAndTheDefault() throws {
        for body in ["cutout('a')", "cutout('a', {})", "cutout('a', { kind: 'person' })", "cutout('a', { kind: 'subject', time: 2 })",
                     "cutout('a', { kind: null })", "cutout('a', { kind: undefined })"] {
            let s = try SprocketScript(source: "composition({ width: 100, height: 100, fps: 30, durationInFrames: 3 }, function () { return \(body); });")
            let n = try s.node(frame: 0)
            XCTAssertEqual(n.type, "video"); XCTAssertNotNil(n.matte, body)
        }
    }

    // MARK: tree

    func testVideoRequestsDistinguishClipAndMask() throws {
        let json = #"{"type":"group","children":[{"type":"video","src":"a","time":1.5},{"type":"video","src":"a","time":1.5,"matte":"person"},{"type":"video","src":"a","time":1.5,"matte":"subject"}]}"#
        let n = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
        let r = n.videoRequests
        XCTAssertEqual(r.map(\.matte), [nil, "person", "subject"])
        XCTAssertEqual(Set(r).count, 3, "the clip and its two masks are three different requests")
        XCTAssertEqual(Node.VideoRequest(src: "a", time: 1), Node.VideoRequest(src: "a", time: 1, matte: nil))
        XCTAssertNotEqual(Node.VideoRequest(src: "a", time: 1), Node.VideoRequest(src: "a", time: 1, matte: "person"))
    }

    // MARK: needed-range scan

    func testScanFindsTheRangesEachClipNeeds() throws {
        let s = try SprocketScript(source: """
        composition({ width: 100, height: 100, fps: 10, durationInFrames: 8 }, function (frame) {
          const t = frame < 6 ? 1 + frame / 10 : 10 + (frame - 6) / 10;
          return [video("a", { time: t }), cutout("a", { time: t }), cutout("b", { time: 3, kind: "subject" })];
        });
        """)
        var scan = MatteNeedScan()
        for f in 0..<8 { scan.add(try s.node(frame: f)) }
        let needs = scan.needs()
        XCTAssertEqual(needs.map(\.src), ["a", "b"])
        XCTAssertEqual(needs.map(\.kind), ["person", "subject"])
        let a = needs[0]
        XCTAssertEqual(a.ranges.count, 2, "two shots far apart are two ranges, not one long one")
        XCTAssertEqual(a.ranges[0].lowerBound, 0.75, accuracy: 1e-9); XCTAssertEqual(a.ranges[0].upperBound, 1.75, accuracy: 1e-9)
        XCTAssertEqual(a.ranges[1].lowerBound, 9.75, accuracy: 1e-9); XCTAssertEqual(a.ranges[1].upperBound, 10.35, accuracy: 1e-9)
        XCTAssertEqual(needs[1].ranges, [2.75...3.25])
        XCTAssertLessThan(a.seconds, 2, "only the used part is masked")
        // The plain video("a") request alone creates no need.
        var plain = MatteNeedScan(); plain.add(try s.node(frame: 0))
        XCTAssertEqual(plain.needs().map(\.src), ["a", "b"])
        var none = MatteNeedScan()
        none.add(Node(type: "video"))
        XCTAssertTrue(none.isEmpty)
    }

    func testExporterReportsItsNeeds() throws {
        let script = try SprocketScript(source: Self.source())
        let ex = SprocketExporter(script: script, assets: [:])
        let n = try ex.matteNeeds()
        XCTAssertEqual(n.count, 1)
        XCTAssertEqual(n[0].start, 0, accuracy: 1e-9); XCTAssertEqual(n[0].end, 29.0 / 30 + 0.25, accuracy: 1e-9)
    }

    func testRangesAreClampedToTheClip() {
        XCTAssertEqual(MatteProvider.clamp([0...1e300], to: 2), [0...2])
        XCTAssertEqual(MatteProvider.clamp([(1e300 - 1)...1e300], to: 2), [1.75...2], "time past the end holds the last frame: mask that")
        XCTAssertEqual(MatteProvider.clamp([0...0.5, 0.6...1], to: 5), [0...1])
        XCTAssertEqual(MatteProvider.clamp([0...0.5, 3...3.5], to: 5), [0...0.5, 3...3.5])
    }

    // MARK: cache

    func testSecondExportMakesNoNewMask() async throws {
        let src = try clip()
        let cache = freshCache("hit")
        let counter = Counter()
        let script = try SprocketScript(source: Self.source())
        let out1 = Self.dir.appendingPathComponent("hit1.mp4"), out2 = Self.dir.appendingPathComponent("hit2.mp4")

        let first = SprocketExporter(script: script, assets: ["c1": src], matteMaker: maker(counter), matteCacheDirectory: cache)
        let t0 = Date()
        try await first.export(to: out1)
        let firstTime = Date().timeIntervalSince(t0)
        XCTAssertEqual(counter.count, 1); XCTAssertEqual(first.matteGenerationCount, 1)
        XCTAssertTrue(first.warnings.isEmpty, "\(first.warnings)")

        let second = SprocketExporter(script: script, assets: ["c1": src], matteMaker: maker(counter), matteCacheDirectory: cache)
        let t1 = Date()
        try await second.export(to: out2)
        print("cutout cache: first export \(firstTime) s, cached export \(Date().timeIntervalSince(t1)) s")
        XCTAssertEqual(counter.count, 1, "no second generation")
        XCTAssertEqual(second.matteGenerationCount, 0)

        // Touching the clip changes its key: a new mask is made.
        let copy = Self.dir.appendingPathComponent("clip-copy.mov")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: src, to: copy)
        let third = SprocketExporter(script: script, assets: ["c1": copy], matteMaker: maker(counter), matteCacheDirectory: cache)
        _ = try await third.still(frame: 0)
        XCTAssertEqual(counter.count, 2, "a different file is a different key")
    }

    func testWiderRangeRegeneratesTheUnion() async throws {
        let src = try clip()
        let cache = freshCache("union")
        let counter = Counter()
        let script = try SprocketScript(source: Self.source())
        let ex = SprocketExporter(script: script, assets: ["c1": src], matteMaker: maker(counter), matteCacheDirectory: cache)
        _ = try await ex.still(frame: 3)      // t = 0.1 -> 0 ... 0.35
        XCTAssertEqual(counter.count, 1)
        _ = try await ex.still(frame: 2)      // t = 0.067: inside the cached range
        XCTAssertEqual(counter.count, 1)
        let r1 = try XCTUnwrap(counter.ranges.first?.first)
        XCTAssertLessThan(r1.upperBound, 0.5, "a still masks only its own moment, not the whole clip")
        _ = try await ex.still(frame: 25)     // t = 0.83: outside
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(counter.ranges[1].first?.lowerBound ?? -1, r1.lowerBound, accuracy: 1e-6, "the old range is kept")
        XCTAssertEqual(counter.ranges[1].last?.upperBound ?? -1, 25.0 / 30 + 0.25, accuracy: 1e-6, "and the new one is added")
    }

    func testOnlyTheNeededPartOfALongClipIsMasked() async throws {
        let src = Self.dir.appendingPathComponent("long.mov")   // 5 s of mid grey
        try TestMedia.makeMovie(url: src, width: 128, height: 72, frames: 150) { _, base, bpr in
            for y in 0..<72 { for i in 0..<(128 * 4) { base[y * bpr + i] = 128 } }
        }
        let counter = Counter()
        let script = try SprocketScript(source: """
        composition({ width: 128, height: 72, fps: 30, durationInFrames: 15 }, function (frame, ctx) {
          const t = 3 + frame / ctx.fps;
          return [video("c1", { time: t }), solid("#ff0000", { mask: cutout("c1", { time: t }), maskMode: "luma" })];
        });
        """)
        let out = Self.dir.appendingPathComponent("long.mp4")
        let ex = SprocketExporter(script: script, assets: ["c1": src], matteMaker: maker(counter), matteCacheDirectory: freshCache("long"))
        try await ex.export(to: out)
        let r = try XCTUnwrap(counter.ranges.first?.first, "\(ex.warnings)")
        XCTAssertEqual(r.lowerBound, 2.75, accuracy: 1e-6); XCTAssertEqual(r.upperBound, 3.5 - 1.0 / 30 + 0.25, accuracy: 1e-6)
        // The mask file holds about 1 s of frames, not 5 s.
        let file = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: ex.cacheDirectoryForTests, includingPropertiesForKeys: nil).first { $0.pathExtension == "mp4" })
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(o); reader.startReading()
        var times: [Double] = []
        while let sb = o.copyNextSampleBuffer() { times.append(CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
        times = times.filter { $0 > 0 }   // the reader pads the gap before the first mask frame with a copy of it at 0
        XCTAssertEqual(times.count, 29, accuracy: 3)
        XCTAssertEqual(times.first ?? -1, 2.75, accuracy: 1.0 / 30 + 1e-3, "mask frames keep the clip's own presentation times")
    }

    // MARK: alignment in time

    func testMaskFramesHaveTheClipsPresentationTimes() async throws {
        let src = try clip()
        let out = Self.dir.appendingPathComponent("aligned-mask.mp4")
        // Mask brightness = the clip frame's red channel, so each mask frame says which clip frame it came from.
        let redAsGrey: MatteFrameMasker = { frame, _, size, _ in
            CVPixelBufferLockBaseAddress(frame, .readOnly); defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(frame)
            let r = Double(base[(CVPixelBufferGetHeight(frame) / 2) * bpr + (CVPixelBufferGetWidth(frame) / 2) * 4 + 2]) / 255
            return CIImage(color: CIColor(red: r, green: r, blue: r)).cropped(to: CGRect(origin: .zero, size: size))
        }
        try await MatteMaker.make(input: src, output: out, kind: .person, ranges: [0.5...1.0], maxSide: 64, masker: redAsGrey)
        let clipStore = MediaVideoStore(assets: ["c": src, "m": out]); await clipStore.prepare(["c", "m"])
        for k in [16, 20, 24, 29] {
            let t = Double(k) / 30
            let want = TestMedia.sampleCentre(try XCTUnwrap(try clipStore.frame(src: "c", time: t))).r
            let got = TestMedia.sampleCentre(try XCTUnwrap(try clipStore.frame(src: "m", time: t))).r
            XCTAssertEqual(got, want, accuracy: 14, "mask frame at \(t) s should carry the clip frame at \(t) s (\(got) vs \(want))")
        }
    }

    // MARK: end to end

    func testMaskRecoloursOnlyInsideTheMask() async throws {
        let src = try clip()
        let script = try SprocketScript(source: Self.source())
        let ex = SprocketExporter(script: script, assets: ["c1": src], matteMaker: maker(Counter()), matteCacheDirectory: freshCache("e2e"))
        let plainScript = try SprocketScript(source: """
        composition({ width: 128, height: 72, fps: 30, durationInFrames: 30 }, function (frame, ctx) { return video("c1", { time: frame / ctx.fps }); });
        """)
        let plain = SprocketExporter(script: plainScript, assets: ["c1": src])
        for f in [0, 12, 29] {
            let cut = try await ex.still(frame: f)
            let base = try await plain.still(frame: f)
            // Inside the mask (left half, away from the edge at x = 64): the fill colour.
            for (x, y) in [(10, 10), (30, 36), (50, 60)] {
                let p = pixel(cut, x, y)
                XCTAssertGreaterThan(p.r, 235, "frame \(f) (\(x),\(y)) \(p)"); XCTAssertLessThan(p.g, 20); XCTAssertLessThan(p.b, 20)
            }
            // Outside: exactly what the clip alone draws.
            for (x, y) in [(80, 10), (100, 36), (120, 60)] {
                XCTAssertLessThan(TestMedia.distance(pixel(cut, x, y), pixel(base, x, y)), 4, "frame \(f) (\(x),\(y))")
            }
        }
        XCTAssertTrue(ex.warnings.isEmpty, "\(ex.warnings)")
    }

    func testMaskUsesTheSameFitAsTheClip() async throws {
        // Two 64x72 boxes with "cover": the left shows the left half of the clip, the right shows its right half. The mask
        // (left half white, made at a different size than the clip) must be cropped and placed exactly like the clip, so
        // the left box is filled and the right box is not.
        let src = try clip()
        let script = try SprocketScript(source: """
        composition({ width: 128, height: 72, fps: 30, durationInFrames: 3 }, function () {
          const l = { x: 0, y: 0, width: 64, height: 72, fit: "cover", focusX: 0 };
          const r = { x: 64, y: 0, width: 64, height: 72, fit: "cover", focusX: 1 };
          return [video("c1", Object.assign({ time: 0 }, l)), video("c1", Object.assign({ time: 0 }, r)),
                  solid("#ff0000", { mask: [cutout("c1", Object.assign({ time: 0 }, l)), cutout("c1", Object.assign({ time: 0 }, r))], maskMode: "luma" })];
        });
        """)
        let ex = SprocketExporter(script: script, assets: ["c1": src], matteMaker: maker(Counter(), maxSide: 48), matteCacheDirectory: freshCache("fit"))
        let cg = try await ex.still(frame: 0)
        let left = pixel(cg, 30, 36), right = pixel(cg, 100, 36)
        XCTAssertGreaterThan(left.r, 235, "\(left)"); XCTAssertLessThan(left.g, 20)
        XCTAssertLessThan(right.r, 20, "\(right)"); XCTAssertGreaterThan(right.g, 235, "right box shows the unfilled clip (frame 0 is green)")
    }

    func testExistingExportCallSiteStillCompilesAndReportsMovieFrames() async throws {
        let src = try clip()
        let counter = Counter()
        let script = try SprocketScript(source: Self.source())
        let ex = SprocketExporter(script: script, assets: ["c1": src], matteMaker: maker(counter), matteCacheDirectory: freshCache("progress"))
        final class Seen: @unchecked Sendable {
            let lock = NSLock(); var frames: [Int] = []; var total = 0; var mattes: [MatteProgress] = []
        }
        let seen = Seen()
        ex.prepareHandler = { p in seen.lock.withLock { seen.mattes.append(p) } }
        try await ex.export(to: Self.dir.appendingPathComponent("progress.mp4")) { p in
            seen.lock.withLock { seen.frames.append(p.frame); seen.total = p.total }
        }
        XCTAssertEqual(seen.total, 30)
        XCTAssertEqual(seen.frames.last, 30)
        XCTAssertFalse(seen.mattes.isEmpty, "the preparation phase is observable")
        XCTAssertEqual(seen.mattes.last?.src, "c1"); XCTAssertEqual(seen.mattes.last?.kind, "person")
        XCTAssertEqual(seen.mattes.last?.frame, seen.mattes.last?.total, "the last report is complete")
        XCTAssertEqual(seen.mattes.last?.index, 1); XCTAssertEqual(seen.mattes.last?.count, 1)
    }

    // MARK: failures are warnings

    func testMissingClipIsAWarningNotACrash() async throws {
        let script = try SprocketScript(source: Self.source())
        let missing = Self.dir.appendingPathComponent("does-not-exist.mp4")
        let counter = Counter()
        let ex = SprocketExporter(script: script, assets: ["c1": missing], matteMaker: maker(counter), matteCacheDirectory: freshCache("missing"))
        let cg = try await ex.still(frame: 0)
        XCTAssertEqual(cg.width, 128)
        XCTAssertEqual(counter.count, 0, "nothing to make a mask from")
        XCTAssertTrue(ex.warnings.contains { $0.contains("cutout(\"c1\"") }, "\(ex.warnings)")
        // The solid is masked by "nothing", which hides it: the frame is black, not red.
        XCTAssertLessThan(pixel(cg, 10, 10).r, 10)

        let notProvided = SprocketExporter(script: script, assets: [:], matteMaker: maker(counter), matteCacheDirectory: freshCache("missing2"))
        _ = try await notProvided.export(to: Self.dir.appendingPathComponent("missing.mp4"))
        XCTAssertTrue(notProvided.warnings.contains { $0.contains("cutout(\"c1\"") && $0.contains("not provided") }, "\(notProvided.warnings)")
    }

    func testAGarbageClipIsAWarningToo() async throws {
        let junk = Self.dir.appendingPathComponent("junk.mp4")
        try Data("not a video".utf8).write(to: junk)
        let script = try SprocketScript(source: Self.source())
        let ex = SprocketExporter(script: script, assets: ["c1": junk], matteMaker: maker(Counter()), matteCacheDirectory: freshCache("junk"))
        _ = try await ex.still(frame: 0)
        XCTAssertTrue(ex.warnings.contains { $0.contains("cutout(\"c1\"") }, "\(ex.warnings)")
    }

    func testAMakerThatFailsGivesAWarning() async throws {
        let src = try clip()
        let script = try SprocketScript(source: Self.source())
        let failing: MatteMakerFunction = { _, _, _, _, _ in throw SprocketError(.asset, "boom") }
        let ex = SprocketExporter(script: script, assets: ["c1": src], matteMaker: failing, matteCacheDirectory: freshCache("fail"))
        _ = try await ex.still(frame: 0)
        XCTAssertTrue(ex.warnings.contains { $0.contains("boom") }, "\(ex.warnings)")
    }

    func testAFrameThatVisionCannotMaskIsBlackAndTheRestContinue() async throws {
        let src = try clip()
        let out = Self.dir.appendingPathComponent("throwing-mask.mp4")
        let flaky: MatteFrameMasker = { frame, o, s, k in
            CVPixelBufferLockBaseAddress(frame, .readOnly); defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
            let red = Int(base[(CVPixelBufferGetHeight(frame) / 2) * CVPixelBufferGetBytesPerRow(frame) + (CVPixelBufferGetWidth(frame) / 2) * 4 + 2])
            if red < 100 { throw SprocketError(.render, "no mask") }     // frames 0...24
            return try CutoutTests.leftHalf(frame, o, s, k)
        }
        let n = try await MatteMaker.make(input: src, output: out, kind: .subject, ranges: nil, maxSide: 64, masker: flaky)
        XCTAssertEqual(n, 60, "every frame is written, failed ones black")
        let store = MediaVideoStore(assets: ["m": out]); await store.prepare(["m"])
        XCTAssertLessThan(TestMedia.sample(try XCTUnwrap(try store.frame(src: "m", time: 0.2)), x: 5, y: 18).r, 12)
        XCTAssertGreaterThan(TestMedia.sample(try XCTUnwrap(try store.frame(src: "m", time: 1.5)), x: 5, y: 18).r, 235)
    }

    func testPersonMatteMakeStillWorksAtClipSize() async throws {
        let src = try clip()
        let out = Self.dir.appendingPathComponent("personmatte.mp4")
        let n = try await PersonMatte.make(input: src, output: out, maxSeconds: 0.5)
        XCTAssertGreaterThan(n, 10); XCTAssertLessThanOrEqual(n, 17)
        let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width), 128); XCTAssertEqual(Int(size.height), 72)
    }

    // MARK: real footage (Vision)

    func testRealPersonFootageIsCutOut() async throws {
        // A 1280x720 clip of one person in a room (torso around 640,600, head around 560,150, wall at the sides).
        guard let path = ProcessInfo.processInfo.environment["SPROCKET_PERSON_CLIP"] else { throw XCTSkip("set SPROCKET_PERSON_CLIP=/path/to/clip.mp4") }
        let clip = URL(fileURLWithPath: path)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: clip.path), "clip missing")
        let still = Self.dir.appendingPathComponent("real-stills", isDirectory: true)
        try? FileManager.default.createDirectory(at: still, withIntermediateDirectories: true)
        for kind in ["person", "subject"] {
            let script = try SprocketScript(source: """
            composition({ width: 1280, height: 720, fps: 24, durationInFrames: 24 }, function (frame, ctx) {
              const t = 1 + frame / ctx.fps;
              return [video("c1", { time: t }), solid("#ff2d55", { mask: cutout("c1", { time: t, kind: "\(kind)" }), maskMode: "luma" })];
            });
            """)
            let ex = SprocketExporter(script: script, assets: ["c1": clip], matteCacheDirectory: freshCache("real-" + kind))
            let cg = try await ex.still(frame: 12)
            let fill = (r: 255, g: 45, b: 85)
            XCTAssertLessThan(TestMedia.distance(pixel(cg, 640, 600), fill), 12, "\(kind): the torso is filled")
            XCTAssertLessThan(TestMedia.distance(pixel(cg, 560, 150), fill), 12, "\(kind): the head is filled")
            XCTAssertGreaterThan(TestMedia.distance(pixel(cg, 60, 300), fill), 60, "\(kind): the wall is not")
            XCTAssertGreaterThan(TestMedia.distance(pixel(cg, 1150, 300), fill), 60, "\(kind): the window is not")
            XCTAssertTrue(ex.warnings.isEmpty, "\(ex.warnings)")
            let dest = still.appendingPathComponent("person-\(kind).png") as CFURL
            if let d = CGImageDestinationCreateWithURL(dest, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d) }
        }
    }

    /// Prints mask frames per second for a 1280x720 clip, per kind (a measurement, not an assertion on speed).
    func testMeasureMaskSpeedOnRealFootage() async throws {
        guard let path = ProcessInfo.processInfo.environment["SPROCKET_PERSON_CLIP"] else { throw XCTSkip("set SPROCKET_PERSON_CLIP=/path/to/clip.mp4") }
        let clip = URL(fileURLWithPath: path)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: clip.path), "clip missing")
        for kind in MatteKind.allCases {
            let out = Self.dir.appendingPathComponent("speed-\(kind.rawValue).mp4")
            let t0 = Date()
            let n = try await MatteMaker.make(input: clip, output: out, kind: kind, ranges: [0...4])
            let s = Date().timeIntervalSince(t0)
            print("MASKSPEED \(kind.rawValue): \(n) frames in \(String(format: "%.2f", s)) s = \(String(format: "%.1f", Double(n) / s)) fps (1280x720 clip, working side \(MatteMaker.defaultWorkingSide))")
            XCTAssertGreaterThan(n, 90)
        }
    }
}
