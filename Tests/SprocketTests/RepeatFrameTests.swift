import XCTest
import AVFoundation
import CoreImage
@testable import Sprocket

/// Repeated frames: a frame whose tree equals the previous frame's is written again without being drawn.
final class RepeatFrameTests: XCTestCase {
    static let dir = TestMedia.tempDir("repeat")

    private func frameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let v = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: v, outputSettings: nil)
        reader.add(out); reader.startReading()
        var n = 0
        while let sb = out.copyNextSampleBuffer() { n += CMSampleBufferGetNumSamples(sb) }
        return n
    }

    private func centre(_ url: URL, frame k: Int, fps: Int = 30) async throws -> (r: Int, g: Int, b: Int) {
        let store = MediaVideoStore(assets: ["o": url])
        await store.prepare(["o"])
        defer { store.closeAll() }
        let img = try store.frame(src: "o", time: Double(k) / Double(fps))
        return TestMedia.sampleCentre(try XCTUnwrap(img))
    }

    private func export(_ source: String, name: String) async throws -> (URL, SprocketExporter) {
        let out = Self.dir.appendingPathComponent(name)
        let ex = SprocketExporter(script: try SprocketScript(source: source), assets: [:])
        try await ex.export(to: out)
        return (out, ex)
    }

    // MARK: the writer

    func testWriterRepeatsTheLastBufferWhenTheFrameIsNil() async throws {
        let out = Self.dir.appendingPathComponent("writer-nil.mp4")
        let config = CompositionConfig(width: 64, height: 64, fps: 30, durationInFrames: 20, audio: nil, background: nil)
        try await ExportEngine.run(config: config, to: out, audio: nil, progress: nil, frame: { k in
            guard k % 2 == 0 else { return nil }
            let c = TestMedia.color(forFrame: k)
            return CIImage(color: CIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, colorSpace: TestMedia.srgb)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        })
        let n = try await frameCount(out)
        XCTAssertEqual(n, 20, "every frame index is written, drawn or not")
        for k in [1, 7, 19] {
            let got = try await centre(out, frame: k)
            let c = TestMedia.color(forFrame: k - 1)
            XCTAssertLessThan(TestMedia.distance(got, (Int(c.r), Int(c.g), Int(c.b))), 24, "frame \(k) repeats frame \(k - 1): \(got) vs \(c)")
        }
    }

    // MARK: the exporter

    func testOnTwosHalfTheFramesAreReused() async throws {
        let (out, ex) = try await export("""
        composition({ width: 64, height: 64, fps: 30, durationInFrames: 20 }, function (f) {
          const g = f - (f % 2);
          return [solid("rgb(" + (g * 12) + ", 40, 200)")];
        });
        """, name: "twos.mp4")
        XCTAssertEqual(ex.framesReused, 10)
        let n = try await frameCount(out)
        XCTAssertEqual(n, 20)
        let f4 = try await centre(out, frame: 4), f5 = try await centre(out, frame: 5), f6 = try await centre(out, frame: 6)
        XCTAssertLessThan(TestMedia.distance(f4, f5), 6, "frame 5 is frame 4 held: \(f4) vs \(f5)")
        XCTAssertLessThan(TestMedia.distance(f5, (48, 40, 200)), 24, "\(f5)")
        XCTAssertLessThan(TestMedia.distance(f6, (72, 40, 200)), 24, "frame 6 is a new pose: \(f6)")
    }

    func testAStillFilmDrawsOneFrameAndKeepsItsPicture() async throws {
        let (out, ex) = try await export("""
        composition({ width: 64, height: 64, fps: 30, durationInFrames: 24 }, function (f) {
          return [solid("#ff8800"), rect(16, 16, 32, 32, { color: "#0044ff" })];
        });
        """, name: "still.mp4")
        XCTAssertEqual(ex.framesReused, 23)
        let n = try await frameCount(out)
        XCTAssertEqual(n, 24)
        let last = try await centre(out, frame: 23)
        XCTAssertLessThan(TestMedia.distance(last, (0, 68, 255)), 24, "the last frame still shows the picture, not black: \(last)")
    }

    func testAFilmThatMovesEveryFrameReusesNothing() async throws {
        let (_, ex) = try await export("""
        composition({ width: 64, height: 64, fps: 30, durationInFrames: 12 }, function (f) {
          return [solid("#000"), rect(f * 4, 0, 8, 64, { color: "#fff" })];
        });
        """, name: "moving.mp4")
        XCTAssertEqual(ex.framesReused, 0)
    }

    func testAnHtmlLayerOnTheDefaultClockIsNeverARepeat() throws {
        // html() without a time runs on the composition's clock, so the resolved trees differ even when the script's do.
        let ex = SprocketExporter(script: try SprocketScript(source: """
        composition({ width: 64, height: 64, fps: 30, durationInFrames: 4 }, function (f) {
          return [html("<div style='width:10px;height:10px;background:red'></div>")];
        });
        """), assets: [:])
        let tracker = SprocketExporter.RepeatTracker()
        XCTAssertFalse(tracker.isRepeat(try ex.resolvedNode(frame: 0)))
        XCTAssertFalse(tracker.isRepeat(try ex.resolvedNode(frame: 1)), "page time 0 s vs 1/30 s")
    }

    func testAVideoNodeHoldingOneSourceTimeIsARepeat() throws {
        // A frozen video (the same source time) is the same picture; a playing one is not.
        let ex = SprocketExporter(script: try SprocketScript(source: """
        composition({ width: 64, height: 64, fps: 30, durationInFrames: 4 }, function (f) {
          return [video("c1", { time: 1.5 }), video("c2", { time: f / 30 })];
        });
        """), assets: [:])
        let a = try ex.resolvedNode(frame: 0), b = try ex.resolvedNode(frame: 1)
        XCTAssertNotEqual(a, b, "the playing clip changes the tree")
        let frozen = SprocketExporter(script: try SprocketScript(source: """
        composition({ width: 64, height: 64, fps: 30, durationInFrames: 4 }, function (f) { return [video("c1", { time: 1.5 })]; });
        """), assets: [:])
        XCTAssertEqual(try frozen.resolvedNode(frame: 0), try frozen.resolvedNode(frame: 3))
    }
}
