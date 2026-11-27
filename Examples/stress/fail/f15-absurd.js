const long = "A".repeat(10000);
composition({ width: 540, height: 960, fps: 30, durationInFrames: 12 }, function (frame) {
  return [video("c1", { time: frame / 30, effects: [{ name: "blur", radius: 1e9 }] }),
    group([rect(0, 0, 100, 100, { color: "#f00" })], { transform: { scale: 1e6 } }),
    group([rect(0, 0, 100, 100, { color: "#0f0" })], { transform: { scale: -1e6, rotate: 1e9 } }),
    video("c2", { time: frame / 30, effects: [{ name: "pixellate", radius: 1e9 }, { name: "motionBlur", radius: 1e9, angle: 1e9 }, { name: "zoomBlur", amount: 1e9 }, { name: "glow", radius: 1e9, amount: 1e9 }, { name: "sharpen", amount: 1e9 }, { name: "grain", amount: 1e9 }, { name: "rgbSplit", amount: 1e9 }, { name: "exposure", amount: 1e9 }, { name: "vignette", amount: 1e9, radius: 1e9 }] }),
    text(long, { y: 100, size: 40, color: "#fff" }),
    text(long, { y: 100, size: 1e7, color: "#fff" }),
    text("tiny", { y: 100, size: 1e-9, color: "#fff" }),
    text("🔥".repeat(3000), { y: 100, size: 30, width: 500, color: "#fff", stroke: "#000", strokeWidth: 1e6, shadow: { color: "#000", blur: 1e9, x: 1e9, y: 1e9 } }),
    rect(0, 0, 1e9, 1e9, { color: "#00f", radius: 1e9, stroke: "#fff", strokeWidth: 1e9 }),
    ellipse(-1e9, -1e9, 2e9, 2e9, { color: "#ff0" }),
    path("M 0 0 L 1e30 1e30 L -1e30 5 Z", { color: "#fff", stroke: "#f0f", strokeWidth: 20 }),
  ];
});
