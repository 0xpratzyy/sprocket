import Foundation
import CoreImage
import ImageIO

/// Asset id -> CIImage, decoded with ImageIO (EXIF orientation applied) and cached.
public final class MediaImageStore: @unchecked Sendable {
    private let urls: [String: URL]
    private let capacity: Int
    private let lock = NSLock()
    private var cache: [String: CIImage] = [:]
    private var order: [String] = []

    public init(assets: [String: URL], capacity: Int = 24) {
        self.urls = assets
        self.capacity = max(1, capacity)
    }

    /// nil when the id is unknown or the file is not a readable image.
    public func image(src: String) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[src] { return c }
        guard let url = urls[src],
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        var orientation = CGImagePropertyOrientation.up
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let raw = props[kCGImagePropertyOrientation] as? UInt32,
           let o = CGImagePropertyOrientation(rawValue: raw) { orientation = o }
        var img = CIImage(cgImage: cg).oriented(orientation)
        let e = img.extent
        if e.origin != .zero { img = img.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y)) }
        cache[src] = img
        order.append(src)
        if order.count > capacity { cache.removeValue(forKey: order.removeFirst()) }
        return img
    }
}
