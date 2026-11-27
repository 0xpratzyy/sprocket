import XCTest
import AVFoundation
import CoreImage
@testable import Sprocket

/// The movie writer, driven by a plain frame closure (no script or renderer involved).
final class ExportWriterTests: XCTestCase {
    static let dir = TestMedia.tempDir("writer")

    private func solid(_ k: Int, _ w: Int, _ h: Int) -> CIImage {
        let c = TestMedia.color(forFrame: k)
        return CIImage(color: CIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255,
                                      colorSpace: TestMedia.srgb)!).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    func testBitrateScalesWithResolution() {
        XCTAssertEqual(ExportEngine.bitrate(width: 1080, height: 1920, fps: 30), 12_000_000)
        XCTAssertEqual(ExportEngine.bitrate(width: 540, height: 960, fps: 30), 3_000_000)
        XCTAssertEqual(ExportEngine.bitrate(width: 1080, height: 1920, fps: 60), 24_000_000)
    }

    func testWritesVideoAndSound() async throws {
        let tone = Self.dir.appendingPathComponent("tone.wav")
        try TestMedia.makeTone(url: tone, seconds: 3.0)
        let out = Self.dir.appendingPathComponent("out-av.mp4")
        let config = CompositionConfig(width: 160, height: 90, fps: 30, durationInFrames: 60, audio: [
            .init(src: "t", startFrame: 0, offset: nil, durationInFrames: nil, volume: 0.8, fadeIn: nil, fadeOut: 0.2)], background: nil)
        let audio = await MediaAudioMix.build(config: config, assets: ["t": tone])
        final class Counter: @unchecked Sendable { var last = 0; var n = 0 }
        let counter = Counter()
        try await ExportEngine.run(config: config, to: out, audio: audio, progress: { p in
            counter.last = p.frame; counter.n += 1; XCTAssertEqual(p.total, 60)
        }, frame: { [self] k in solid(k % 60, 160, 90) })
        XCTAssertEqual(counter.last, 60); XCTAssertEqual(counter.n, 60)

        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2.0, accuracy: 0.06)
        let vTrack = try await asset.loadTracks(withMediaType: .video).first
        let v = try XCTUnwrap(vTrack)
        let size = try await v.load(.naturalSize)
        XCTAssertEqual(Int(size.width), 160); XCTAssertEqual(Int(size.height), 90)
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        let a = try XCTUnwrap(aTrack, "audio track exists")
        let aDur = try await a.load(.timeRange).duration.seconds
        XCTAssertEqual(aDur, 2.0, accuracy: 0.08)
        let fmt = try await v.load(.formatDescriptions).first
        let ext = CMFormatDescriptionGetExtensions(fmt!) as? [String: Any]
        XCTAssertEqual(ext?["CVImageBufferColorPrimaries"] as? String, "ITU_R_709_2")
        XCTAssertEqual(ext?["CVImageBufferYCbCrMatrix"] as? String, "ITU_R_709_2")

        // frame count and colours: read the file back with the store
        let store = MediaVideoStore(assets: ["o": out])
        await store.prepare(["o"])
        let reader = try AVAssetReader(asset: asset)
        let vo = AVAssetReaderTrackOutput(track: v, outputSettings: nil)
        reader.add(vo); reader.startReading()
        var frames = 0
        while let sb = vo.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sb) }
        XCTAssertEqual(frames, 60)
        for k in [0, 17, 30, 59] {
            let img = try XCTUnwrap(try store.frame(src: "o", time: Double(k) / 30))
            let got = TestMedia.sampleCentre(img)
            let c = TestMedia.color(forFrame: k)
            XCTAssertLessThan(TestMedia.distance(got, (Int(c.r), Int(c.g), Int(c.b))), 24, "frame \(k) colour \(got) vs \(c)")
        }
        // audio level: 0.8 / sqrt(2) = 0.566 mid-file, tail faded
        let rms = try await TestMedia.rmsProfile(of: asset, window: 0.1, seconds: 2.0)
        XCTAssertEqual(rms[10], 0.8 * 0.8 / 2.0.squareRoot(), accuracy: 0.06)
        XCTAssertLessThan(rms[19], rms[10] * 0.6)
    }

    func testNoAudioClipsMeansNoAudioTrack() async throws {
        let out = Self.dir.appendingPathComponent("out-silent.mp4")
        let config = CompositionConfig(width: 64, height: 64, fps: 30, durationInFrames: 12, audio: nil, background: nil)
        try await ExportEngine.run(config: config, to: out, audio: nil, progress: nil, frame: { [self] k in solid(k, 64, 64) })
        let asset = AVURLAsset(url: out)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audioTracks.isEmpty)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
    }

    func testCancellationRemovesPartialFile() async throws {
        let out = Self.dir.appendingPathComponent("out-cancel.mp4")
        let config = CompositionConfig(width: 64, height: 64, fps: 30, durationInFrames: 3000, audio: nil, background: nil)
        let task = Task {
            try await ExportEngine.run(config: config, to: out, audio: nil, progress: nil, frame: { [self] k in
                Thread.sleep(forTimeInterval: 0.004); return solid(k % 60, 64, 64)
            })
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()
        do { try await task.value; XCTFail("should have thrown") }
        catch let e as SprocketError { XCTAssertEqual(e.kind, .cancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testFrameFailureIsReportedAndFileRemoved() async throws {
        let out = Self.dir.appendingPathComponent("out-fail.mp4")
        let config = CompositionConfig(width: 64, height: 64, fps: 30, durationInFrames: 30, audio: nil, background: nil)
        do {
            try await ExportEngine.run(config: config, to: out, audio: nil, progress: nil, frame: { [self] k in
                if k == 5 { throw SprocketError(.script, "boom", line: 7) }
                return solid(k, 64, 64)
            })
            XCTFail("should have thrown")
        } catch let e as SprocketError {
            XCTAssertEqual(e.kind, .script); XCTAssertEqual(e.line, 7)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testInvalidConfigIsAnExportError() async {
        let config = CompositionConfig(width: 0, height: 64, fps: 30, durationInFrames: 30, audio: nil, background: nil)
        do {
            try await ExportEngine.run(config: config, to: Self.dir.appendingPathComponent("x.mp4"), audio: nil, progress: nil, frame: { _ in CIImage() })
            XCTFail("should have thrown")
        } catch let e as SprocketError { XCTAssertEqual(e.kind, .export) } catch { XCTFail("\(error)") }
    }
}
