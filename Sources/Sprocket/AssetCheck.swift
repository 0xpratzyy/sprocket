import Foundation
import AVFoundation
import ImageIO

/// Plain-language reasons why an asset the script uses cannot be drawn or heard.
public enum AssetCheck {
    public enum Kind: String, Sendable { case video, image, audio }

    /// The message for an asset that came back unusable: not provided, missing file, empty file, or unreadable.
    static func message(id: String, kind: Kind, url: URL?) -> String {
        guard let url else { return "asset \(id) is used by the script but was not provided" }
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return "asset \(id): file does not exist (\(url.path))" }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue ?? -1
        var m = "asset \(id): file is not a readable \(kind.rawValue) (\(url.path))"
        if size == 0 { m += "; the file is empty" }
        return m
    }

    /// An audio file that could not be used: unreadable, or readable but with no sound.
    static func audioProblem(id: String, url: URL, asset: AVURLAsset) async -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path), let tracks = try? await asset.load(.tracks), !tracks.isEmpty {
            return "asset \(id): file has no audio track (\(url.path))"
        }
        return message(id: id, kind: .audio, url: url)
    }

    /// Checks one asset the way the exporter would use it. nil means it is fine; otherwise the same message the exporter's
    /// `warnings` would carry. For `--check` and for hosts that want to validate assets before rendering.
    public static func problem(id: String, kind: Kind, assets: [String: URL]) async -> String? {
        guard let url = assets[id] else { return message(id: id, kind: kind, url: nil) }
        guard FileManager.default.fileExists(atPath: url.path) else { return message(id: id, kind: kind, url: url) }
        switch kind {
        case .video:
            let asset = AVURLAsset(url: url)
            if let t = try? await asset.loadTracks(withMediaType: .video), !t.isEmpty { return nil }
            return message(id: id, kind: kind, url: url)
        case .audio:
            let asset = AVURLAsset(url: url)
            if let t = try? await asset.loadTracks(withMediaType: .audio).first,
               let d = try? await asset.load(.duration).seconds, d.isFinite, d > 0, t.mediaType == .audio { return nil }
            return await audioProblem(id: id, url: url, asset: asset)
        case .image:
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
               CGImageSourceCreateImageAtIndex(src, 0, nil) != nil { return nil }
            return message(id: id, kind: kind, url: url)
        }
    }
}
