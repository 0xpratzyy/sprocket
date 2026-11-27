import Foundation
import AVFoundation
import CoreImage
import CoreVideo
import ImageIO

/// Decodes video frames on demand: "the frame nearest at-or-before source time t" for an asset id.
///
/// Requests normally arrive in increasing time order per asset, so each open AVAssetReader reads forward
/// sequentially and keeps its current and next sample. A request that no open reader can reach cheaply opens a new
/// reader at the previous sync sample (keyframe) at or before the target, so the decoder never wastes work.
/// Up to `maxReaders` readers stay open per asset (several time streams of one clip, e.g. normal speed + reverse +
/// freeze, each want their own); the least recently used is recycled.
///
/// Two small caches sit in front of the readers, both bounded by bytes (`cacheBytes`, about 200 MB at source
/// resolution, so only a few frames at 4K):
///  - the decoded frames of the last restarted group of pictures, so reverse playback decodes each GOP once and
///    serves consecutive backward requests from memory;
///  - a few recently returned frames per asset, so jump cuts that revisit times (and slow motion, freezes) cost nothing.
///
/// Output is upright (preferredTransform applied) and converted to SDR BT.709, so HDR / Dolby Vision
/// iPhone clips are not washed out.
public final class MediaVideoStore: @unchecked Sendable {
    struct TrackInfo {
        var asset: AVURLAsset
        var track: AVAssetTrack
        var duration: Double
        var orientation: CGImagePropertyOrientation
        /// Upright (display) size in pixels.
        var size: CGSize = .zero
    }

