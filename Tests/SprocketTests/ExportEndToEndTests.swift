import XCTest
import AVFoundation
import CoreImage
@testable import Sprocket

/// Needs the real SprocketScript and SprocketRenderer. Run with SPROCKET_E2E=1.
final class ExportEndToEndTests: XCTestCase {
    static let dir = TestMedia.tempDir("e2e")

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPROCKET_E2E"] == "1", "set SPROCKET_E2E=1 to run (needs SprocketScript and SprocketRenderer)")
    }

    func testExportsTwoSecondComposition() async throws {
        let src = Self.dir.appendingPathComponent("src.mov")
        try TestMedia.makeCodedMovie(url: src, width: 180, height: 320, frames: 60)
        let tone = Self.dir.appendingPathComponent("tone.wav")
        try TestMedia.makeTone(url: tone, seconds: 3)
        let script = try SprocketScript(source: """
        composition({ width: 180, height: 320, fps: 30, durationInFrames: 60,
                      audio: [{ src: "tone", volume: 0.8, fadeOut: 0.2 }] },
          function (frame, ctx) { return [video("c1", { time: frame / ctx.fps })]; });
        """)
        let out = Self.dir.appendingPathComponent("e2e.mp4")
        let exporter = SprocketExporter(script: script, assets: ["c1": src, "tone": tone])
        let t0 = Date()
        try await exporter.export(to: out)
        print("e2e export: 60 frames in \(Date().timeIntervalSince(t0)) s")

        let asset = AVURLAsset(url: out)
        let dur = try await asset.load(.duration).seconds
        XCTAssertEqual(dur, 2.0, accuracy: 0.06)
        let vTrack = try await asset.loadTracks(withMediaType: .video).first
        let v = try XCTUnwrap(vTrack)
        let size = try await v.load(.naturalSize)
        XCTAssertEqual(Int(size.width), 180); XCTAssertEqual(Int(size.height), 320)
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        let a = try XCTUnwrap(aTrack)
        let aDur = try await a.load(.timeRange).duration.seconds
        XCTAssertEqual(aDur, 2.0, accuracy: 0.08)
        let reader = try AVAssetReader(asset: asset)
        let vo = AVAssetReaderTrackOutput(track: v, outputSettings: nil)
        reader.add(vo); reader.startReading()
        var n = 0
        while let sb = vo.copyNextSampleBuffer() { n += CMSampleBufferGetNumSamples(sb) }
        XCTAssertEqual(n, 60)

        // frame 30 of the output should be frame 30 of the source
        let srcStore = MediaVideoStore(assets: ["s": src]); await srcStore.prepare(["s"])
        let outStore = MediaVideoStore(assets: ["o": out]); await outStore.prepare(["o"])
        let want = TestMedia.sampleCentre(try XCTUnwrap(try srcStore.frame(src: "s", time: 1.0)))
        let got = TestMedia.sampleCentre(try XCTUnwrap(try outStore.frame(src: "o", time: 1.0)))
        XCTAssertLessThan(TestMedia.distance(want, got), 20, "output frame 30 \(got) vs source frame 30 \(want)")

        let still = try await exporter.still(frame: 30)
        XCTAssertEqual(still.width, 180); XCTAssertEqual(still.height, 320)
    }
}
