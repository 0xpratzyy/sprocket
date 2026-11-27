# Sprocket: the authoring API

A composition is one JavaScript file. It declares the canvas once and gives a function that returns what one frame looks like. The engine calls that function for frame 0, 1, 2 … and draws what it returns. Nothing else runs: no network, no files, no timers, no DOM (except inside an `html()` layer's own sealed web page, below).

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

## Rules

- `composition(config, render)` must be called exactly once, at the top level.
- `render(frame, ctx)` returns a node, an array of nodes (drawn first to last, last on top), or `null`. Arrays may nest; `null`, `undefined` and `false` entries are dropped.
- `ctx` is `{ frame, fps, width, height, durationInFrames, time }` where `time = frame / fps`.
- The function must be pure: the same frame always returns the same tree. `Math.random()` and `Date` are replaced with deterministic versions (`Math.random` is seeded per frame; `Date.now()` is the frame's time in ms). Use `random(seed)` for stable randomness.
- Coordinates are pixels, origin top-left, y down. Colours are CSS strings: `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()`, `hsl()`, `hsla()`, and the names `white black red green blue yellow orange purple pink gray transparent`.
- Assets are referred to by id (`"c1"`, `"music"`). The host maps ids to files. An id that is not in the host's map, or a file that is missing, empty or not a readable video / image / audio file, draws nothing (or plays nothing) and the render still finishes; the host is told through `SprocketExporter.warnings` (the CLI prints them to stderr; `--strict` turns them into exit code 2). Read the warnings: a silent blank where a clip should be is almost always a wrong id or path.
- Limits: loading the script may take at most 2 s; one `render` call at most 250 ms; one frame's tree at most 5,000 nodes. Past a limit the engine throws a SprocketError with kind `timeout` or `script`.
- `console.log(...)` (also `info`, `warn`, `error`, `debug`) exists. Output is collected in `SprocketScript.logs` (at most 200 lines of 2,000 characters) and is never drawn. `sprocket-render --verbose` prints the lines to stderr as `log: ...` after the run, also when the run failed. Use it to find out what a value is.

## Config

`composition(config, render)`: `config` is `{ width, height, fps, durationInFrames, background?, audio? }`.

| Field | Rule |
|---|---|
| `width`, `height` | integers, `16...4096`, and **even** (video encoders need even sizes). An odd size is an error, it is not rounded. |
| `fps` | integer `1...120` (`29.97` is an error; use `30`) |
| `durationInFrames` | integer `1...36000` |
| `background` | a colour (default black); the frame is always drawn over black first, so it ends up opaque |
| `audio` | optional array of audio clips, below |

A fractional, non-numeric, missing or out-of-range value throws at the `composition(...)` call with a message that names the field and the rule, for example `invalid composition config: width must be an even number, got 541 (odd sizes are an error, not rounded; use 540 or 542)`, with the line of the call.

### Audio clips

Each entry of `audio` is `{ src, startFrame, offset, durationInFrames, volume, fadeIn, fadeOut }`:

| Field | Meaning |
|---|---|
| `src` | asset id of an audio file, or of a video file whose sound is used. Required. |
| `startFrame` | integer frame on the composition timeline where the clip starts. Default 0. Not negative. |
| `offset` | seconds into the source where playback starts. Default 0. |
| `durationInFrames` | integer frames to play. Default: to the end of the source or of the composition, whichever is first. A clip never runs past the end of the composition. |
| `volume` | 0...1 (clamped). Default 1. |
| `fadeIn`, `fadeOut` | seconds of linear fade at the start / end of the clip's played part. Default 0. If the two together are longer than the clip they are shrunk in proportion. |

Clips mix together (several may overlap). The audio track of the exported file always lasts exactly as long as the picture: when the clips end early (or start late) the rest is silence. A clip whose asset is missing or has no sound is skipped with a warning; if no clip is usable the file has no audio track.

## Nodes

Every constructor returns a plain object `{ type, ...props }`. All take an optional last `props` object. Props every node accepts:

| Prop | Meaning |
|---|---|
| `opacity` | 0…1; values outside are clamped (`99` is 1, `-5` is 0); `NaN` counts as 1 |
| `transform` | `{ translateX, translateY, scale, scaleX, scaleY, skewX, skewY, rotateX, rotateY, perspective, rotate, originX, originY }`. Degrees for `skewX`, `skewY` (CSS meaning: `skewX` slides the bottom right, `skewY` slides the right side down), `rotateX`, `rotateY` (3D tilt like CSS: positive `rotateX` tips the top away from the viewer, positive `rotateY` the right side away) and `rotate` (clockwise, in the screen plane). `perspective` is the camera distance in px (default 1000; smaller is a stronger tilt); a corner that would reach the camera makes the node vanish. Origin defaults to the canvas centre. Order, all about the origin: scale, skew, 3D tilt, rotate, translate. |
| `blend` | `normal multiply screen overlay add darken lighten softLight hardLight difference`. Inside a group a blend mode blends only against the siblings drawn before it in that same group (the group is flattened first, then blended as one layer against what is below it). |
| `mask` | a node or array; this node shows only where the mask is opaque. `maskMode: "luma"` uses brightness instead (white shows, black hides). The mask is drawn in canvas space, not in the node's transformed space. A mask that draws nothing hides the node. |
| `clip` | `{ x, y, width, height, radius? }` in canvas pixels (canvas space, after the transform). `x`, `y`, `width`, `height` are required. |
| `effects` | array from the effects table below, applied in order |

### Order of operations per node

The renderer applies a node's props in this fixed order, regardless of the order you write them:

1. draw the content (children, shape, picture, text)
2. `effects`, in array order
3. `transform` (scale, skew, 3D tilt, rotate, translate, about the origin)
4. `clip`
5. `mask`
6. `opacity`
7. `blend`, onto what has been drawn below it (in the same group)

`clip` and `mask` are in **canvas space**: they are applied after the transform, so a node that is moved or rotated slides under a fixed clip or mask. To make a clip follow a moving node, move the clip's `x`/`y` as well, or put the node in a `group` that carries the clip and animate the group's content instead.

### Non-finite and out-of-range numbers

One rule: **a non-finite (`NaN`, `Infinity`, `-Infinity`) geometry value makes the node draw nothing**, the same as a negative size does. Geometry values are `x`, `y`, `width`, `height`, `radius`, `size`, `strokeWidth`, every `transform` number, the four `clip` numbers, and the points of a gradient's `from` / `to` (also inside `fill`). The node's children, mask and effects vanish with it. (A hidden node used as a `mask` still masks: the masked node disappears.) A negative `width` or `height` also draws nothing.

Other values keep a meaning instead of hiding the node:

| Value | Result |
|---|---|
| `opacity` | clamped to 0...1; `NaN` is ignored (counts as 1) |
| video `time` before 0 or `-Infinity` | holds the first frame; `NaN` is the first frame |
| video `time` past the end of the file or `Infinity` | holds the last frame |
| `strokeWidth` | clamped to the canvas diagonal, so `1e9` cannot turn a line into a filled canvas |
| any other `NaN` / `Infinity` (effect parameters, `lineHeight`, `focusX`, ...) | dropped: the default applies; inside a `colorMatrix` matrix it becomes 0 |

### Validation

The tree a frame returns is checked before it is drawn. A wrong type is an error that names the node, the prop and the position, for example
`frame 12: rect.color must be a string, got number (at root > group[2] > rect[14])`.
The path counts children after nested arrays and `null` / `false` entries are removed (`root` is the array `render` returned; `group[2]` is its third node). Other messages: `gradient stops[1] is missing "at"`, `clip is missing "height"`, `effects must be an array`, `mask must be a node or array of nodes, got string`, `video is missing "src"`, `text(): the first argument must be a string ...` (also thrown with the line of the `text(null)` call). `null` and `undefined` props mean "not set". Props the engine does not know are ignored.

An object whose `type` is not one of `group solid rect ellipse path gradient image video text html` is an error, not an empty node: `unknown node type "bogus"; valid types: group, solid, rect, ellipse, path, gradient, image, video, text, html (at root > bogus)`. Unknown effect `name`s are still ignored.

| Constructor | Draws |
|---|---|
| `group(children, props)` | children in order, then the group's own opacity / transform / mask / effects on the result |
| `solid(color, props)` | the whole canvas in one colour |
| `rect(x, y, width, height, props)` | `color`, `radius`, `stroke`, `strokeWidth`, and the stroke / fill props in "Strokes and gradient fills" below |
| `ellipse(x, y, width, height, props)` | same props as rect; x, y is the top-left of its box |
| `path(d, props)` | SVG path data in canvas pixels (`M L H V C S Q T A Z`, absolute and relative); `color` (fill), `stroke`, `strokeWidth`, plus the same stroke / fill props |
| `gradient(stops, props)` | `stops: [{ at: 0…1, color }]` (at least one; sorted by `at`), `kind: "linear" \| "radial"`, `from: {x,y}`, `to: {x,y}`; optional `x, y, width, height` box (default the canvas). Defaults below. |
| `image(src, props)` | `x, y, width, height` box (default the canvas), `fit`, `focusX`, `focusY` |
| `video(src, props)` | `time` (seconds into the source, required for motion; before 0 holds the first frame, past the end of the file holds the last), box, `fit: "cover" \| "contain" \| "fill"` (default cover), `focusX`, `focusY` (0…1, default 0.5) |
| `cutout(src, props)` | a white-on-black **mask** of clip `src` (a person, or the main foreground thing) at source time `time`. Same box / fit / focus props as `video`, so it lines up with the clip drawn underneath. Use it as a `mask`. See Cut-outs below. |
| `html(markup, props)` | a **web layer**: the HTML / CSS / SVG / canvas page `markup` drawn as a transparent picture. `x, y, width, height` box (default the canvas), `time` (page seconds, default `frame / fps`). See Web layer below. |
| `text(string, props)` | `x` (default 0), `y` (top of the text block), `width` (wrap width, default canvas width), `font` (family name), `size`, `weight` 100…900, `italic` (true / false), `color`, `fill` (gradient, below), `align: "left" \| "center" \| "right"` (default center), `lineHeight`, `letterSpacing`, `stroke`, `strokeWidth`, `shadow: { color, blur, x, y }`. The string must be a string or a number (`text(null)` is an error); `"\n"` starts a new line. Defaults below. |

### Defaults

Text: colour **white**, `size` **48** (valid 1...4000), `weight` 400, `lineHeight` **1.2** (a multiple of `size`), `align` `"center"` inside the `width` box (so with the default `x: 0` and full-canvas width the text is centred on the canvas), `letterSpacing` 0, no stroke, no shadow (`shadow` without a colour uses `rgba(0,0,0,0.5)`). `font` takes a family name from the installed-fonts list the host puts in the prompt; a missing `font`, or one that is not installed, draws the system font (and `SprocketExporter.warnings` says `font "X" is not installed; drew the system font`, once). `weight` is the usual scale: 100 thin, 300 light, 400 regular, 500 medium, 600 semibold, 700 bold, 800 heavy, 900 black; a family without that exact weight gives the nearest it has. `italic: true` asks for the family's italic face; a family without one is slanted instead.

Gradient: `kind` is `"linear"`, the box is the whole canvas. Linear: `from` is the box's top-left corner and `to` is straight below it at the box's bottom edge (so the default runs top to bottom). Radial: `from` is the box centre and `to` is `max(width, height) / 2` to the right of `from`. The colour before the first stop and after the last stop is held. One stop (or `from` equal to `to`) fills with the last stop's colour. An unparseable stop colour is transparent. `at` outside 0...1 is clamped.

Shapes: `rect` and `ellipse` default to the whole canvas for a missing `x, y, width, height` (but see the non-finite rule: a *non-finite* value is not "missing"); a stroke is drawn only when `stroke` is set, with `strokeWidth` default 1, centred on the outline; no `color` means no fill. `image` and `video`: `fit` `"cover"`, `focusX` / `focusY` 0.5, box = the canvas. `solid` needs a colour.

## Strokes and gradient fills

Stroke props on `rect`, `ellipse`, `path` (all need `stroke` set to show):

| Prop | Meaning |
|---|---|
| `lineCap` | `"butt"` (default), `"round"`, `"square"`; the ends of open lines and of every dash |
| `lineJoin` | `"miter"` (default), `"round"`, `"bevel"`; unknown values use the default |
| `dash` | `[on, off, on, off, ...]` in px, repeating; entries must be `>= 0` and not all 0. With `lineCap: "round"`, `[0, 20]` draws dots. |
| `dashOffset` | px into the pattern where the stroke starts; animate it to march the dashes |
| `trim` | `{ start, end }`, fractions 0…1 of the outline's length; only that part of the stroke is drawn (the fill is not affected). `end <= start` draws no stroke. Length is counted across all sub-paths of a `path`, in order. Animate `end` from 0 to 1 for a line that draws itself on. A `rect` outline starts at its top-left corner (a rounded one just after it, on the top edge), an `ellipse` at 12 o'clock, both running clockwise. A trimmed curve is drawn as many short straight pieces (round `lineJoin` hides that). |

`fill` on `rect`, `ellipse`, `path` and `text` is a gradient object `{ kind, stops, from, to }`, with the same meaning as the `gradient` node's fields (`from` / `to` in canvas pixels). It replaces `color`. When `from` / `to` are missing they default relative to the shape's bounding box (for text: the text's own lines, not the wrap width). For text it fills the glyphs (chrome, gold); `stroke` stays a solid colour.

```js
text("CHROME", { y: 700, size: 220, weight: 900, italic: true, stroke: "#1e1b4b", strokeWidth: 4,
  fill: { stops: [{ at: 0, color: "#fff" }, { at: 0.48, color: "#8a93a6" }, { at: 0.5, color: "#1c2030" }, { at: 1, color: "#fff" }] } })
path("M60 900 C300 700 700 1100 1020 880", { stroke: "#7dd3fc", strokeWidth: 24, lineCap: "round", trim: { start: 0, end: p } })
```

## Per-letter text

`layoutText(string, props)` takes the same props as `text()` and returns one entry per character: `{ char, index, line, x, y, width, height }` in canvas pixels, from exactly the layout `text()` draws with (CoreText: it respects `font`, `size`, `weight`, `italic`, `letterSpacing`, `align`, `width` wrapping, `lineHeight`). `index` is the position in the string (a newline counts but has no entry), `line` the 0-based line, `x` where the glyph's pen starts, `y` the top of its line box, `width` the glyph's advance (without `letterSpacing`), `height` the line box height (`size * lineHeight`). Draw each letter as its own `text` with `align: "left"`, the entry's `x` and `y`, and the same other props; then it sits exactly where it sits in the whole string, and each letter can have its own transform, opacity, colour or effects. Use `width` of at least the letter's width (a wide box such as 300 is fine) so it never wraps. `layoutText("")` returns `[]`. The `transform.originX` / `originY` of a letter are canvas pixels: use `x + width / 2` and `y + height / 2` to spin it about its centre.

```js
const P = { y: 800, size: 120, weight: 800, letterSpacing: 4 };
layoutText("LAUNCH", P).map((g) =>
  text(g.char, { ...P, x: g.x, y: g.y - 80 * (1 - spring({ frame: frame - g.index * 3, fps: ctx.fps })), width: 300, align: "left" }))
```

## Cut-outs

`cutout(src, { time, kind })` returns a node that draws a mask of the clip `src` at source time `time`: white where the thing is, black elsewhere. `kind` is `"person"` (default) or `"subject"` (the main foreground thing, of any kind); any other value is an error (`cutout kind must be "person" or "subject", got "banana"`). The script never makes mask files: the engine does it the first time a clip needs one. It takes the box / `fit` / `focusX` / `focusY` props of `video`, and draws exactly where `video(src, sameProps)` would, whatever the mask's own resolution.

Use it as a luma mask, over the clip it was cut from. This recolours only the person and leaves the background playing normally:

```js
composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 90 }, function (frame, ctx) {
  const time = 2 + frame / ctx.fps;                     // the same time for the clip and its mask
  return [
    video("c1", { time }),                              // background plays as is
    solid("#ff2d55", { mask: cutout("c1", { time }), maskMode: "luma" }),   // person: flat colour
  ];
});
```

Swap the `solid` for `image("t3", { mask: cutout("c1", { time }), maskMode: "luma" })` to fill the person with a texture, or a `gradient`, or a second `video(...)`; a different texture on every frame is just a different `src`/`time` per frame. Put `blend`, `opacity` and `effects` on the masked node as usual. With `kind: "subject"` the mask is the main foreground object instead.

How it behaves:

- A cut-out is a `video` node with an extra field `matte: "person" | "subject"` in the tree. The clip and its mask are different pictures of the same asset id.
- Before rendering, the engine evaluates every frame of the script to learn which source times of each clip need a mask, and makes the mask for just those times (plus 0.25 s on each side), not the whole clip. A 1 s shot out of a 60 s clip masks about 1.5 s. Shots far apart in the same clip are made as separate stretches.
- Masks are made at a reduced size (long side about 768) and drawn upscaled with lightly feathered edges. Mask frames carry the same presentation times as the clip's own frames.
- The mask videos are cached on disk in a `Sprocket-mattes` folder under the system caches folder, keyed by the clip's path, size, modification date and kind, so a second export of the same clip is instant. `SprocketExporter.clearMatteCache()` empties it.
- Vision finds nothing on a frame: that frame's mask is black (the masked node is hidden there). The clip cannot be read: `SprocketExporter.warnings` says so, and the mask draws nothing.
- Making masks is the slow part (roughly 25 frames/s for `"person"` and 60 for `"subject"` on a Mac). Hosts can watch it through `SprocketExporter.prepareHandler`.

## Web layer

`html(markup, props)` draws anything the web can draw as one transparent layer: HTML, CSS (`@keyframes`, filters, `backdrop-filter`, 3D transforms, `clip-path`, gradients, blend modes), inline `<svg>`, `<canvas>` 2D, WebGL, and the system fonts. It is composited like any other node, so `opacity`, `transform`, `mask`, `clip`, `effects` and `blend` all apply to it.

```js
composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 90 }, function (frame, ctx) {
  return [
    video("c1", { time: frame / ctx.fps }),                 // footage is always a native video() node
    html(`<style>
            h1 { font: 800 140px Helvetica; color: white; animation: pop .6s cubic-bezier(.2,1.4,.4,1) both; }
            @keyframes pop { from { transform: scale(.3); opacity: 0 } to { transform: none; opacity: 1 } }
          </style><h1>HELLO</h1>`,
         { x: 0, y: 700, width: 1080, height: 300 }),
  ];
});
```

- `markup` is an HTML string (a fragment, or a whole document); it may contain `<style>`, `<svg>`, `<canvas>` and `<script>`. The page's background is transparent: draw your own background if you want one.
- `x, y, width, height`: the box in canvas pixels (default the whole canvas). The page's viewport is exactly the box size, **1 CSS px = 1 canvas px**; a fractional size is rounded up. Each side at most 4096.
- `time`: the page time in seconds that this frame shows. Default: the composition's time, `frame / fps`. Give a number to hold a pose or to run the page on its own clock (`time: Math.max(0, ctx.time - 2)` starts it 2 s in).

**Time is frozen and set by the engine, not by the clock.** For every frame that shows the layer at page time `t` the engine, in this order: (1) pauses every CSS animation, CSS transition and Web Animation and sets its `currentTime` to `t * 1000` (SVG SMIL animations are seeked to `t` too), so plain `@keyframes` animate correctly and frame-exactly with no extra work; (2) sets the CSS custom properties `--t` (seconds, unitless: `width: calc(var(--t) * 100px)`) and `--frame` on `:root`; (3) runs `setTimeout` / `setInterval` timers that are due by `t`, then `requestAnimationFrame` callbacks, then calls `window.sprocketFrame(t, frame)` if the page defines it (it may be `async`; it is awaited); (4) waits for layout and paint and takes the picture.

- For canvas, WebGL or any JavaScript drawing, define `window.sprocketFrame = function (t, frame) { ... }` and draw the whole picture from `t` (clear and redraw each call; do not keep state between calls, a frame may be asked for on its own).
- `Date.now()` and `performance.now()` return `t * 1000`, `Math.random()` is seeded (the same every time the page loads), timers and `requestAnimationFrame` only run inside the step. Never depend on the wall clock. Timers and `requestAnimationFrame` advance only for the times that are rendered; prefer CSS animations, `--t` and `sprocketFrame`, which are exact for any single frame.
- A page with no animation, no script timers, no `sprocketFrame` and no mention of `--t` / `--frame` is drawn once and that picture is reused for every frame.

**Sealed page.** No network and no files: `fetch`, `XMLHttpRequest`, WebSocket, `<link>`, `<script src>`, `<iframe src>`, `http(s):` and `file:` images all fail. Only `data:` URLs work inline (`url(data:...)`, base64 fonts and images). To show one of the host's image assets use `sprocket-asset://ID` with the asset id: `<img src="sprocket-asset://c3">`, `background: url(sprocket-asset://c3)`, SVG `<image href="sprocket-asset://c3">`. Only image assets are served (not video or audio; an unknown id is a 404). Fonts are the installed system font families (`font-family: "Helvetica Neue"`); `@font-face` with a remote file does not work. `console.log` in the page goes to the script's logs, prefixed `html: `.

**Limits.** Markup at most 200 KB. Page load at most 5 s, one frame step at most 1 s. A page error (an uncaught exception or rejected promise during load or in a step, a script syntax error) or a limit stops the export with a `SprocketError` of kind `script` whose message starts `html:` and names the error and the page time, for example `html: the page threw an error at t = 1.200 s: sprocketFrame: Cannot read properties of null`.

**When to use it.** Use native nodes (`rect`, `path`, `text`, `gradient`, effects) whenever they can do the job: they are much faster. Video footage is always a native `video()` node, never an html `<video>`. Use `html()` for graphics, text and illustration layers the native nodes cannot make: CSS-styled text with gradients and glows, SVG drawings that draw themselves on, canvas or WebGL generative art, 3D-transformed cards. Each distinct (markup, size) page is loaded once and every frame needs one snapshot, so on a Mac an animated layer costs roughly 20-60 ms per frame at 540x960 and 60-150 ms at 1080x1920 (heavy CSS such as `backdrop-filter` and big shadows is the slow end), and a phone is slower; keep boxes as small as the graphic needs and reuse the same markup string (identical markup and size share their pictures, so two layers of the same page cost the same as one).

## Effects

`{ name, ...params }`. Unknown names are ignored.

| name | params |
|---|---|
| `blur` | `radius` px |
| `motionBlur` | `radius` px, `angle` degrees |
| `zoomBlur` | `amount` px, `x`, `y` centre in canvas px (default centre) |
| `brightness` | `amount` −1…1 |
| `contrast` | `amount` 0…4, 1 = unchanged |
| `saturation` | `amount` 0…4, 1 = unchanged |
| `exposure` | `amount` in stops |
| `hue` | `angle` degrees |
| `invert`, `sepia` (`amount` 0…1), `grayscale` (`amount` 0…1) | |
| `vignette` | `amount` 0…2, `radius` 0…2 |
| `pixellate` | `radius` = block size px |
| `sharpen` | `amount` 0…2 |
| `glow` | `radius` px, `amount` 0…1 |
| `grain` | `amount` 0…1, `seed` |
| `rgbSplit` | `amount` px, `angle` degrees |
| `tint` | `color`, `amount` 0…1 |
| `colorMatrix` | `matrix`: 20 numbers, rows R G B A, each `[r, g, b, a, bias]` |
| `dropShadow` | `color` (default `rgba(0,0,0,0.5)`), `radius` px blur (default 10), `x`, `y` offset px (default 0, 8); a shadow of the node's alpha drawn under it |
| `wave` | `amount` px (default 10), `wavelength` px (default 120), `angle` degrees the wave travels along (0 = across, the pixels move up and down), `phase` degrees (animate it to make the wave travel) |
| `twirl` | `x`, `y` centre (default canvas centre), `radius` px, `angle` degrees (default 90, positive = clockwise) |
| `bulge` | `x`, `y` centre, `radius` px, `amount` −1…1 (default 0.5; negative pinches in) |
| `displace` | `amount` px (default 20), `scale` px = size of the wobbles (default 120), `seed`: smooth noise displacement for liquid / heat looks; change `seed` per frame to animate |
| `glitch` | `amount` 0…1 (slice shift and colour split), `slices` (default 10, max 64), `seed`: bands of the picture slide sideways, then the colour channels split. The same `seed` gives the same picture; change `seed` per frame for flicker. |
| `scanlines` | `amount` 0…1 (default 0.35), `spacing` px between lines (default 4) |
| `posterize` | `levels` per channel (default 6, 2…256) |
| `threshold` | `amount` 0…1 (default 0.5): brighter than it is white, else black |
| `halftone` | `radius` px of a dot cell (default 4), `angle` degrees: colour dot screen |
| `duotone` | `dark`, `light` colours (default black, white): the picture's brightness mapped between them |
| `mirror` | `axis`: `"x"` mirrors the left side onto the right, `"y"` the top onto the bottom; `x` / `y` (px) move the mirror line (default centre) |
| `edges` | `amount` 0…10 (default 1): outlines on black |

## Helpers (globals)

| Helper | Meaning |
|---|---|
| `interpolate(value, [in0, in1, …], [out0, out1, …], { easing, extrapolateLeft, extrapolateRight })` | piecewise-linear map; extrapolation `"clamp"` (default) or `"extend"`; `easing` applies inside each segment |
| `Easing` | `linear, inQuad, outQuad, inOutQuad, inCubic, outCubic, inOutCubic, inQuart, outQuart, inOutQuart, inExpo, outExpo, inOutExpo, inBack, outBack, inOutBack, outElastic, outBounce`, and `Easing.bezier(x1, y1, x2, y2)` |
| `spring({ frame, fps, from = 0, to = 1, stiffness = 100, damping = 10, mass = 1, delay = 0 })` | physical spring value at this frame |
| `clamp(v, lo, hi)`, `lerp(a, b, t)`, `mix(colorA, colorB, t)` | `mix` returns a colour string |
| `random(seed)` | stable 0…1 for a number or string seed |
| `noise(x, y = 0)` | smooth value noise, −1…1 |
| `sequence(frame, [{ durationInFrames, render(localFrame, index) }, …])` | returns the output of the segment that contains `frame` (or `null` past the end) |
| `series(frame, items, overlap, render(a, b, progress, ia, ib, local))` | helper for transitions: segments are laid end to end; `render` gets the current item `a` and, inside the last `overlap` frames of its segment, the next item `b` with `progress` 0…1 (`b` and `ib` are `null` outside a transition, `progress` is 0); each item is `{ durationInFrames, ... }`; returns what `render` returned (or `null` past the end). Details below. |
| `secondsToFrames(s, fps)`, `framesToSeconds(f, fps)` | |
| `line(x1, y1, x2, y2, props)` | a `path` node: a straight line (use `stroke`) |
| `polyline(points, props)`, `polygon(points, props)` | a `path` through `points` (`[[x, y], …]` or `[{ x, y }, …]`); `polygon` closes it |
| `star(cx, cy, points, outerR, innerR, props)` | a star with `points` tips, the first one straight up; `innerR` is the notch radius |
| `arc(cx, cy, r, startDeg, endDeg, props)` | an open arc for strokes; degrees clockwise on screen from 3 o'clock (90 = down); `endDeg < startDeg` runs the other way; at most one turn |
| `heart(cx, cy, size, props)` | a heart `size` px wide centred on `cx, cy` |
| `smoothPath(points, props, closed)` | a smooth curve through the points (Catmull-Rom as cubic Béziers): swooshes, organic shapes, hand-drawn lines; `closed` joins the end to the start |
| `wobble(points, amount, seed)` | the points as `[[x, y], …]`, each moved by up to `amount` px in x and y, the same for the same `seed`; feed it to `smoothPath` / `polyline` for a hand-drawn look |
| `layoutText(string, props)` | per-character positions, see "Per-letter text" |

### `series`: `local` and `progress`

`local` is `{ frame, frameB, start }`:

- `local.frame` = frames since `a`'s segment began (0 on its first frame).
- `local.start` = the timeline frame where `a`'s segment began.
- `local.frameB` = `frame - (start + a.durationInFrames)`. It is `null` when there is no `b`. During a transition it is **negative**: it is `-overlap` on the first frame of the transition and counts up to `-1` on the last. It is 0 on the first frame of `b`'s own segment, but by then `b` has become `a` and `local.frame` is 0, so `frameB` itself never reads 0 inside a transition. In short, `frameB` is "b's own frame number" with `b`'s segment starting at 0.
- `progress = (frame - (start + duration - overlap)) / overlap`: 0 on the first transition frame and **never reaches exactly 1** (the last transition frame is `(overlap - 1) / overlap`); the frame after it is the next segment with `progress` 0 and no `b`. The overlap is capped at the segment's length.

Using it for the incoming clip's video time, so that `b` is at its in-point `b.from` on the first frame of its own segment (this reads footage from *before* `b.from` during the lead-in, so the file needs that much material; clamp with `Math.max(0, ...)` if it does not):

```js
const tB = b.from + local.frameB / ctx.fps;                // frameB is negative: b is "rolling in"
layers.push(video(b.src, { time: Math.max(0, tB), opacity: progress }));
```

## Errors

A script error reports the message and the 1-based line in the author's file, as `message (line N)`. Every error is a `SprocketError` with a `kind` (`script`, `timeout`, `asset`, `render`, `export`, `cancelled`); a frame error starts with `frame N:`.

- `throw new Error("...")` gives a line. A thrown string, number or object (`throw "oops"`) gives **no** line: JavaScript does not record one, so the message says so and asks for `throw new Error`.
- A timeout names the phase and the frame (`timeout while rendering frame 20: render() ran longer than the 250 ms limit for one frame`, `timeout while loading the script: ... 2 s load limit`) and has no line, because a script that was stopped cannot say where it was. Look for a loop with no exit.
- Config and tree problems carry the path or field, see Config and Validation above.

## Command line

`sprocket-render <script.js> [--asset id=path ...] --out out.mp4` (also `--still N`, `--sheet N`, `--check`). `--check` evaluates every frame and lists the config, node counts, the asset ids used with their kinds, and the cut-out masks the script needs (`mask needed: clip c1, kind person, source time 0.75-3.21 s`); with `--asset` it also checks that those files are usable. For `html()` layers `--check` also lists the distinct pages (size, markup size, how many page times and pictures they need). `--strict` makes any warning (unreadable or missing asset) exit with status 2. `--verbose` prints `console.log` output to stderr. Exit codes: 0 ok, 1 error, 2 warnings under `--strict`, 130 after SIGINT, 143 after SIGTERM; an interrupted export removes its partial file and temp file.
