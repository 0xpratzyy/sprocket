import Foundation
import Sprocket
import CoreGraphics
import CoreText
import ImageIO

// sprocket-render <script.js> [--asset id=path ...] --out out.mp4
//               --still N --out frame.png | --sheet N --out sheet.jpg | --check
//               [--strict] [--verbose]
//
// Exit codes: 0 ok, 1 error, 2 warnings with --strict, 130 interrupted (SIGINT), 143 terminated (SIGTERM).
// An interrupted export is cancelled and leaves no output file and no temp file behind.

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func fail(_ s: String) -> Never {
    err("error: \(s)")
    exit(1)
}

let usage = """
usage: sprocket-render <script.js> [--asset id=path ...] --out out.mp4
       sprocket-render <script.js> [--asset id=path ...] --still N --out frame.png
       sprocket-render <script.js> [--asset id=path ...] --sheet N --out sheet.jpg
       sprocket-render <script.js> [--asset id=path ...] --check
options: --strict   treat warnings (unreadable or missing assets) as a failure: exit code 2
         --verbose  print the script's console.log output to stderr
"""

nonisolated(unsafe) var scriptPath: String?
nonisolated(unsafe) var assets: [String: URL] = [:]
nonisolated(unsafe) var outPath: String?
nonisolated(unsafe) var stillFrame: Int?
nonisolated(unsafe) var sheetCount: Int?
nonisolated(unsafe) var check = false
nonisolated(unsafe) var strict = false
nonisolated(unsafe) var verbose = false

var argv = Array(CommandLine.arguments.dropFirst())
func take(_ flag: String) -> String {
    guard !argv.isEmpty else { fail("\(flag) needs a value\n\(usage)") }
    return argv.removeFirst()
}
while !argv.isEmpty {
    let a = argv.removeFirst()
    switch a {
    case "--asset":
        let v = take(a)
        guard let eq = v.firstIndex(of: "="), eq != v.startIndex else { fail("--asset expects id=path, got \(v)") }
        let id = String(v[..<eq])
        let path = String(v[v.index(after: eq)...])
        assets[id] = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    case "--out": outPath = take(a)
    case "--still":
        guard let n = Int(take(a)), n >= 0 else { fail("--still expects a frame number") }
        stillFrame = n
    case "--sheet":
        guard let n = Int(take(a)), n > 0 else { fail("--sheet expects a positive count") }
        sheetCount = n
    case "--check": check = true
    case "--strict": strict = true
    case "--verbose": verbose = true
    case "-h", "--help": print(usage); exit(0)
    default:
        if a.hasPrefix("--") { fail("unknown option \(a)\n\(usage)") }
        if scriptPath == nil { scriptPath = a } else { fail("unexpected argument \(a)\n\(usage)") }
    }
}
guard let scriptPath else { fail(usage) }
let source: String
do { source = try String(contentsOf: URL(fileURLWithPath: (scriptPath as NSString).expandingTildeInPath), encoding: .utf8) }
catch { fail("cannot read \(scriptPath): \(error.localizedDescription)") }

func describe(_ error: Error) -> String {
    (error as? SprocketError)?.errorDescription ?? error.localizedDescription
}

func nodeCount(_ n: Node) -> Int {
    1 + (n.children ?? []).reduce(0) { $0 + nodeCount($1) } + (n.mask ?? []).reduce(0) { $0 + nodeCount($1) }
}

func writeImage(_ image: CGImage, to path: String) throws {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let ext = url.pathExtension.lowercased()
    let type = (ext == "jpg" || ext == "jpeg") ? "public.jpeg" : "public.png"
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
        throw SprocketError(.export, "cannot create \(path)")
    }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw SprocketError(.export, "cannot write \(path)") }
}

/// N frames tiled into one picture, each tile labelled with its frame number.
func makeSheet(_ tiles: [(frame: Int, image: CGImage)], aspect: Double) throws -> CGImage {
    let n = tiles.count
    let cols = max(1, Int((Double(n) / aspect).squareRoot().rounded(.up)))
    let rows = Int((Double(n) / Double(cols)).rounded(.up))
    let tileW = aspect >= 1 ? 480 : 270
    let tileH = Int((Double(tileW) / aspect).rounded())
    let gap = 6
    let W = cols * tileW + (cols + 1) * gap, H = rows * tileH + (rows + 1) * gap
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw SprocketError(.export, "cannot create the sheet")
    }
    ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.interpolationQuality = .high
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 15, nil)
    for (i, tile) in tiles.enumerated() {
        let col = i % cols, row = i / cols
        let x = gap + col * (tileW + gap)
        let y = H - (gap + (row + 1) * tileH + row * gap)   // CG origin is bottom-left
        ctx.draw(tile.image, in: CGRect(x: x, y: y, width: tileW, height: tileH))
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "f\(tile.frame)", attributes: attrs))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.7))
        ctx.fill(CGRect(x: x, y: y + tileH - Int(bounds.height) - 10, width: Int(bounds.width) + 12, height: Int(bounds.height) + 10))
        ctx.textPosition = CGPoint(x: x + 6, y: y + tileH - Int(bounds.height) - 4)
        CTLineDraw(line, ctx)
    }
    guard let out = ctx.makeImage() else { throw SprocketError(.export, "cannot create the sheet") }
    return out
}

