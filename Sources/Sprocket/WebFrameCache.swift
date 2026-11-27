import Foundation
import CoreImage
import CoreGraphics
import ImageIO

/// Renders the pages a script uses and keeps the pictures on disk.
///
/// Cache: `<caches>/Sprocket-web/<digest>-<w>x<h>-<fps>-<micros>.png`, or `...-static.png` for a page that cannot change with
/// time (one picture for every time). The digest hashes the markup; the file never depends on the asset files, so a page that
/// shows `sprocket-asset://` pictures is cached per markup, size and fps only: clear the cache (`SprocketExporter.clearWebCache()`)
/// after swapping the files behind an asset id.
///
/// Format: PNG. Measured at 1080x1920 with transparency (see the report): PNG writes in about 16 ms and reads in 18 ms,
/// HEIC with alpha writes in 65 ms and reads in 29 ms for a file 40% smaller. Writing is the cost that is paid on every frame
/// of every render, so PNG wins; the files live in the caches folder, which the system may empty at any time.
public final class WebFrameStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var index: [WebRequest: URL] = [:]
    private var rendered = 0
    private var loads = 0
    private let decoded: NSCache<NSURL, CIImage> = { let c = NSCache<NSURL, CIImage>(); c.countLimit = 6; return c }()

    /// Pictures made by this store (cache hits do not count) and page loads it had to do. For tests and tuning.
    public var framesRendered: Int { lock.withLock { rendered } }
    public var pageLoads: Int { lock.withLock { loads } }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Sprocket-web", isDirectory: true)
    }

    public init(directory: URL? = nil) { self.directory = directory ?? Self.defaultDirectory }

    public static func clear(directory: URL = defaultDirectory) { try? FileManager.default.removeItem(at: directory) }

    // MARK: lookup (used while drawing)

    /// The picture of a request that `prepare` made, as a lazily decoded image; nil if there is none.
    func image(for request: WebRequest) -> CIImage? {
        guard let url = lock.withLock({ index[request] }) else { return nil }
        if let hit = decoded.object(forKey: url as NSURL) { return hit }
        guard let img = CIImage(contentsOf: url) else { return nil }
        decoded.setObject(img, forKey: url as NSURL)
        return img
    }

    /// The file behind a request (for tests).
    func file(for request: WebRequest) -> URL? { lock.withLock { index[request] } }

    // MARK: prepare

    private struct Page {
        var markup: String
        var width: Int
        var height: Int
        var digest: String
        var times: Set<Int>
        var requests: [Int: WebRequest]
    }

    private func name(_ p: Page, fps: Int, suffix: String) -> URL {
        directory.appendingPathComponent("\(p.digest)-\(p.width)x\(p.height)-\(fps)-\(suffix).png")
    }

    /// Renders every distinct page once, stepping through its times in increasing order, and writes the pictures to the cache.
    /// Pages and times already in the cache are not rendered again. `log` receives the page's console output;
    /// `report` the number of pictures done / expected per page (a `MatteProgress` with kind "web" and src "html:" plus the first
    /// 8 hex digits of the page's digest). Setting SPROCKET_WEB_TIMING in the environment prints a timing line per page. Throws SprocketError(.script, "html: ...").
    func prepare(requests: Set<WebRequest>, fps: Int, assets: [String: URL],
                 log: @escaping @Sendable (String) -> Void,
                 report: (@Sendable (MatteProgress) -> Void)?) async throws {
        guard !requests.isEmpty else { return }
        var pages: [String: Page] = [:]
        for r in requests {
            let key = "\(r.digest)|\(r.width)|\(r.height)"
            var p = pages[key] ?? Page(markup: r.markup, width: r.width, height: r.height, digest: r.digest, times: [], requests: [:])
            p.times.insert(r.micros); p.requests[r.micros] = r
            pages[key] = p
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ordered = pages.values.sorted { ($0.digest, $0.width, $0.height) < ($1.digest, $1.width, $1.height) }
        let fm = FileManager.default

        for (i, page) in ordered.enumerated() {
            if Task.isCancelled { throw SprocketError(.cancelled, "export cancelled") }
            let label = "html:" + page.digest.prefix(8)
            // A page known to be static: one file serves every time.
            let staticFile = name(page, fps: fps, suffix: "static")
            if fm.fileExists(atPath: staticFile.path) {
                lock.withLock { for (_, r) in page.requests { index[r] = staticFile } }
                continue
            }
            var missing: [Int] = []
            for t in page.times.sorted() {
                let f = name(page, fps: fps, suffix: String(t))
                if fm.fileExists(atPath: f.path) { lock.withLock { index[page.requests[t]!] = f } } else { missing.append(t) }
            }
            if missing.isEmpty { continue }

            let setup = WebPageSetup(markup: page.markup, width: page.width, height: page.height, assets: assets)
            let result = try await Self.renderPage(setup, times: missing, fps: fps, file: { [self] suffix in name(page, fps: fps, suffix: suffix) },
                                                   log: log) { done, total in
                report?(MatteProgress(src: label, kind: "web", frame: done, total: total, index: i + 1, count: ordered.count))
            }
            lock.withLock {
                loads += 1
                rendered += result.written
                for (t, f) in result.files { index[page.requests[t]!] = f }
            }
        }
    }

    struct PageResult { var files: [Int: URL]; var written: Int }

    /// Loads one page and makes its pictures. Runs on the main actor (WKWebView needs it); the caller's task waits.
    @MainActor
    private static func renderPage(_ setup: WebPageSetup, times: [Int], fps: Int, file: (String) -> URL,
                                   log: @escaping @Sendable (String) -> Void,
                                   progress: @escaping (Int, Int) -> Void) async throws -> PageResult {
        let timing = ProcessInfo.processInfo.environment["SPROCKET_WEB_TIMING"] != nil
        var tCreate = 0.0, tLoad = 0.0, tStep = 0.0, tShot = 0.0, tWrite = 0.0
        func now() -> Double { Date().timeIntervalSinceReferenceDate }
        let t0 = now()
        let page = try await WebPage(setup)
        tCreate = now() - t0
        defer {
            page.close()
            if timing {
                let n = max(1, Double(times.count))
                FileHandle.standardError.write(Data(String(format: "web timing %dx%d: create %.0f ms, load %.0f ms, then per picture: step %.1f ms, snapshot %.1f ms, encode+write %.1f ms (%d pictures)\n",
                    setup.width, setup.height, tCreate * 1000, tLoad * 1000, tStep / n * 1000, tShot / n * 1000, tWrite / n * 1000, times.count).utf8))
            }
        }
        do {
            let tl = now()
            try await page.load()
            tLoad = now() - tl
            page.takeLogs().forEach(log)
            var files: [Int: URL] = [:]
            var written = 0
            if page.isStatic {
                // Nothing on the page depends on time: one picture, reused for every time.
                let t = Double(times[0]) / 1e6
                try await page.step(t: t, frame: Int((t * Double(fps)).rounded()))
                let url = file("static")
                try write(try await page.snapshot(), to: url)
                page.takeLogs().forEach(log)
                written = 1
                progress(1, 1)
                for t in times { files[t] = url }
            } else {
                for (n, micros) in times.enumerated() {
                    if Task.isCancelled { throw SprocketError(.cancelled, "export cancelled") }
                    let t = Double(micros) / 1e6
                    let ts = now()
                    try await page.step(t: t, frame: Int((t * Double(fps)).rounded()))
                    let ts2 = now()
                    let url = file(String(micros))
                    let shot = try await page.snapshot()
                    let ts3 = now()
                    try write(shot, to: url)
                    tStep += ts2 - ts; tShot += ts3 - ts2; tWrite += now() - ts3
                    page.takeLogs().forEach(log)
                    files[micros] = url
                    written += 1
                    progress(n + 1, times.count)
                }
            }
            return PageResult(files: files, written: written)
        } catch {
            page.takeLogs().forEach(log)
            throw error
        }
    }

    /// Writes a PNG atomically (a half-written file is never seen by another export).
    private static func write(_ image: CGImage, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".tmp-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, "public.png" as CFString, 1, nil) else {
            throw SprocketError(.export, "html: cannot write \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw SprocketError(.export, "html: cannot write \(url.path)") }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }
}
