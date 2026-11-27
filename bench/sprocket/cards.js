composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 300, background: "#0a0a0a" }, function (f, ctx) {
  const t = f / 30;
  const out = [ellipse(190 + 200 * Math.sin(t * 0.8), 600 + 300 * Math.cos(t * 0.6), 700, 700, { color: "#7c3aed", effects: [{ name: "blur", radius: 80 }] })];
  for (let i = 0; i < 48; i++) {
    const col = i % 6, row = Math.floor(i / 6);
    const x = 30 + col * 170, y = 60 + row * 225, h = i * 7.5;
    out.push(group([
      rect(x, y, 150, 200, { radius: 24, fill: { kind: "linear", stops: [{ at: 0, color: `hsl(${h}, 80%, 60%)` }, { at: 1, color: `hsl(${h + 40}, 80%, 40%)` }], from: { x, y }, to: { x: x + 150, y: y + 200 } } }),
      text(String(i + 1), { x, y: y + 100 - 29, width: 150, size: 48, weight: 700, font: "Helvetica", color: "#fff" }),
    ], {
      transform: { rotate: 12 * Math.sin(t * 2 + i * 0.4), scale: 0.92 + 0.08 * Math.sin(t * 3 + i * 0.7), originX: x + 75, originY: y + 100 },
      effects: [{ name: "dropShadow", color: "rgba(0,0,0,0.5)", radius: 40, x: 0, y: 20 }],
    }));
  }
  return out;
});
