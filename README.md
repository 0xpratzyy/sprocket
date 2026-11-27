# Sprocket

**Video as code, rendered natively on iPhone and Mac.** You write a composition in JavaScript: one function that says what frame N looks like. Sprocket draws every frame with Core Image and Metal and writes the movie with AVFoundation. There is no browser and no server, and nothing leaves the device.

```js
composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 90,
              audio: [{ src: "music", volume: 0.9, fadeOut: 0.3 }] },
  function (frame, ctx) {
    const p = interpolate(frame, [20, 50], [0, 1], { easing: Easing.inOutCubic });
    return [
      video("c1", { time: frame / ctx.fps }),
      video("c2", { time: 2 + frame / ctx.fps, opacity: p }),
      text("LISBON", { y: 1500, size: 120, weight: 800, color: "#fff" }),
    ];
  });
```

```bash
swift build -c release
.build/release/sprocket-render title.js --asset c1=a.mp4 --asset c2=b.mp4 --asset music=song.m4a --out out.mp4
```

If you know Remotion, the idea is the same (a frame is a function of time), but the renderer is native code on the device instead of headless Chrome on a server.

## What it can draw

- **Nodes:** `group`, `solid`, `rect`, `ellipse`, `path` (SVG path data), `gradient`, `image`, `video`, `text`, `html`, `cutout`
- **On every node:** transforms including 3D tilt, blend modes, masks (alpha or luma), clips, opacity
- **Strokes:** dashes, trims (lines that draw themselves on), gradient fills, including on text
- **About 30 effects:** blurs (Gaussian, motion, zoom), glow, drop shadow, grain, colour grading, glitch, RGB split, halftone, duotone, wave, twirl, displace and more
- **Per-letter text:** `layoutText()` returns each glyph's box from the same CoreText layout `text()` draws with
- **Cut-outs:** `cutout(src)` gives a person or subject mask of a clip (Apple Vision), made once and cached
- **Web layer:** `html(markup)` draws HTML, CSS, SVG, canvas or WebGL as a transparent layer, frame-exact, in a sealed WKWebView
- **Audio:** clips from audio or video files, with offsets, volume and fades
- **Helpers:** `interpolate`, `spring`, `Easing`, seeded `random`, and transition helpers

The full authoring guide, with every prop, default, limit and error message, is [API.md](API.md).

Scripts are checked before drawing, and a mistake names the frame, node, prop and position: `frame 12: rect.color must be a string, got number (at root > group[2] > rect[14])`. Rendering is deterministic: `Math.random` and `Date` are replaced per frame.

## Use it from Swift

```swift
import Sprocket

let script = try SprocketScript(source: js)
let exporter = SprocketExporter(script: script, assets: ["c1": clipURL, "music": songURL])
try await exporter.export(to: outputURL)
```

`SprocketExporter` also renders single stills, and reports progress and warnings (missing assets, missing fonts). Requires iOS 26 or macOS 26, Swift 6 tools.

## CLI

```
sprocket-render <script.js> [--asset id=path ...] --out out.mp4
sprocket-render <script.js> [--asset id=path ...] --still N --out frame.png
sprocket-render <script.js> [--asset id=path ...] --sheet N --out sheet.jpg
sprocket-render <script.js> [--asset id=path ...] --check
  --strict   treat warnings (unreadable or missing assets) as a failure: exit code 2
  --verbose  print the script's console.log output to stderr
```

## How fast, and how heavy

Measured on a Mac mini (Apple M4, 10 cores, 16 GB) on 27 Nov 2026, against Remotion 4.0.547, HyperFrames 0.9.102 and Kinetograph 0.3.0 (a Rust renderer). Each engine ran with its defaults. Times are wall clock for the whole render, median of 3 runs after a warm-up.

**Three 10-second test scenes** (reproduce with [bench/](bench/)):

| Scene | Sprocket | Kinetograph | Remotion | HyperFrames |
|---|---|---|---|---|
| Title card: text, shapes | **1.5 s** | 2.4 s | 5.6 s | 6.0 s |
| 48 shadowed cards and a big blur | 8.5 s | 6.7 s | 8.3 s | 11.1 s |
| Video with word captions and audio | **1.6 s** | 4.5 s | 11.2 s | 9.7 s |

**A 17-second motion-graphics ad, rebuilt frame by frame.** The ad is full of glows, blurs and gradients. Every engine drew the same scene description:

| Engine | Wall time | CPU time | Peak memory |
|---|---|---|---|
| **Sprocket** | 6.3 s | **5.9 s** | **0.4 GB** |
| Kinetograph | 3.0 s | 16–19 s | 2.4 GB |
| Remotion | 7.7 s | 38 s | 3.2 GB |
| HyperFrames | 8.2 s | 43 s | 3.3 GB |

Sprocket uses about one CPU core and the GPU. The browser-based engines spread over 5–6 cores and several gigabytes, and Kinetograph also skips drawing repeated frames. For a phone, CPU time and memory are what count: battery, heat, and not getting killed in the background.

## Known weak spots

- **Heavy blur and shadows are the slow path.** 48 cards, each with a drop shadow, render at 35 fps.
- **One core.** Frames are drawn one after another. Spreading the work over cores is the next improvement. Repeated frames are already skipped: a frame whose tree equals the previous frame's is written again without being drawn.
- **The `html()` web layer is slow on heavy pages:** about 0.9 s per 1080×1920 frame with many shadows and a big blur. Use native nodes whenever they can do the job.
- **Fonts:** only fonts installed on the device. There is no `@font-face` loading yet.
- Speeds above are from a Mac. **Phone numbers haven't been published yet.**

## Status

Beta. The authoring API is documented and checked, but it can still change. Issues and pull requests are welcome.

## Licence

[Apache 2.0](LICENSE).
