// Scenes swap into each other tile by tile on a grid, like a mosaic reveal.
const W = 1080, H = 1920, FPS = 30, TILE = 120, COLS = W / TILE, ROWS = H / TILE;
const scenes = [
  { src: "c1", from: 1.0, durationInFrames: 60 },
  { src: "c2", from: 0.5, durationInFrames: 54 },
  { src: "c3", from: 2.0, durationInFrames: 54 },
  { src: "c4", from: 0.0, durationInFrames: 54 },
  { src: "c5", from: 1.0, durationInFrames: 78 },
];
const OVERLAP = 24;
const total = scenes.reduce((n, s) => n + s.durationInFrames, 0);

function shot(s, localFrame) { return video(s.src, { time: s.from + localFrame / FPS }); }

// Tiles of the next scene that have already flipped at this progress. Each tile has its own moment.
function tiles(progress, seed) {
  const out = [];
  for (let r = 0; r < ROWS; r++) for (let c = 0; c < COLS; c++) {
    const at = random(seed + ":" + r + ":" + c) * 0.85;
    if (progress >= at) out.push(rect(c * TILE, r * TILE, TILE, TILE, { color: "#fff" }));
  }
  return out;
}

function gridLines(opacity) {
  const lines = [];
  for (let c = 1; c < COLS; c++) lines.push(rect(c * TILE - 1, 0, 2, H, { color: "#ffffff" }));
  for (let r = 1; r < ROWS; r++) lines.push(rect(0, r * TILE - 1, W, 2, { color: "#ffffff" }));
  return group(lines, { opacity });
}

composition({ width: W, height: H, fps: FPS, durationInFrames: total, audio: [{ src: "c1", volume: 0.8, fadeOut: 0.4 }] },
  function (frame) {
    return series(frame, scenes, OVERLAP, function (a, b, progress, ia, ib, local) {
      const layers = [shot(a, local.frame)];
      if (b) {
        layers.push(group([shot(b, local.frameB)], { mask: tiles(progress, "t" + ia) }));
        layers.push(gridLines(0.35 * Math.sin(Math.PI * progress)));
      }
      return layers;
    });
  });
