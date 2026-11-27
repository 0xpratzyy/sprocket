import Foundation
import AVFoundation
import Vision
import CoreImage

/// What a cut-out mask is of.
public enum MatteKind: String, Sendable, CaseIterable {
    /// People (VNGeneratePersonSegmentationRequest, accurate quality).
    case person
    /// The main foreground thing of any kind (VNGenerateForegroundInstanceMaskRequest, all instances merged).
    case subject
}

/// Makes a cut-out mask video for a clip: white where a person is, black elsewhere, one mask frame per source frame.
/// A composition uses it as `mask: video("matte", { time }), maskMode: "luma"`, or, with no pre-made file at all,
/// `mask: cutout("c1", { time }), maskMode: "luma"` (the exporter then calls `MatteMaker` itself).
public enum PersonMatte {
    /// Writes an H.264 .mp4 the same size and timing as `input`. Returns the number of frames written.
    /// `maxSeconds` stops after that much of the clip (a long clip whose opening is all that is used).
    @discardableResult
    public static func make(input: URL, output: URL, maxSeconds: Double? = nil) async throws -> Int {
        try await MatteMaker.make(input: input, output: output, kind: .person,
                                  ranges: maxSeconds.map { [0...max(0, $0)] }, maxSide: nil)
    }
}

/// Decides, for one decoded clip frame, what the mask looks like.
/// `frame` is BGRA in the clip's stored orientation; `orientation` makes it upright; `size` is the upright size the
/// mask will be written at. Returns a white-on-black image (any size, any origin; it is scaled to `size`). Throwing means
/// "no mask for this frame": the maker writes a black frame and carries on.
public typealias MatteFrameMasker = @Sendable (_ frame: CVPixelBuffer, _ orientation: CGImagePropertyOrientation,
                                              _ size: CGSize, _ kind: MatteKind) throws -> CIImage

/// Writes a mask video for (a time range of) a clip.
public enum MatteMaker {
    /// Long side Vision runs at, and the mask video is written at, unless the caller says otherwise.
    public static let defaultWorkingSide = 768
    /// Gaussian sigma (in mask pixels) that softens the edges of a reduced-size mask so it does not look blocky once upscaled.
    static let featherSigma = 0.9

