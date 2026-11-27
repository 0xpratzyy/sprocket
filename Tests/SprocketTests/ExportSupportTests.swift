import XCTest
import AVFoundation
import CoreImage
import ImageIO
@testable import Sprocket

/// Helpers shared by the Export*Tests files: generated movies, tones, and pixel sampling. No personal media.
enum TestMedia {
    static let ciContext = CIContext()
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func tempDir(_ name: String = UUID().uuidString) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sprocket-tests-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Colour that encodes frame number k (0..<64): R and G run in opposite directions, B spreads the rest.
    static func color(forFrame k: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        (UInt8(k * 4), UInt8(255 - k * 4), UInt8((k * 37) % 256))
    }

    /// Writes an H.264 movie; `fill` paints BGRA pixels for frame k.
    static func makeMovie(url: URL, width: Int, height: Int, frames: Int, fps: Int = 30,
                          transform: CGAffineTransform = .identity,
                          fill: (_ k: Int, _ base: UnsafeMutablePointer<UInt8>, _ bytesPerRow: Int) -> Void) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000, AVVideoMaxKeyFrameIntervalKey: 15] as [String: Any],
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for k in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            var pbOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pbOut)
            let pb = pbOut!
            CVPixelBufferLockBaseAddress(pb, [])
            fill(k, CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRow(pb))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(k), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw SprocketError(.export, "test movie failed: \(String(describing: writer.error))") }
    }

    /// 2 s (by default) at 30 fps; frame k is a solid colour encoding k.
    static func makeCodedMovie(url: URL, width: Int = 128, height: Int = 72, frames: Int = 60) throws {
        try makeMovie(url: url, width: width, height: height, frames: frames) { k, base, bpr in
            let c = color(forFrame: k)
            for y in 0..<height {
                let row = base + y * bpr
                for x in 0..<width { row[x * 4] = c.b; row[x * 4 + 1] = c.g; row[x * 4 + 2] = c.r; row[x * 4 + 3] = 255 }
            }
        }
    }

    /// Mono sine wave as a 48 kHz 16-bit WAV.
    static func makeTone(url: URL, seconds: Double, frequency: Double = 440, amplitude: Float = 0.8) throws {
        try? FileManager.default.removeItem(at: url)
        let rate = 48_000.0
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        let n = AVAudioFrameCount(seconds * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n)!
        buf.frameLength = n
        let p = buf.floatChannelData![0]
        for i in 0..<Int(n) { p[i] = amplitude * Float(sin(2 * Double.pi * frequency * Double(i) / rate)) }
        try file.write(from: buf)
    }

    /// RGB at (x, y) measured from the top-left of the image.
    static func sample(_ image: CIImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        var px = [UInt8](repeating: 0, count: 4)
        let h = Int(image.extent.height)
        ciContext.render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: h - 1 - y, width: 1, height: 1),
                         format: .RGBA8, colorSpace: srgb)
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    static func sampleCentre(_ image: CIImage) -> (r: Int, g: Int, b: Int) {
        sample(image, x: Int(image.extent.width) / 2, y: Int(image.extent.height) / 2)
    }

    static func distance(_ a: (r: Int, g: Int, b: Int), _ b: (r: Int, g: Int, b: Int)) -> Int {
        max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
    }

    /// Frame numbers of a coded movie as seen by a store: classifies a sampled colour against a table built
    /// from the movie itself, read once forward at exact frame times (and sanity-checked against the encoded colours).
    static func codedTable(store: MediaVideoStore, id: String, frames: Int = 60, fps: Double = 30) throws -> [(r: Int, g: Int, b: Int)] {
        var table: [(r: Int, g: Int, b: Int)] = []
        for k in 0..<frames {
            guard let img = try store.frame(src: id, time: Double(k) / fps) else { throw SprocketError(.asset, "no frame \(k)") }
            table.append(sampleCentre(img))
        }
        return table
    }

    static func classify(_ c: (r: Int, g: Int, b: Int), in table: [(r: Int, g: Int, b: Int)]) -> Int {
        var best = 0, bestD = Int.max
        for (k, t) in table.enumerated() {
            let d = abs(c.r - t.r) + abs(c.g - t.g) + abs(c.b - t.b)
            if d < bestD { bestD = d; best = k }
        }
        return best
    }

    /// Mean-square-root level of mono-mixed PCM per window, from an AVAssetReader audio output. Returns RMS per `window` seconds.
    static func rmsProfile(of asset: AVAsset, window: Double = 0.1, seconds: Double) async throws -> [Double] {
        let track = try await asset.loadTracks(withMediaType: .audio).first!
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: MediaAudioMix.pcmSettings)
        reader.add(out)
        reader.startReading()
        return try readRMS(from: out, reader: reader, window: window, seconds: seconds)
    }

    static func readRMS(from output: AVAssetReaderOutput, reader: AVAssetReader, window: Double, seconds: Double) throws -> [Double] {
        let rate = 48_000.0
        let bins = Int((seconds / window).rounded(.up))
        var sumSq = [Double](repeating: 0, count: bins)
        var counts = [Int](repeating: 0, count: bins)
        var placed = 0.0   // sample index of the next sample, advanced by pts when there are gaps
        while let sb = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            placed = max(placed, (pts * rate).rounded())
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
            let floats = UnsafeBufferPointer(start: UnsafeRawPointer(ptr!).assumingMemoryBound(to: Float.self), count: length / 4)
            var i = 0
            while i + 1 < floats.count {
                let mono = Double(floats[i] + floats[i + 1]) / 2
                let bin = Int(placed / rate / window)
                if bin < bins { sumSq[bin] += mono * mono; counts[bin] += 1 }
                placed += 1; i += 2
            }
        }
        if reader.status == .failed { throw reader.error! }
        return (0..<bins).map { counts[$0] > 0 ? (sumSq[$0] / Double(counts[$0])).squareRoot() : 0 }
    }
}
