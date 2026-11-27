import Foundation
import CoreText
import CoreGraphics

/// The line layout of a `text` node (CoreText). One source of truth for drawing the text and for `layoutText()`, so a
/// script that draws each letter itself lines up exactly with the whole-string render.
struct TextLayout {
    struct Line {
        var ct: CTLine?                 // nil for an empty line (a blank paragraph)
        var paragraph: Int              // index into `paragraphs`
        var range: CFRange              // UTF-16 range inside that paragraph
        var width: Double               // typographic width without trailing whitespace (what align uses)
        var x: Double                   // where the line's pen starts, after alignment
        var top: Double                 // top of the line box
        var baseline: Double
    }
    var font: CTFont
    var syntheticItalic: Bool
    var lines: [Line]
    var paragraphs: [String]
    var size: Double, x: Double, y: Double, wrap: Double, spacing: Double
    var boxHeight: Double, ascent: Double, descent: Double

    /// Nil when the node draws nothing (empty string, size outside 1...4000, bad box). Same limits as the text node.
    static func make(_ n: Node, canvasWidth: Int) -> TextLayout? {
        guard let str = n.text, !str.isEmpty else { return nil }
        let size = fin(n.size) ?? 48
        guard size >= 1, size <= 4000 else { return nil }
        let x = fin(n.x) ?? 0, y = fin(n.y) ?? 0
        let wrap = fin(n.width) ?? Double(canvasWidth)
        guard wrap > 0, wrap < 1e6, abs(x) < 1e7, abs(y) < 1e7 else { return nil }
        let lh = (fin(n.lineHeight).flatMap { $0 > 0 ? $0 : nil }) ?? 1.2
        let spacing = fin(n.letterSpacing) ?? 0
        let align = n.align ?? "center"
        let italic = n.italic == true

        let font = RenderPass.makeFont(family: n.font, size: CGFloat(size), weight: n.weight, italic: italic)
        var attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: kCFBooleanTrue as Any]
        if spacing != 0 { attrs[kCTKernAttributeName] = spacing }

        // Break into lines: explicit newlines first, then wrap each paragraph at the box width.
        var raw: [(ct: CTLine?, paragraph: Int, range: CFRange)] = []
        let paragraphs = str.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        outer: for (pi, p) in paragraphs.enumerated() {
            if p.isEmpty { raw.append((nil, pi, CFRange(location: 0, length: 0))); continue }
            let astr = CFAttributedStringCreate(nil, p as CFString, attrs as CFDictionary)!
            let ts = CTTypesetterCreateWithAttributedString(astr)
            let total = CFAttributedStringGetLength(astr)
            var start = 0
            while start < total {
                var count = CTTypesetterSuggestLineBreak(ts, start, wrap)
                if count <= 0 { count = 1 }
                let r = CFRange(location: start, length: count)
                raw.append((CTTypesetterCreateLine(ts, r), pi, r))
                start += count
                if raw.count >= 400 { break outer }
            }
        }
        guard !raw.isEmpty else { return nil }

        let asc = Double(CTFontGetAscent(font)), desc = Double(CTFontGetDescent(font))
        let box = lh * size
        var lines: [Line] = []
        for (i, r) in raw.enumerated() {
            var width = 0.0, px = x
            if let line = r.ct {
                width = CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)
                switch align {
                case "left": px = x
                case "right": px = x + wrap - width
                default: px = x + (wrap - width) / 2
                }
            }
            let top = y + Double(i) * box
            lines.append(Line(ct: r.ct, paragraph: r.paragraph, range: r.range, width: width, x: px, top: top,
                              baseline: top + (box - (asc + desc)) / 2 + asc))
        }
        return TextLayout(font: font, syntheticItalic: RenderPass.needsSyntheticItalic(font, italic: italic), lines: lines,
                          paragraphs: paragraphs, size: size, x: x, y: y, wrap: wrap, spacing: spacing,
                          boxHeight: box, ascent: asc, descent: desc)
    }

    /// One entry per character of the original string (newline characters have no entry). Positions are canvas pixels:
    /// `x` is where the glyph is drawn when its own text node uses `align: "left"` at that x, `y` the top of its line box.
    struct Glyph { var char: String; var index: Int; var line: Int; var x: Double; var y: Double; var width: Double; var height: Double }

    func glyphs(original: String) -> [Glyph] {
        // Character index in the original string, counting newlines (a "\r\n" pair is one character).
        var charIndex: [Int: [Int]] = [:]      // paragraph -> char index per Character
        var p = 0, idx = 0
        charIndex[0] = []
        for ch in original {
            if ch == "\n" || ch == "\r\n" { p += 1; charIndex[p] = []; idx += 1; continue }
            charIndex[p, default: []].append(idx); idx += 1
        }
        var out: [Glyph] = []
        for (li, line) in lines.enumerated() {
            guard let ct = line.ct else { continue }
            let para = paragraphs[line.paragraph]
            let indices = charIndex[line.paragraph] ?? []
            // Where CoreText put each glyph (run positions include the letter spacing exactly; the line's offset-for-index
            // function splits the spacing around glyphs, so it is only the fallback for characters with no glyph of their own).
            var pen: [Int: (x: Double, adv: Double)] = [:]
            for run in (CTLineGetGlyphRuns(ct) as? [CTRun]) ?? [] {
                let n = CTRunGetGlyphCount(run)
                guard n > 0 else { continue }
                var pos = [CGPoint](repeating: .zero, count: n), adv = [CGSize](repeating: .zero, count: n), si = [CFIndex](repeating: 0, count: n)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &pos)
                CTRunGetAdvances(run, CFRange(location: 0, length: 0), &adv)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &si)
                for g in 0..<n where pen[si[g]] == nil { pen[si[g]] = (Double(pos[g].x), Double(adv[g].width)) }
            }
            // Walk the paragraph's characters; keep those whose UTF-16 span lies inside this line's range.
            var u16 = 0, ci = 0
            for ch in para {
                let len = ch.utf16.count
                defer { u16 += len; ci += 1 }
                guard u16 >= line.range.location, u16 + len <= line.range.location + line.range.length, ci < indices.count else { continue }
                var x: Double, w: Double
                if let p = pen[u16] { x = p.x; w = p.adv - spacing }   // the advance includes the letter spacing
                else {
                    x = Double(CTLineGetOffsetForStringIndex(ct, u16, nil))
                    w = max(0, Double(CTLineGetOffsetForStringIndex(ct, u16 + len, nil)) - x - spacing)
                }
                out.append(Glyph(char: String(ch), index: indices[ci], line: li, x: line.x + x, y: line.top, width: max(0, w), height: boxHeight))
                if out.count >= 5000 { return out }
            }
        }
        return out
    }
}
