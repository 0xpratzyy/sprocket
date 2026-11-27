// layoutText: each letter drawn as its own text node. The top block is the whole string, static; the bottom block is the
// same string drawn letter by letter with its own motion, and has settled into the same shape by the last frame.
composition({ width: 720, height: 960, fps: 30, durationInFrames: 60, background: "#101018" }, function (frame, ctx) {
  const P = { x: 40, width: 640, size: 64, weight: 800, letterSpacing: 2, align: "center", lineHeight: 1.1 };
  const s = "Hello Sprocket,\nper-letter motion wraps and aligns like text";
  const whole = text(s, Object.assign({}, P, { y: 40, color: "#8892a6" }));
  const P2 = Object.assign({}, P, { y: 480 });
  const letters = layoutText(s, P2).map(function (g) {
    const p = clamp((frame - g.index * 0.5) / 14, 0, 1);
    const e = Easing.outBack(p);
    return text(g.char, Object.assign({}, P2, {
      x: g.x, y: g.y + (1 - e) * 140, width: 400, align: "left",
      color: mix("#ff5a5f", "#ffd23f", g.index / 56), opacity: p > 0 ? 1 : 0,
      transform: { scale: 0.3 + 0.7 * e, originX: g.x + g.width / 2, originY: g.y + g.height / 2, rotate: (1 - e) * 60 },
    }));
  });
  return [whole, letters];
});
