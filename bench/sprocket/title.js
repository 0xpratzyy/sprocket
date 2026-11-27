const clamp = (x) => Math.max(0, Math.min(1, x));
const easeOut = (p) => 1 - Math.pow(1 - p, 3);
composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 300 }, function (f, ctx) {
  const t = f / 30;
  const p1 = easeOut(clamp((f - 10) / 30)), p2 = clamp((f - 30) / 30);
  const colors = ["#f43f5e", "#22d3ee", "#facc15"];
  return [
    gradient([{ at: 0, color: "#0b1020" }, { at: 1, color: "#1e1b4b" }]),
    text("LISBON", { y: 760, size: 160, weight: 800, font: "Helvetica", color: "#fff", opacity: p1, transform: { translateY: 80 * (1 - p1) } }),
    text("a weekend in light", { y: 960, size: 56, weight: 400, font: "Helvetica", color: "#c7d2fe", opacity: p2 }),
    colors.map((c, i) => ellipse(90 + i * 320 + 60 * Math.sin(t * 1.5 + i), 1300 + 40 * Math.cos(t * 2 + i), 200, 200, { color: c })),
    rect(0, 1880, Math.max(0.01, (1080 * f) / 299), 16, { color: "#fff" }),
  ];
});