    /// Writes an H.264 .mp4 with one mask frame per source frame, at the source frames' own presentation times, for the
    /// given time ranges (seconds; `nil` = the whole clip). Frames outside the ranges are not written (the file has gaps).
    /// `maxSide` limits the long side of the working and output size (`nil` = the clip's own size).
    /// `masker` decides what a frame's mask is; the default asks Vision. Returns the number of frames written.
    /// `progress` gets (frames done, frames expected). Throws SprocketError(.asset) if the clip cannot be read.
    @discardableResult
    public static func make(input: URL, output: URL, kind: MatteKind, ranges: [ClosedRange<Double>]? = nil,
                            maxSide: Int? = MatteMaker.defaultWorkingSide,
                            masker: MatteFrameMasker? = nil,
                            progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Int {
        try? FileManager.default.removeItem(at: output)
        let masker = masker ?? Self.visionMasker
        let asset = AVURLAsset(url: input)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            throw SprocketError(.asset, "no video track in \(input.lastPathComponent)")
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let fps = max(1, Double((try? await track.load(.nominalFrameRate)) ?? 30))
        let upright = CGRect(origin: .zero, size: natural).applying(transform)
        let orientation = MediaVideoStore.orientation(for: transform)
        let swaps = abs(upright.width - natural.width) > 1 && abs(upright.height - natural.height) > 1

        // Working size (stored orientation) and the upright size of the written mask. Both even.
        func even(_ v: Double) -> Int { max(2, Int(v.rounded()) / 2 * 2) }
        var scale = 1.0
        if let maxSide, maxSide > 0 { scale = min(1, Double(maxSide) / max(1, max(natural.width, natural.height))) }
        let reduced = scale < 1
        let nw = even(Double(natural.width) * scale), nh = even(Double(natural.height) * scale)
        let w = swaps ? nh : nw, h = swaps ? nw : nh

        // Normalise the ranges: inside the clip, ordered, non-overlapping.
        let full = 0...max(duration, 0.001)
        var spans = (ranges ?? [full]).map { max(0, $0.lowerBound)...max(0, $0.upperBound) }
        spans.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for s in spans {
            if let last = merged.last, s.lowerBound <= last.upperBound { merged[merged.count - 1] = last.lowerBound...max(last.upperBound, s.upperBound) }
            else { merged.append(s) }
        }
        let expected = max(1, Int(merged.reduce(0) { $0 + min($1.upperBound, duration > 0 ? duration : $1.upperBound) - min($1.lowerBound, duration > 0 ? duration : $1.lowerBound) } * fps))

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, w * h * 6),
                AVVideoMaxKeyFrameIntervalKey: 24,
            ] as [String: Any],
        ])
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(writerInput)
        guard writer.startWriting() else { throw SprocketError(.export, writer.error?.localizedDescription ?? "cannot write the mask") }
        writer.startSession(atSourceTime: .zero)

        var succeeded = false
        defer { if !succeeded { writer.cancelWriting(); try? FileManager.default.removeItem(at: output) } }

        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)
        let sizeUpright = CGSize(width: w, height: h)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: bounds)
        let pool = ScalePool()
        var frames = 0
        var lastPTS = -Double.infinity

        for span in merged {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            out.alwaysCopiesSampleData = false
            reader.add(out)
            let start = CMTime(seconds: span.lowerBound, preferredTimescale: 6000)
            let end = CMTime(seconds: span.upperBound, preferredTimescale: 6000)
            reader.timeRange = CMTimeRange(start: start, end: max(end, start + CMTime(value: 1, timescale: 6000)))
            guard reader.startReading() else {
                throw SprocketError(.asset, "cannot read \(input.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown error")")
            }
            defer { reader.cancelReading() }

            while true {
                try Task.checkCancellation()
                var target: CVPixelBuffer?
                var pts = 0.0
                var finished = false
                autoreleasepool {
                    guard let sample = out.copyNextSampleBuffer() else { finished = true; return }
                    guard var frame = CMSampleBufferGetImageBuffer(sample) else { return }
                    pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    guard pts > lastPTS + 1e-6 else { return }
                    if reduced, let small = Self.downscale(frame, to: pool.next(width: nw, height: nh), width: nw, height: nh) { frame = small }
                    var mask = black
                    if let raw = try? masker(frame, orientation, sizeUpright, kind) { mask = Self.fit(raw, to: bounds, feather: reduced) ?? black }
                    var buffer: CVPixelBuffer?
                    if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
                    guard let b = buffer else { return }
                    SprocketRenderer.context.render(mask, to: b, bounds: bounds, colorSpace: srgb)
                    target = b
                }
                if finished { break }
                guard let target else { continue }
                while !writerInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
                guard adaptor.append(target, withPresentationTime: CMTime(seconds: pts, preferredTimescale: 60000)) else {
                    throw SprocketError(.export, writer.error?.localizedDescription ?? "cannot append a mask frame")
                }
                lastPTS = pts
                frames += 1
                if frames % 8 == 0 { progress?(frames, max(expected, frames)) }
            }
            if reader.status == .failed {
                throw SprocketError(.asset, "reading \(input.lastPathComponent) failed: \(reader.error?.localizedDescription ?? "unknown error")")
            }
        }
        guard frames > 0 else { throw SprocketError(.asset, "\(input.lastPathComponent) has no frames in the requested time range") }
        writerInput.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw SprocketError(.export, writer.error?.localizedDescription ?? "the mask was not written") }
        succeeded = true
        progress?(frames, frames)
        return frames
    }

    /// A small BGRA buffer to hold a downscaled clip frame; reused for every frame so memory stays flat.
    final class ScalePool {
        private var buffer: CVPixelBuffer?
        func next(width: Int, height: Int) -> CVPixelBuffer? {
            if let b = buffer, CVPixelBufferGetWidth(b) == width, CVPixelBufferGetHeight(b) == height { return b }
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &out)
            buffer = out
            return out
        }
    }

    /// Lanczos-scales a decoded frame into `target` (the clip is decoded at full size; Vision and the writer only see this).
    static func downscale(_ frame: CVPixelBuffer, to target: CVPixelBuffer?, width: Int, height: Int) -> CVPixelBuffer? {
        guard let target else { return nil }
        let src = CIImage(cvPixelBuffer: frame)
        let e = src.extent
        guard e.width > 0, e.height > 0 else { return nil }
        let sy = Double(height) / e.height
        let aspect = (Double(width) / e.width) / sy
        let scaled = src.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: aspect])
        SprocketRenderer.context.render(scaled.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), to: target,
                                      bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return target
    }

    /// Scales a mask image to exactly `bounds` (origin at zero), copies its first channel into R, G and B (float masks come
    /// out as one channel only), makes it opaque, and softens the edge a little when asked.
    static func fit(_ image: CIImage, to bounds: CGRect, feather: Bool) -> CIImage? {
        let e = image.extent
        guard !e.isInfinite, !e.isNull, e.width > 0, e.height > 0 else { return nil }
        var m = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        if abs(e.width - bounds.width) > 0.01 || abs(e.height - bounds.height) > 0.01 {
            m = m.transformed(by: CGAffineTransform(scaleX: bounds.width / e.width, y: bounds.height / e.height))
        }
        m = m.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        if feather { m = m.clampedToExtent().applyingGaussianBlur(sigma: featherSigma) }
        return m.cropped(to: bounds)
    }

    // MARK: Vision

    /// The default masker.
    static let visionMasker: MatteFrameMasker = { frame, orientation, size, kind in
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, orientation: orientation, options: [:])
        switch kind {
        case .person:
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .accurate
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try handler.perform([request])
            guard let buffer = request.results?.first?.pixelBuffer else { throw SprocketError(.render, "no person mask") }
            return CIImage(cvPixelBuffer: buffer)
        case .subject:
            let request = VNGenerateForegroundInstanceMaskRequest()
            try handler.perform([request])
            guard let obs = request.results?.first, !obs.allInstances.isEmpty else {
                return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))   // nothing in the foreground
            }
            let buffer = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
            return CIImage(cvPixelBuffer: buffer)
        }
    }
}
