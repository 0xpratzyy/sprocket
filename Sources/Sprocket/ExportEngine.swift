import Foundation
import AVFoundation
import CoreImage
import CoreVideo

/// Writes frames and sound to an .mp4. Knows nothing about scripts: `frame` returns the picture for a frame index,
/// or nil when the frame is the same picture as the one before it (then the last written buffer is appended again
/// without drawing anything).
enum ExportEngine {
    static func bitrate(width: Int, height: Int, fps: Int) -> Int {
        let scale = Double(width * height) / Double(1080 * 1920) * Double(max(1, fps)) / 30.0
        return max(1_000_000, Int(12_000_000 * scale))
    }

    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func run(config: CompositionConfig, to url: URL, audio: MediaAudioMix?,
                    progress: (@Sendable (SprocketExporter.Progress) -> Void)?,
                    frame: @escaping @Sendable (Int) throws -> CIImage?) async throws {
        let w = config.width, h = config.height, fps = config.fps, total = config.durationInFrames
        guard w > 0, h > 0, fps > 0, total > 0 else {
            throw SprocketError(.export, "invalid composition size \(w)x\(h), \(fps) fps, \(total) frames")
        }
        if Task.isCancelled { throw SprocketError(.cancelled, "export cancelled") }
        let fm = FileManager.default
        try? fm.removeItem(at: url)

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) }
        catch { throw SprocketError(.export, "cannot create the movie file: \(error.localizedDescription)") }

        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate(width: w, height: h, fps: fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any],
        ])
        vInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        // From here until the pumps take over, any failure must leave nothing behind.
        var handedOver = false
        defer { if !handedOver { ExportEngine.abandon(writer, output: url) } }
        guard writer.canAdd(vInput) else { throw SprocketError(.export, "cannot add the video track") }
        writer.add(vInput)

        var aInput: AVAssetWriterInput?
        var aReader: AVAssetReader?
        var aOutput: AVAssetReaderAudioMixOutput?
        if let audio {
            let (r, o) = try audio.makeReader()
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            ai.expectsMediaDataInRealTime = false
            guard writer.canAdd(ai) else { throw SprocketError(.export, "cannot add the audio track") }
            writer.add(ai)
            aInput = ai; aReader = r; aOutput = o
        }
        writer.shouldOptimizeForNetworkUse = true

        guard writer.startWriting() else {
            throw SprocketError(.export, "cannot start writing: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        writer.startSession(atSourceTime: .zero)
        if let aReader, !aReader.startReading() {
            throw SprocketError(.export, "cannot read the audio mix: \(aReader.error?.localizedDescription ?? "unknown error")")
        }

        let state = ExportState(writer: writer, audioReader: aReader, url: url, pumps: aInput == nil ? 1 : 2)
        handedOver = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                state.continuation = cont
                let vq = DispatchQueue(label: "sprocket.export.video", qos: .userInitiated)
                var next = 0
                var rendered = 0
                var last: CVPixelBuffer?
                vInput.requestMediaDataWhenReady(on: vq) {
                    while vInput.isReadyForMoreMediaData {
                        if state.isFinished { return }
                        if state.isCancelled { state.fail(SprocketError(.cancelled, "export cancelled")); return }
                        if next >= total { vInput.markAsFinished(); state.pumpDone(); return }
                        var failure: Error?
                        autoreleasepool {
                            do {
                                let pb: CVPixelBuffer
                                if let image = try frame(next) ?? (last == nil ? CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: w, height: h)) : nil) {
                                    guard let pool = adaptor.pixelBufferPool else { throw SprocketError(.export, "no pixel buffer pool") }
                                    var pbOut: CVPixelBuffer?
                                    let st = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
                                    guard st == kCVReturnSuccess, let fresh = pbOut else { throw SprocketError(.export, "out of pixel buffers (\(st))") }
                                    tag709(fresh)
                                    SprocketRenderer.context.render(image, to: fresh,
                                                                  bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: colorSpace)
                                    pb = fresh
                                    last = fresh
                                    rendered += 1
                                } else {
                                    // The same picture as the frame before: write the last buffer again (the encoder only reads it).
                                    pb = last!
                                }
                                let t = CMTime(value: CMTimeValue(next), timescale: CMTimeScale(fps))
                                guard adaptor.append(pb, withPresentationTime: t) else {
                                    throw SprocketError(.export, "cannot append frame \(next): \(writer.error?.localizedDescription ?? "writer failed")")
                                }
                            } catch let e as SprocketError { failure = e }
                            catch { failure = SprocketError(.render, "frame \(next): \(error.localizedDescription)") }
                        }
                        if let failure { state.fail(failure); return }
                        next += 1
                        if rendered > 0 && rendered % 120 == 0 { SprocketRenderer.context.clearCaches() }
                        progress?(SprocketExporter.Progress(frame: next, total: total))
                    }
                }
                if let aInput, let aOutput, let aReader {
                    let aq = DispatchQueue(label: "sprocket.export.audio", qos: .userInitiated)
                    // The mix ends when its last clip ends; silence is appended so the audio track lasts as long as the picture.
                    let targetSamples = Int64((Double(total) / Double(fps) * Double(AudioSilence.sampleRate)).rounded())
                    var endSamples: Int64 = 0
                    var format: CMFormatDescription?
                    var padding = false
                    aInput.requestMediaDataWhenReady(on: aq) {
                        while aInput.isReadyForMoreMediaData {
                            if state.isFinished { return }
                            if state.isCancelled { state.fail(SprocketError(.cancelled, "export cancelled")); return }
                            var done = false
                            var failure: Error?
                            autoreleasepool {
                                if !padding {
                                    if let sb = aOutput.copyNextSampleBuffer() {
                                        if format == nil { format = CMSampleBufferGetFormatDescription(sb) }
                                        let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sb), CMSampleBufferGetDuration(sb))
                                        if end.isNumeric { endSamples = max(endSamples, Int64((end.seconds * Double(AudioSilence.sampleRate)).rounded())) }
                                        if !aInput.append(sb) {
                                            failure = SprocketError(.export, "cannot append audio: \(writer.error?.localizedDescription ?? "writer failed")")
                                        }
                                        return
                                    } else if aReader.status == .failed {
                                        failure = SprocketError(.export, "audio read failed: \(aReader.error?.localizedDescription ?? "unknown error")")
                                        return
                                    }
                                    padding = true
                                }
                                let remaining = targetSamples - endSamples
                                if remaining <= 0 { done = true; return }
                                let n = Int(min(remaining, 4800))
                                guard let sb = AudioSilence.buffer(format: format, startSample: endSamples, frames: n) else {
                                    failure = SprocketError(.export, "cannot create the silent audio padding")
                                    return
                                }
                                if aInput.append(sb) { endSamples += Int64(n) }
                                else { failure = SprocketError(.export, "cannot append audio padding: \(writer.error?.localizedDescription ?? "writer failed")") }
                            }
                            if let failure { state.fail(failure); return }
                            if done { aInput.markAsFinished(); state.pumpDone(); return }
                        }
                    }
                }
            }
        } onCancel: {
            state.requestCancel()
        }
    }

    /// Removes the output file and any temporary file AVAssetWriter left beside it (`name.mp4.sb-xxxx`).
    static func removePartialOutput(_ url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        let dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".sb-"
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(prefix) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    /// Cancels a writer and waits (briefly) until it has let go of its files, then removes them.
    static func abandon(_ writer: AVAssetWriter, output url: URL) {
        if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
        var waited = 0
        while writer.status == .writing && waited < 200 { Thread.sleep(forTimeInterval: 0.01); waited += 1 }
        removePartialOutput(url)
    }

    static func tag709(_ pb: CVPixelBuffer) {
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
}

/// Shared between the two writer queues: first failure wins, the file is removed on failure, the continuation resumes once.
final class ExportState: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let audioReader: AVAssetReader?
    private let url: URL
    private var pending: Int
    private var cancelled = false
    private var finished = false
    var continuation: CheckedContinuation<Void, Error>?

    init(writer: AVAssetWriter, audioReader: AVAssetReader?, url: URL, pumps: Int) {
        self.writer = writer; self.audioReader = audioReader; self.url = url; self.pending = pumps
    }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func requestCancel() { lock.lock(); cancelled = true; lock.unlock() }

    func fail(_ error: Error) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        audioReader?.cancelReading()
        ExportEngine.abandon(writer, output: url)
        cont?.resume(throwing: error)
    }

    func pumpDone() {
        lock.lock()
        pending -= 1
        if pending > 0 || finished { lock.unlock(); return }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        let writer = self.writer, url = self.url
        writer.finishWriting {
            if writer.status == .completed {
                cont?.resume()
            } else {
                ExportEngine.removePartialOutput(url)
                cont?.resume(throwing: SprocketError(.export, "writing failed: \(writer.error?.localizedDescription ?? "unknown error")"))
            }
        }
    }
}
