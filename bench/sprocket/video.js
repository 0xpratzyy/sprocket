const clamp = (x) => Math.max(0, Math.min(1, x));
const easeOut = (p) => 1 - Math.pow(1 - p, 3);
const WORDS = "this is a quick test of captions on top of moving video footage".split(" ");
composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 300, audio: [{ src: "clip" }] }, function (f, ctx) {
  const t = f / 30;
  const w = Math.min(WORDS.length - 1, Math.floor(t / 0.75));
  const pop = easeOut(clamp((t - w * 0.75) / 0.2));
  return [
    video("clip", { time: t }),
    rect(0, 1500, 1080, 260, { color: "rgba(0,0,0,0.55)" }),
    text(WORDS[w], { y: 1560, size: 120, weight: 800, font: "Helvetica", color: "#facc15", opacity: pop, transform: { scale: 0.6 + 0.4 * pop, originX: 540, originY: 1632 } }),
  ];
});
