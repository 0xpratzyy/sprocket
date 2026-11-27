import Foundation
import CoreImage
import AVFoundation

/// Decodes the frames a composition asks for and writes the movie. Owned by the EXPORT worker; the public surface below is fixed.
public final class SprocketExporter: @unchecked Sendable {
    public struct Progress: Sendable {
        public var frame: Int; public var total: Int
        public init(frame: Int, total: Int) { self.frame = frame; self.total = total }
    }

    private let script: SprocketScript
    private let assets: [String: URL]
    private let videos: MediaVideoStore
    private let images: MediaImageStore
    private let renderer = SprocketRenderer()
    private let mattes: MatteProvider
    private let web: WebFrameStore
    private let warningLock = NSLock()
    private var warningList: [String] = []
    private var warningSeen = Set<String>()

    /// Problems that did not stop the export but left something out, de-duplicated, in the order found: an asset id
    /// the script uses that was not provided, a file that does not exist or is not a readable video / image / audio file.
    /// Examples: "asset c3: file is not a readable video (/path/c3.mp4)", "asset c9 is used by the script but was not provided".
    /// Safe to read from any thread, including while an export is running.
    public var warnings: [String] {
        warningLock.lock(); defer { warningLock.unlock() }
        return warningList
    }

    /// True the first time an (asset, kind) pair is reported unusable, so the file checks are not repeated every frame.
    private func noteUnusable(_ id: String, _ kind: AssetCheck.Kind) -> Bool {
        warningLock.lock(); defer { warningLock.unlock() }
        return unusable.insert("\(kind.rawValue):\(id)").inserted
    }
    private var unusable = Set<String>()

    func warn(_ message: String) {
        warningLock.lock(); defer { warningLock.unlock() }
        if warningSeen.insert(message).inserted { warningList.append(message) }
    }

    /// Called (from any thread) while cut-out masks are made, before the movie's first frame: mask frames done / expected
    /// per clip. Set it before `export`. It is a property, not a second closure parameter, so existing
    /// `export(to:) { p in ... }` calls keep meaning the movie's progress.
    public var prepareHandler: (@Sendable (MatteProgress) -> Void)?

    /// How many mask videos this exporter had to make (cache hits do not count).
    public var matteGenerationCount: Int { mattes.generationCount }

    /// How many web-layer pictures this exporter had to render and how many pages it had to load (cache hits do not count).
    public var webFramesRendered: Int { web.framesRendered }
    public var webPageLoads: Int { web.pageLoads }

    /// Frames of the last `export` that were the same picture as the frame before them, so they were written again
    /// without being drawn. A frame repeats when its node tree, with defaults written out, equals the previous frame's:
    /// the renderer draws only from the tree and the asset files, so an equal tree is an equal picture. Films animated
    /// on twos (each pose held for two frames) repeat about half their frames.
    public var framesReused: Int { warningLock.withLock { reused } }
    private var reused = 0

    /// Where this exporter keeps its web-layer pictures (tests look inside).
    var webCacheDirectoryForTests: URL { web.directory }

    /// Deletes every cached web-layer picture (`Sprocket-web` under the system caches folder).
    public static func clearWebCache() { WebFrameStore.clear() }

    /// Where this exporter keeps its masks (tests look inside).
    var cacheDirectoryForTests: URL { mattes.directory }

    /// Deletes every cached cut-out mask video (`Sprocket-mattes` under the system caches folder).
    public static func clearMatteCache() { MatteProvider.clear(directory: MatteProvider.defaultDirectory) }

    /// `assets` maps the ids used in the script ("c1", "music") to files.
    /// `matteMaker` and `matteCacheDirectory` are for tests and hosts with their own mask source: the function that makes
    /// a mask video (default: Vision, see `MatteMaker`) and the folder that caches them (default: `Sprocket-mattes` under the
    /// system caches folder).
    public init(script: SprocketScript, assets: [String: URL], matteMaker: MatteMakerFunction? = nil, matteCacheDirectory: URL? = nil,
                webCacheDirectory: URL? = nil) {
        self.script = script
        self.assets = assets
        self.mattes = MatteProvider(directory: matteCacheDirectory, maker: matteMaker)
        self.web = WebFrameStore(directory: webCacheDirectory)
        self.videos = MediaVideoStore(assets: assets)
        self.images = MediaImageStore(assets: assets)
    }