// MARK: signals

/// SIGINT / SIGTERM cancel the running job and wait for it to clean up; the process then exits 130 / 143.
final class Interrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var _code: Int32 = 0
    private var job: Task<Void, Error>?
    var code: Int32 { lock.lock(); defer { lock.unlock() }; return _code }
    func attach(_ job: Task<Void, Error>) {
        lock.lock(); self.job = job; let c = _code; lock.unlock()
        if c != 0 { job.cancel() }
    }
    func fire(_ c: Int32, outPath: String?) {
        lock.lock()
        let first = _code == 0
        if first { _code = c }
        let j = job
        lock.unlock()
        guard first else { return }
        err(c == 130 ? "interrupted: cancelling" : "terminated: cancelling")
        j?.cancel()
        // Backstop: if the job has not wound down in 20 s, remove the partial output ourselves and go.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            if let outPath { removePartialOutput(outPath) }
            exit(c)
        }
    }
}

/// The output file and AVAssetWriter's temp file beside it (`name.mp4.sb-xxxx`).
func removePartialOutput(_ path: String) {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let fm = FileManager.default
    try? fm.removeItem(at: url)
    let dir = url.deletingLastPathComponent()
    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix(url.lastPathComponent + ".sb-") {
        try? fm.removeItem(at: dir.appendingPathComponent(name))
    }
}

let interrupt = Interrupt()
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let signalQueue = DispatchQueue(label: "sprocket.signals")
var signalSources: [DispatchSourceSignal] = []
for (sig, code) in [(SIGINT, Int32(130)), (SIGTERM, Int32(143))] {
    let src = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    src.setEventHandler { interrupt.fire(code, outPath: outPath) }
    src.resume()
    signalSources.append(src)
}

// MARK: job

var loadedScript: SprocketScript?   // kept so --verbose can print the script's logs even after a failure
var collectedWarnings: [String] = []

func printLogs() {
    guard verbose, let s = loadedScript else { return }
    for line in s.logs { err("log: \(line)") }
}

func noteWarnings(_ list: [String]) {
    for w in list where !collectedWarnings.contains(w) { collectedWarnings.append(w); err("warning: \(w)") }
}

