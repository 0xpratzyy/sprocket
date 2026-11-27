// Size/rate test 720x1280 @25: cover video, moving bar, border, frame counter, corner marks.
const W = 720, H = 1280;
composition({ width: W, height: H, fps: 25, durationInFrames: 50, audio: [{ src: "tone", volume: 0.5, fadeOut: 0.2 }] }, function (frame, ctx) {
  const m = Math.min(W, H) / 20;
  return [
    video("c1", { time: frame / ctx.fps }),
    rect(0, 0, W, H, { color: "transparent", stroke: "#ff0000", strokeWidth: m / 2 }),
    rect(m, m, m * 2, m * 2, { color: "#00ff00" }), rect(W - m * 3, m, m * 2, m * 2, { color: "#0000ff" }),
    rect(m, H - m * 3, m * 2, m * 2, { color: "#ffff00" }), rect(W - m * 3, H - m * 3, m * 2, m * 2, { color: "#ff00ff" }),
    rect((W - m * 2) * frame / (ctx.durationInFrames - 1), H / 2, m * 2, m * 2, { color: "#fff" }),
    text(W + "x" + H + " @" + ctx.fps + "  f" + frame, { y: H * 0.3, size: Math.round(W / 14), weight: 800, color: "#fff", stroke: "#000", strokeWidth: m / 4 }),
  ];
});