    /// Renders every frame and writes an H.264 .mp4 with the composition's sound. Cancelling the task stops it and removes the partial file.
    ///
    /// Cut-out masks (`cutout(...)` in the script) are made first, only for the source times the script uses.
    /// `progress` reports only the frames of the movie itself; set `prepareHandler` before calling to observe the mask phase.
    public func export(to url: URL, progress: (@Sendable (Progress) -> Void)? = nil) async throws {
        let config = script.config
        await videos.prepare(assets.keys)
        try await prepare(frames: 0..<config.durationInFrames, report: prepareHandler)
        let audio = await MediaAudioMix.build(config: config, assets: assets, warn: { [self] in warn($0) })
        defer { videos.closeAll() }
        let repeats = RepeatTracker()
        warningLock.withLock { reused = 0 }
        try await ExportEngine.run(config: config, to: url, audio: audio, progress: progress) { [self] frame in
            let node = try resolvedNode(frame: frame)
            if repeats.isRepeat(node) {
                warningLock.withLock { reused += 1 }
                return nil
            }
            return try makeImage(node: node)
        }
    }

    /// One frame as a CGImage, for previews, tests and the look-and-fix loop.
    public func still(frame: Int) async throws -> CGImage {
        let config = script.config
        guard frame >= 0, frame < config.durationInFrames else {
            throw SprocketError(.render, "frame \(frame) is outside 0..<\(config.durationInFrames)")
        }
        await videos.prepare(assets.keys)
        try await prepare(frames: frame..<(frame + 1), report: nil)
        defer { videos.closeAll() }
        let image = try makeImage(node: try resolvedNode(frame: frame))
        guard let cg = SprocketRenderer.context.createCGImage(image, from: CGRect(x: 0, y: 0, width: config.width, height: config.height),
                                                            format: .RGBA8, colorSpace: ExportEngine.colorSpace)
        else { throw SprocketError(.render, "cannot rasterise frame \(frame)") }
        return cg
    }

    /// The masks a script needs for these frames, with the time ranges to cover (what `export` will make).
    public func matteNeeds() throws -> [MatteNeed] { try scanMattes(frames: 0..<script.config.durationInFrames) }

    private func scanMattes(frames: Range<Int>) throws -> [MatteNeed] {
        var ignored = Set<WebRequest>()
        return try scanFrames(frames, web: &ignored)
    }

    /// Evaluates the frames once; returns the masks they need and collects the web-layer pictures they need into `web`.
    private func scanFrames(_ frames: Range<Int>, web: inout Set<WebRequest>) throws -> [MatteNeed] {
        var scan = MatteNeedScan()
        for f in frames {
            if Task.isCancelled { throw SprocketError(.cancelled, "export cancelled") }
            let node = try resolvedNode(frame: f)
            scan.add(node)
            if node.containsHTML { web.formUnion(try node.webRequests()) }
        }
        return scan.needs()
    }

    /// The prepare phase: scans the frames once, then makes the cut-out masks and renders the web pages they need.
    private func prepare(frames: Range<Int>, report: (@Sendable (MatteProgress) -> Void)?) async throws {
        var requests = Set<WebRequest>()
        let needs = try scanFrames(frames, web: &requests)
        try await prepareMattes(needs: needs, report: report)
        let script = self.script
        try await web.prepare(requests: requests, fps: script.config.fps, assets: assets, log: { script.appendLog($0) }, report: report)
    }

    /// The frame's node tree with the defaults of its html nodes written out (box = canvas, time = frame / fps).
    func resolvedNode(frame: Int) throws -> Node {
        let c = script.config
        return try script.node(frame: frame).resolvingWeb(frame: frame, fps: c.fps, canvasWidth: c.width, canvasHeight: c.height)
    }

