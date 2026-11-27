# Benchmark

Three 10-second vertical videos (1080×1920, 30 fps, 300 frames), each written once per engine with the same maths:

| Scene | What it draws |
|---|---|
| `title` | gradient background, two lines of text animating in, three moving circles, a progress bar |
| `cards` | 48 rotating gradient cards with drop shadows over an 80 px blurred blob |
| `video` | a full-frame clip, a caption band and popping word captions, with audio |

Engines: Sprocket (`sprocket/*.js`), Remotion (`remotion/src/Root.tsx`), HyperFrames (`hyperframes/*/index.html`), and Kinetograph, which renders both the Remotion and the HyperFrames versions.

```bash
./setup.sh   # installs the engines here, makes the test clip, builds sprocket-render
./run.sh     # 1 warm-up + 3 timed runs per engine and scene, prints medians
```

`sprocket/cards-html.js` draws the cards scene through Sprocket's `html()` web layer instead of native nodes. It isn't in `run.sh` because it's very slow; see the main README.

## Results (Mac mini, Apple M4, 10 cores, 16 GB, macOS 26.5, 27 Nov 2026)

Remotion 4.0.547, HyperFrames 0.9.102, Kinetograph 0.3.0. Wall-clock time of the whole command, median of 3 runs after a warm-up, each engine with its defaults.

| Scene | Sprocket | Kinetograph (TSX) | Kinetograph (HTML) | Remotion | HyperFrames |
|---|---|---|---|---|---|
| title | **1.49 s** | 2.40 s | 2.46 s | 5.61 s | 5.96 s |
| cards | 8.50 s | 6.74 s | 6.79 s | 8.28 s | 11.10 s |
| video | **1.61 s** | 4.47 s | 4.57 s | 11.22 s | 9.74 s |

Encoders differ by default: Sprocket uses the hardware encoder (VideoToolbox), the others use libx264.
