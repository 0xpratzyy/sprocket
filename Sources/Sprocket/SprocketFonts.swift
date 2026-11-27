import Foundation
import CoreText

/// The fonts a script may name in a `text` node's `font` prop.
public enum SprocketFonts {
    /// The font family names installed on this device (system and user-installed), sorted, without hidden families
    /// (names starting with "."). A host puts this list in the prompt so the author only names fonts that exist.
    public static func familyNames() -> [String] {
        let all = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return all.filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: Bool] = [:]

    /// True when `family` resolves to an installed font (same test the renderer uses before it falls back to the system font).
    /// Cached per name.
    static func isInstalled(_ family: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let k = family.lowercased()
        if let v = known[k] { return v }
        let v = RenderPass.installedFont(family: family, size: 12, weight: 400) != nil
        known[k] = v
        return v
    }

    /// The warning for a font that is not installed.
    static func missingMessage(_ family: String) -> String { "font \"\(family)\" is not installed; drew the system font" }
}

extension Node {
    /// Every `font` family named by a text node in this tree (children and masks included).
    var textFontFamilies: Set<String> {
        var out = Set<String>()
        func walk(_ n: Node) {
            if n.type == "text", let f = n.font, !f.isEmpty { out.insert(f) }
            n.children?.forEach(walk); n.mask?.forEach(walk)
        }
        walk(self)
        return out
    }
}
