import Foundation
import AVFoundation
import CryptoKit

/// A clip's mask that a script needs: which clip, which kind, and which source-time ranges (seconds), already padded.
/// An upper bound of 1e300 or more means "to the end of the clip".
public struct MatteNeed: Sendable, Hashable {
    public var src: String
    public var kind: String
    public var ranges: [ClosedRange<Double>]
    public var start: Double { ranges.first?.lowerBound ?? 0 }
    public var end: Double { ranges.last?.upperBound ?? 0 }
    public var seconds: Double { ranges.reduce(0) { $0 + min($1.upperBound, 1e9) - $1.lowerBound } }
}

/// Collects the source times at which a script draws cut-out masks, frame by frame, and turns them into ranges.
public struct MatteNeedScan: Sendable {
    /// Seconds added before and after every time a mask is drawn, so frames near the edge (and the "frame at or before"
    /// lookup) are covered.
    public static let padding = 0.25
    /// Ranges closer than this are joined; farther apart they stay separate (a 1 s shot at 3 s and another at 50 s do
    /// not make the engine mask the 47 s between them).
    public static let mergeGap = 0.5

    private struct Key: Hashable { var src: String; var kind: String }
    private var times: [Key: Set<Double>] = [:]
    public init() {}

    public var isEmpty: Bool { times.isEmpty }

    /// Notes every mask request in the tree.
    public mutating func add(_ node: Node) {
        for r in node.videoRequests {
            guard let kind = r.matte else { continue }
            times[Key(src: r.src, kind: kind), default: []].insert(r.time)
        }
    }

    /// The needs found so far, sorted by clip id then kind.
    public func needs() -> [MatteNeed] {
        times.keys.sorted { ($0.src, $0.kind) < ($1.src, $1.kind) }.map { key in
            let sorted = times[key]!.sorted()
            var ranges: [ClosedRange<Double>] = []
            for t in sorted {
                let r = max(0, t - Self.padding)...(t + Self.padding)
                if let last = ranges.last, r.lowerBound <= last.upperBound + Self.mergeGap {
                    ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
                } else { ranges.append(r) }
            }
            return MatteNeed(src: key.src, kind: key.kind, ranges: ranges)
        }
    }
}

/// How a mask video gets made: (clip file, output file, kind, ranges to cover) -> frames written. The default is `MatteMaker.make`
/// with Vision; tests pass their own to supply a known mask.
public typealias MatteMakerFunction = @Sendable (_ input: URL, _ output: URL, _ kind: MatteKind, _ ranges: [ClosedRange<Double>],
                                                 _ progress: @escaping @Sendable (Int, Int) -> Void) async throws -> Int

/// What the exporter reports while it makes masks, before the first frame is drawn.
public struct MatteProgress: Sendable {
    public var src: String
    public var kind: String
    /// Mask frames done / expected for this clip (an estimate: frame rate times the seconds to cover).
    public var frame: Int
    public var total: Int
    /// 1-based position among the masks this export needs, and how many there are.
    public var index: Int
    public var count: Int
}

/// Finds or makes the mask video for (clip, kind) and keeps it on disk, so a second export of the same clip is instant.
///
/// Cache: `<caches>/Sprocket-mattes/<key>-<kind>.mp4` plus a `.json` sidecar listing the time ranges inside it. The key hashes
/// the clip's path, size and modification date, so an edited file never reuses a stale mask. A cached file serves a request
/// when it covers every needed range; otherwise one covering the union of the old and the new ranges is made.
final class MatteProvider: @unchecked Sendable {
    let directory: URL
    private let maker: MatteMakerFunction
    private let lock = NSLock()
    private var generations = 0

    /// How many mask videos this provider had to make (cache hits do not count). For tests and tuning.
    var generationCount: Int { lock.withLock { generations } }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sprocket-mattes", isDirectory: true)
    }

    init(directory: URL? = nil, maker: MatteMakerFunction? = nil) {
        self.directory = directory ?? Self.defaultDirectory
        self.maker = maker ?? { input, output, kind, ranges, progress in
            try await MatteMaker.make(input: input, output: output, kind: kind, ranges: ranges, progress: progress)
        }
    }

    /// The id the mask of a clip goes by inside the video store.
    static func maskID(src: String, kind: String) -> String { "\(src)#matte:\(kind)" }

    static func key(for url: URL, kind: String) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let text = "\(url.standardizedFileURL.path)|\(size)|\(mtime)|\(kind)"
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private struct Sidecar: Codable { var ranges: [[Double]]; var frames: Int }

    /// Returns the mask video covering `needed` for this clip, making it when the cache does not already hold it.
    /// Throws SprocketError(.asset) when the clip cannot be read.
    func ensure(clip: URL, kind: MatteKind, needed: [ClosedRange<Double>],
                progress: @escaping @Sendable (Int, Int) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: clip)
        guard let dur = try? await asset.load(.duration).seconds, dur.isFinite, dur > 0,
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
            throw SprocketError(.asset, "the clip is not a readable video (\(clip.path))")
        }
        let wanted = Self.clamp(needed, to: dur)
        let name = Self.key(for: clip, kind: kind.rawValue) + "-" + kind.rawValue
        let file = directory.appendingPathComponent(name + ".mp4")
        let side = directory.appendingPathComponent(name + ".json")
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var cover = wanted
        if fm.fileExists(atPath: file.path), let data = try? Data(contentsOf: side),
           let car = try? JSONDecoder().decode(Sidecar.self, from: data) {
            let have = car.ranges.compactMap { $0.count == 2 ? $0[0]...$0[1] : nil }
            if wanted.allSatisfy({ w in have.contains { $0.lowerBound <= w.lowerBound + 1e-6 && $0.upperBound >= w.upperBound - 1e-6 } }) {
                return file
            }
            cover = Self.union(have, wanted)
        }
        try Task.checkCancellation()
        let tmp = directory.appendingPathComponent(name + ".tmp-\(UUID().uuidString).mp4")
        defer { try? fm.removeItem(at: tmp) }
        lock.withLock { generations += 1 }
        let frames = try await maker(clip, tmp, kind, cover, progress)
        try? fm.removeItem(at: file)
        try fm.moveItem(at: tmp, to: file)
        let car = Sidecar(ranges: cover.map { [$0.lowerBound, $0.upperBound] }, frames: frames)
        if let data = try? JSONEncoder().encode(car) { try? data.write(to: side, options: .atomic) }
        return file
    }

    /// Inside 0...duration, ordered, merged; a range past the end becomes the last 0.25 s (the clip holds its last frame).
    static func clamp(_ ranges: [ClosedRange<Double>], to dur: Double) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for r in ranges {
            var lo = min(max(0, r.lowerBound), dur), hi = min(max(0, r.upperBound), dur)
            if hi - lo < MatteNeedScan.padding { lo = max(0, hi - MatteNeedScan.padding) }
            out.append(lo...hi)
        }
        return union([], out)
    }

    static func union(_ a: [ClosedRange<Double>], _ b: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var merged: [ClosedRange<Double>] = []
        for r in (a + b).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, r.lowerBound <= last.upperBound + MatteNeedScan.mergeGap {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else { merged.append(r) }
        }
        return merged
    }

    /// Deletes every cached mask video in `directory`.
    static func clear(directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}