func runJob() async throws {
    let script = try SprocketScript(source: source)
    loadedScript = script
    let config = script.config

    if check {
        var ids = Set<String>()
        var kinds: [String: Set<String>] = [:]
        var counts: [Int] = []
        var matteScan = MatteNeedScan()
        var webRequests = Set<WebRequest>()
        var webLayersPerFrame = 0
        let t0 = Date()
        for f in 0..<config.durationInFrames {
            if Task.isCancelled { throw SprocketError(.cancelled, "cancelled") }
            let node = try script.node(frame: f)
            counts.append(nodeCount(node))
            matteScan.add(node)
            if node.containsHTML {
                let resolved = node.resolvingWeb(frame: f, fps: config.fps, canvasWidth: config.width, canvasHeight: config.height)
                let reqs = try resolved.webRequests()
                webLayersPerFrame = max(webLayersPerFrame, reqs.count)
                webRequests.formUnion(reqs)
            }
            node.videoRequests.forEach { ids.insert($0.src); kinds[$0.src, default: []].insert("video") }
            node.imageSources.forEach { ids.insert($0); kinds[$0, default: []].insert("image") }
        }
        (config.audio ?? []).forEach { ids.insert($0.src); kinds[$0.src, default: []].insert("audio") }
        let data = (try? JSONEncoder().encode(config)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
        print("config: \(data)")
        print("duration: \(String(format: "%.2f", config.duration)) s, \(config.durationInFrames) frames")
        print("nodes per frame: min \(counts.min() ?? 0), max \(counts.max() ?? 0), mean \(String(format: "%.1f", Double(counts.reduce(0, +)) / Double(max(1, counts.count))))")
        print("assets used: " + ids.sorted().map { "\($0) (\(kinds[$0, default: []].sorted().joined(separator: "+")))" }.joined(separator: ", "))
        for need in matteScan.needs() {
            let to = need.end >= 1e9 ? "end" : String(format: "%.2f", need.end)
            let spans = need.ranges.count > 1 ? ", \(need.ranges.count) ranges: " + need.ranges.map { String(format: "%.2f", $0.lowerBound) + "-" + ($0.upperBound >= 1e9 ? "end" : String(format: "%.2f", $0.upperBound)) }.joined(separator: " ") : ""
            print("mask needed: clip \(need.src), kind \(need.kind), source time \(String(format: "%.2f", need.start))-\(to) s\(spans)")
        }
        if !webRequests.isEmpty {
            // One line per distinct page (markup + size): how many page times it needs, or 1 when nothing on it can move.
            struct PageKey: Hashable { var digest: String; var w: Int; var h: Int }
            var pages: [PageKey: (times: Set<Int>, markup: String)] = [:]
            for r in webRequests { pages[PageKey(digest: r.digest, w: r.width, h: r.height), default: (Set(), r.markup)].times.insert(r.micros) }
            print("html layers: up to \(webLayersPerFrame) per frame, \(pages.count) distinct page\(pages.count == 1 ? "" : "s")")
            for (k, v) in pages.sorted(by: { ($0.key.digest, $0.key.w) < ($1.key.digest, $1.key.w) }) {
                let animated = WebPageHeuristics.mentionsTime(v.markup)
                let n = animated ? v.times.count : 1
                print("  html page \(k.digest.prefix(8)): \(k.w)x\(k.h), \(v.markup.utf8.count / 1024) KB markup, \(v.times.count) distinct page time\(v.times.count == 1 ? "" : "s"), \(n) picture\(n == 1 ? "" : "s") to render" + (animated ? "" : " (no animation, script or --t: rendered once)"))
            }
        }
        if assets.isEmpty {
            if !ids.isEmpty { print("assets provided: none (pass --asset id=path to check that the files are usable)") }
        } else {
            for id in ids.sorted() {
                for kind in kinds[id, default: []].sorted() {
                    if let k = AssetCheck.Kind(rawValue: kind), let problem = await AssetCheck.problem(id: id, kind: k, assets: assets) {
                        noteWarnings([problem])
                    }
                }
            }
        }
        print("ok: evaluated \(counts.count) frames in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        return
    }

    guard let outPath else { fail("--out is required\n\(usage)") }
    let outURL = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
    let exporter = SprocketExporter(script: script, assets: assets)
    let start = Date()

    if let f = stillFrame {
        let image = try await exporter.still(frame: f)
        try writeImage(image, to: outPath)
        noteWarnings(exporter.warnings)
        let s = Date().timeIntervalSince(start)
        print("frames=1 seconds=\(String(format: "%.2f", s)) fps=\(String(format: "%.1f", 1 / max(s, 1e-6))) out=\(outURL.path)")
    } else if let n = sheetCount {
        let total = config.durationInFrames
        let picks = (0..<n).map { n == 1 ? 0 : Int((Double($0) * Double(total - 1) / Double(n - 1)).rounded()) }
        var tiles: [(frame: Int, image: CGImage)] = []
        for (i, f) in picks.enumerated() {
            if Task.isCancelled { throw SprocketError(.cancelled, "cancelled") }
            err("sheet \(i + 1)/\(n) (frame \(f))")
            tiles.append((f, try await exporter.still(frame: f)))
        }
        noteWarnings(exporter.warnings)
        let sheet = try makeSheet(tiles, aspect: Double(config.width) / Double(config.height))
        try writeImage(sheet, to: outPath)
        let s = Date().timeIntervalSince(start)
        print("frames=\(n) seconds=\(String(format: "%.2f", s)) fps=\(String(format: "%.1f", Double(n) / max(s, 1e-6))) out=\(outURL.path)")
    } else {
        final class Throttle: @unchecked Sendable { var last = Date.distantPast }
        let throttle = Throttle()
        exporter.prepareHandler = { p in
            err("\(p.kind == "web" ? "page" : "mask") \(p.index)/\(p.count) (\(p.src), \(p.kind)): frame \(p.frame)/\(p.total)")
        }
        try await exporter.export(to: outURL) { p in
            let now = Date()
            if now.timeIntervalSince(throttle.last) > 0.25 || p.frame == p.total {
                throttle.last = now
                err("frame \(p.frame)/\(p.total)")
            }
        }
        noteWarnings(exporter.warnings)
        let s = Date().timeIntervalSince(start)
        print("frames=\(config.durationInFrames) seconds=\(String(format: "%.2f", s)) fps=\(String(format: "%.1f", Double(config.durationInFrames) / max(s, 1e-6))) out=\(outURL.path)")
    }
}

let job = Task { try await runJob() }
interrupt.attach(job)
do {
    try await job.value
} catch {
    // The job has finished winding down (the exporter removed its partial files before throwing).
    printLogs()
    if interrupt.code != 0 {
        if let outPath, stillFrame == nil, sheetCount == nil, !check { removePartialOutput(outPath) }
        err("cancelled")
        exit(interrupt.code)
    }
    fail(describe(error))
}
printLogs()
if interrupt.code != 0 { exit(interrupt.code) }
if strict && !collectedWarnings.isEmpty {
    err("error: --strict: \(collectedWarnings.count) warning\(collectedWarnings.count == 1 ? "" : "s"); exiting with status 2")
    exit(2)
}