    final class Sample {
        let pts: Double
        let buffer: CVPixelBuffer
        let orientation: CGImagePropertyOrientation
        let bytes: Int
        private var cached: CIImage?
        init(pts: Double, buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
            self.pts = pts; self.buffer = buffer; self.orientation = orientation
            self.bytes = max(CVPixelBufferGetDataSize(buffer), CVPixelBufferGetWidth(buffer) * CVPixelBufferGetHeight(buffer) * 3 / 2)
        }
        var image: CIImage {
            if let c = cached { return c }
            var img = CIImage(cvPixelBuffer: buffer).oriented(orientation)
            let e = img.extent
            if e.origin != .zero { img = img.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y)) }
            cached = img
            return img
        }
    }

    final class Reader {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let orientation: CGImagePropertyOrientation
        let startsAtBeginning: Bool
        var cur: Sample?
        var next: Sample?
        var firstPTS: Double = 0
        var firstSample: Sample?
        var lastUsed = 0
        init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, orientation: CGImagePropertyOrientation, startsAtBeginning: Bool) {
            self.reader = reader; self.output = output; self.orientation = orientation; self.startsAtBeginning = startsAtBeginning
        }
        func readNext() -> Sample? {
            while let sb = output.copyNextSampleBuffer() {
                guard let ib = CMSampleBufferGetImageBuffer(sb) else { continue }
                return Sample(pts: CMSampleBufferGetPresentationTimeStamp(sb).seconds, buffer: ib, orientation: orientation)
            }
            return nil
        }
        func close() { reader.cancelReading(); cur = nil; next = nil; firstSample = nil }
    }

    /// Decoded frames of one restarted group of pictures, ascending pts and contiguous: every frame of the stream
    /// from `frames.first` up to (not including) `until` is in `frames`.
    private final class Run {
        var frames: [Sample]
        var bytes: Int
        var until: Double
        var fromStart: Bool      // begins at the stream's first frame, so times before it are served too
        var lastUsed: Int
        init(frames: [Sample], bytes: Int, until: Double, fromStart: Bool, lastUsed: Int) {
            self.frames = frames; self.bytes = bytes; self.until = until; self.fromStart = fromStart; self.lastUsed = lastUsed
        }
    }
    /// Frames kept for one asset besides the readers' own.
    private final class AssetCache {
        /// One run per time stream of the clip that went backwards or jumped (a few at most).
        var runs: [Run] = []
        /// Recently returned frames, most recent first, each valid for times up to `until`.
        var recent: [Recent] = []
        var lastUsed = 0
        var runBytes: Int { runs.reduce(0) { $0 + $1.bytes } }
        var recentBytes: Int { recent.reduce(0) { $0 + $1.sample.bytes } }
    }
    private struct Recent { let sample: Sample; let until: Double; let first: Bool }
    private static let maxRuns = 3

    private var urls: [String: URL]
    private let maxReaders: Int
    private let runBudget: Int
    private let recentBudget: Int
    private let lock = NSLock()
    private var tracks: [String: TrackInfo] = [:]
    private var notVideo: Set<String> = []
    private var readers: [String: [Reader]] = [:]
    private var caches: [String: AssetCache] = [:]
    private var tick = 0
    private let eps = 1e-3
    private let jumpAhead = 1.0
    /// A reader is shared between time streams of one clip only when the target is this close ahead of it.
    private let stealGap = 0.25
    private static let maxRecent = 4

    /// How many AVAssetReaders were opened so far (for tests and tuning).
    public private(set) var readerOpenCount = 0
    /// Frames currently held by the group-of-pictures and recent-frame caches, in bytes (for tests).
    public var cachedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return caches.values.reduce(0) { $0 + $1.runBytes + $1.recentBytes }
    }

    /// `cacheBytes` bounds the frame caches (shared by all assets of the store).
    public init(assets: [String: URL], maxReaders: Int = 8, cacheBytes: Int = 200 << 20) {
        self.urls = assets
        self.maxReaders = max(1, maxReaders)
        self.runBudget = max(1, cacheBytes * 3 / 4)
        self.recentBudget = max(1, cacheBytes / 4)
    }

    deinit { closeAll() }

    /// Loads track information for the ids (asynchronously). Ids that are not video files are remembered and ignored.
    public func prepare(_ ids: some Sequence<String>) async {
        for id in ids {
            let known = lock.withLock { tracks[id] != nil || notVideo.contains(id) }
            if known { continue }
            guard let url = lock.withLock({ urls[id] }) else { continue }
            let asset = AVURLAsset(url: url)
            do {
                let vt = try await asset.loadTracks(withMediaType: .video)
                guard let track = vt.first else { markNotVideo(id); continue }
                let transform = try await track.load(.preferredTransform)
                let natural = try await track.load(.naturalSize)
                let duration = try await asset.load(.duration).seconds
                let upright = CGRect(origin: .zero, size: natural).applying(transform)
                var info = TrackInfo(asset: asset, track: track, duration: duration.isFinite ? duration : 0,
                                     orientation: Self.orientation(for: transform))
                info.size = CGSize(width: abs(upright.width), height: abs(upright.height))
                lock.withLock { tracks[id] = info }
            } catch {
                markNotVideo(id)
            }
        }
    }

    /// Adds (or replaces) an asset id after init, e.g. the id of a generated mask video. Call `prepare` for it afterwards.
    func register(id: String, url: URL) {
        lock.withLock {
            if urls[id] != url {
                // A replaced file invalidates what was decoded from the old one.
                readers[id]?.forEach { $0.close() }
                readers[id] = nil; caches[id] = nil; tracks[id] = nil; notVideo.remove(id)
            }
            urls[id] = url
        }
    }

    /// The clip's upright size in pixels once `prepare` has loaded it.
    func uprightSize(src: String) -> CGSize? {
        lock.withLock { tracks[src]?.size }
    }

    private func markNotVideo(_ id: String) { lock.withLock { _ = notVideo.insert(id) } }

    /// True when `src` is a readable video file the store has loaded.
    public func isReadableVideo(src: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tracks[src] != nil
    }

    /// The decoded frame at-or-before `time` (seconds). Times before 0 give the first frame, past the end (including
    /// +infinity) the last; NaN gives the first. Returns nil for an unknown asset id.
    /// Throws SprocketError(.asset) if the file cannot be read.
    public func frame(src: String, time: Double) throws -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        guard let info = tracks[src] else {
            if urls[src] == nil || notVideo.contains(src) { return nil }
            throw SprocketError(.asset, "video asset \(src) was not prepared")
        }
        let t = time.isNaN ? 0 : max(0, time)
        let te = t + eps
        tick += 1
        let cache = caches[src] ?? AssetCache()
        caches[src] = cache
        cache.lastUsed = tick

        // 0. Frames already decoded: a restarted group of pictures, then recently returned frames.
        for run in cache.runs {
            guard let (s, k) = lookupRun(run, te: te) else { continue }
            run.lastUsed = tick
            remember(cache, s, until: k + 1 < run.frames.count ? run.frames[k + 1].pts : run.until, first: run.fromStart && k == 0)
            return s.image
        }
        for r in cache.recent where te < r.until && (r.sample.pts <= te || r.first) {
            return r.sample.image
        }
        var list = readers[src] ?? []

        // 1. A reader that already sits on the right frame, or can reach it by reading forward a little.
        var best: Reader?
        for r in list {
            guard let cur = r.cur else { continue }
            let usable: Bool
            if cur.pts <= te {
                let gap = t - cur.pts
                usable = gap <= stealGap || (list.count >= maxReaders && gap <= jumpAhead) || r.next == nil
            } else {
                usable = r.startsAtBeginning && cur.pts == r.firstPTS   // t before the very first frame
            }
            guard usable else { continue }
            if let b = best?.cur {
                if cur.pts <= te, b.pts > te || cur.pts > b.pts { best = r }
            } else { best = r }
        }
        if let r = best {
            advance(r, to: t, run: nil)
            r.lastUsed = tick
            if let cur = r.cur { remember(cache, cur, until: r.next?.pts ?? .infinity, first: r.startsAtBeginning && cur === r.firstSample) }
            return r.cur?.image
        }

        // 2. Open a new reader at the previous keyframe, recycling the least recently used if at the cap.
        if list.count >= maxReaders, let lru = list.enumerated().min(by: { $0.element.lastUsed < $1.element.lastUsed }) {
            lru.element.close()
            list.remove(at: lru.offset)
        }
        let wentBackwards = list.contains { ($0.cur?.pts ?? -.infinity) > te }
        var start = Self.syncPoint(info, before: t)
        var attempts = 0
        var reader: Reader
        var run: [Sample] = []
        var runBytes = 0
        var evicted = false
        while true {
            reader = try open(info, start: start)
            run.removeAll(keepingCapacity: true); runBytes = 0; evicted = false
            if let c = reader.cur { run.append(c); runBytes += c.bytes }
            advance(reader, to: t, run: { [self] sample in
                run.append(sample); runBytes += sample.bytes
                while runBytes > runBudget, run.count > 1 { runBytes -= run.removeFirst().bytes; evicted = true }
            })
            if let c = reader.cur, c.pts > te, !start.isStreamStart, attempts < 8 {   // started too late: back up and retry
                reader.close()
                attempts += 1
                start = Self.syncPoint(info, before: max(0, (start.time?.seconds ?? 1) - 0.001), mustPrecede: start.time?.seconds)
                continue
            }
            break
        }
        reader.lastUsed = tick
        list.append(reader)
        readers[src] = list
        if let cur = reader.cur {
            if wentBackwards, run.count >= 3 {
                addRun(cache, Run(frames: run, bytes: runBytes, until: reader.next?.pts ?? .infinity,
                                  fromStart: reader.startsAtBeginning && !evicted, lastUsed: tick), served: t)
            }
            remember(cache, cur, until: reader.next?.pts ?? .infinity, first: reader.startsAtBeginning && cur === reader.firstSample)
        }
        return reader.cur?.image
    }

    // MARK: frame caches

    private func lookupRun(_ r: Run, te: Double) -> (Sample, Int)? {
        guard let first = r.frames.first, te < r.until else { return nil }
        if te < first.pts { return r.fromStart ? (first, 0) : nil }
        var lo = 0, hi = r.frames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if r.frames[mid].pts <= te { lo = mid } else { hi = mid - 1 }
        }
        return (r.frames[lo], lo)
    }

    /// Keeps a few runs per asset (least recently used out) and bounds all runs of the store by `runBudget`.
    private func addRun(_ c: AssetCache, _ run: Run, served t: Double) {  // t: only for debugging
        c.runs.append(run)
        if c.runs.count > Self.maxRuns, let lru = c.runs.enumerated().filter({ $0.element !== run }).min(by: { $0.element.lastUsed < $1.element.lastUsed }) {
            c.runs.remove(at: lru.offset)
        }
        var total = caches.values.reduce(0) { $0 + $1.runBytes }
        while total > runBudget {
            var victim: (AssetCache, Int, Run)?
            for ac in caches.values {
                for (i, r) in ac.runs.enumerated() where r !== run {
                    if victim == nil || r.lastUsed < victim!.2.lastUsed { victim = (ac, i, r) }
                }
            }
            guard let (ac, i, r) = victim else { break }
            total -= r.bytes
            ac.runs.remove(at: i)
        }
    }

    private func remember(_ c: AssetCache, _ s: Sample, until: Double, first: Bool) {
        c.recent.removeAll { $0.sample === s }
        c.recent.insert(Recent(sample: s, until: until, first: first), at: 0)
        // Bounded by count, and by this asset's share of the recent-frame budget.
        let share = max(1, recentBudget / max(1, caches.count))
        var bytes = c.recentBytes
        while c.recent.count > Self.maxRecent || (bytes > share && c.recent.count > 1) {
            bytes -= c.recent.removeLast().sample.bytes
        }
    }

    /// Cancels every open reader and frees decoded frames.
    public func closeAll() {
        lock.lock(); defer { lock.unlock() }
        for (_, l) in readers { l.forEach { $0.close() } }
        readers.removeAll()
        caches.removeAll()
    }

    /// Number of readers currently open for an asset (for tests).
    public func openReaderCount(src: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return readers[src]?.count ?? 0
    }

    /// Reads forward until `r.cur` is the last frame at or before `t`. `run` sees every frame that becomes current.
    private func advance(_ r: Reader, to t: Double, run: ((Sample) -> Void)?) {
        while let n = r.next, n.pts <= t + eps {
            r.cur = n
            run?(n)
            r.next = r.readNext()
        }
    }

    /// Where a reader should start to decode the frame at-or-before a time: the sync sample (keyframe) at or before it.
    struct SyncPoint {
        var time: CMTime?          // nil: read from the start of the file
        var isStreamStart: Bool { time == nil }
    }

    /// The keyframe at or before `t`, found with a sample cursor. Falls back to a point a little before `t` when the
    /// track cannot be walked. `mustPrecede` forces progress when retrying (the result is before that time).
    static func syncPoint(_ info: TrackInfo, before t: Double, mustPrecede: Double? = nil) -> SyncPoint {
        let fallback = SyncPoint(time: t <= 0.25 ? nil : CMTime(seconds: max(0, (mustPrecede ?? t) - 0.5), preferredTimescale: 600))
        let ts = max(info.track.naturalTimeScale, 600)
        guard t > 0, let cursor = info.track.makeSampleCursor(presentationTimeStamp: CMTime(seconds: t, preferredTimescale: ts)) else {
            return t > 0 ? fallback : SyncPoint(time: nil)
        }
        // Land on the frame at-or-before t (the cursor may pick the one just after).
        var guardSteps = 0
        while cursor.presentationTimeStamp.seconds > t + 1e-3, guardSteps < 4, cursor.stepInPresentationOrder(byCount: -1) == -1 { guardSteps += 1 }
        var steps = 0
        while true {
            let isSync = cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue
            let pts = cursor.presentationTimeStamp
            if isSync, mustPrecede == nil || pts.seconds < mustPrecede! - 1e-4 {
                return pts.seconds <= 1e-4 ? SyncPoint(time: nil) : SyncPoint(time: pts)
            }
            if cursor.stepInDecodeOrder(byCount: -1) != -1 { return SyncPoint(time: nil) }   // before the first sample: read from the start
            steps += 1
            if steps > 100_000 { return fallback }
        }
    }

    private func open(_ info: TrackInfo, start: SyncPoint) throws -> Reader {
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        do {
            let reader = try AVAssetReader(asset: info.asset)
            let output = AVAssetReaderTrackOutput(track: info.track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw SprocketError(.asset, "cannot read video track") }
            reader.add(output)
            if let st = start.time {
                let remaining = max(1.0, info.duration - st.seconds + 1.0)
                reader.timeRange = CMTimeRange(start: st, duration: CMTime(seconds: remaining, preferredTimescale: 600))
            }
            readerOpenCount += 1
            guard reader.startReading() else {
                throw SprocketError(.asset, "cannot start reading video: \(reader.error?.localizedDescription ?? "unknown error")")
            }
            let r = Reader(reader: reader, output: output, orientation: info.orientation, startsAtBeginning: start.isStreamStart)
            r.cur = r.readNext()
            r.firstSample = r.cur
            r.firstPTS = r.cur?.pts ?? 0
            r.next = r.cur == nil ? nil : r.readNext()
            if r.cur == nil {
                let why = reader.error?.localizedDescription ?? "no frames"
                throw SprocketError(.asset, "video has no decodable frames near \(start.time?.seconds ?? 0)s (\(why))")
            }
            return r
        } catch let e as SprocketError {
            throw e
        } catch {
            throw SprocketError(.asset, "video read failed: \(error.localizedDescription)")
        }
    }

    /// Maps a track's preferredTransform (top-left coordinates) to the EXIF-style orientation that makes it upright.
    static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        let a = Int(t.a.rounded()), b = Int(t.b.rounded()), c = Int(t.c.rounded()), d = Int(t.d.rounded())
        switch (a, b, c, d) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        case (-1, 0, 0, 1): return .upMirrored
        case (1, 0, 0, -1): return .downMirrored
        case (0, 1, 1, 0): return .leftMirrored
        case (0, -1, -1, 0): return .rightMirrored
        default: return .up
        }
    }
}