    /// Makes (or finds in the cache) the mask video of every clip the frames use through `cutout`, and registers it with the
    /// video store. A clip that cannot be read gives a warning and draws nothing for its mask.
    private func prepareMattes(needs: [MatteNeed], report: (@Sendable (MatteProgress) -> Void)?) async throws {
        for (i, need) in needs.enumerated() {
            guard let kind = MatteKind(rawValue: need.kind) else { continue }
            let label = "cutout(\"\(need.src)\", kind \(need.kind))"
            guard let url = assets[need.src] else { warn("\(label): asset \(need.src) was not provided"); continue }
            do {
                let file = try await mattes.ensure(clip: url, kind: kind, needed: need.ranges) { done, total in
                    report?(MatteProgress(src: need.src, kind: need.kind, frame: done, total: total, index: i + 1, count: needs.count))
                }
                let id = MatteProvider.maskID(src: need.src, kind: need.kind)
                videos.register(id: id, url: file)
                await videos.prepare([id])
                if !videos.isReadableVideo(src: id) { warn("\(label): the mask video could not be read (\(file.path))") }
            } catch is CancellationError {
                throw SprocketError(.cancelled, "export cancelled")
            } catch let e as SprocketError where e.kind == .cancelled {
                throw e
            } catch {
                let why = (error as? SprocketError)?.message ?? error.localizedDescription
                warn("\(label): no mask, \(why)")
            }
        }
    }

    /// Reports (once each) the fonts the frame names that are not installed, and anything the script itself noticed.
    private func noteFonts(_ node: Node) {
        for f in node.textFontFamilies.sorted() where !SprocketFonts.isInstalled(f) { warn(SprocketFonts.missingMessage(f)) }
        for w in script.drainWarnings() { warn(w) }
    }

    private func makeImage(node: Node) throws -> CIImage {
        noteFonts(node)
        let resources = try Snapshot(node: node, videos: videos, images: images, web: web, report: { [self] id, kind in
            guard noteUnusable(id, kind) else { return }
            warn(AssetCheck.message(id: id, kind: kind, url: assets[id]))
        })
        return renderer.render(node, config: script.config, resources: resources)
    }

    /// Remembers the previous frame's tree during an export. Called from the writer's one video queue, in frame order.
    final class RepeatTracker: @unchecked Sendable {
        private var previous: Node?
        /// True when `node` equals the tree of the frame before; always records `node` as the new previous tree.
        func isRepeat(_ node: Node) -> Bool {
            defer { previous = node }
            return previous == node
        }
    }

    /// The pictures one frame needs, fetched before drawing.
    struct Snapshot: FrameResources, @unchecked Sendable {
        /// Keyed by asset id; a mask is keyed by `MatteProvider.maskID`.
        private var video: [String: [(time: Double, image: CIImage)]] = [:]
        private var stills: [String: CIImage] = [:]

        private var pages: [WebRequest: CIImage] = [:]

        init(node: Node, videos: MediaVideoStore, images: MediaImageStore, web: WebFrameStore, report: (String, AssetCheck.Kind) -> Void) throws {
            if node.containsHTML { for req in try node.webRequests() { if let img = web.image(for: req) { pages[req] = img } } }
            for req in Set(node.videoRequests) {
                if let kind = req.matte {
                    // A mask: same picture size as its clip (so the same fit puts it exactly under the clip), or nothing.
                    // A mask that could not be made was already warned about when it was prepared.
                    let id = MatteProvider.maskID(src: req.src, kind: kind)
                    if var img = try videos.frame(src: id, time: req.time) {
                        if let clip = videos.uprightSize(src: req.src), clip.width > 0, clip.height > 0 {
                            let e = img.extent
                            if e.width > 0, e.height > 0, abs(e.width - clip.width) > 0.01 || abs(e.height - clip.height) > 0.01 {
                                img = img.transformed(by: CGAffineTransform(scaleX: clip.width / e.width, y: clip.height / e.height))
                            }
                        }
                        video[id, default: []].append((req.time, img))
                    }
                    continue
                }
                if let img = try videos.frame(src: req.src, time: req.time) { video[req.src, default: []].append((req.time, img)) }
                else { report(req.src, .video) }
            }
            for id in Set(node.imageSources) {
                if let img = images.image(src: id) { stills[id] = img } else { report(id, .image) }
            }
        }

        func videoFrame(src: String, time: Double) -> CIImage? { videoFrame(src: src, time: time, matte: nil) }
        func videoFrame(src: String, time: Double, matte: String?) -> CIImage? {
            guard let list = video[matte.map { MatteProvider.maskID(src: src, kind: $0) } ?? src] else { return nil }
            let t = max(0, time)
            return list.min(by: { abs($0.time - t) < abs($1.time - t) })?.image
        }
        func image(src: String) -> CIImage? { stills[src] }
        func webFrame(markup: String, width: Int, height: Int, time: Double) -> CIImage? {
            pages[WebRequest(markup: markup, width: width, height: height, time: time)]
        }
    }
}
