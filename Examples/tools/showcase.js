// Showcase: most of the new drawing tools in one 4 s piece (1080x1920, 30 fps).
// A dusk gradient with a flat-vector skyline that draws itself on, a liquid swoosh, a shooting star, floating hearts,
// chrome type with tilted echoes, a glitch letter scramble that settles, a hand-drawn underline, then a scanline/duotone outro.
composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 120, background: "#0d0b1e" }, function (frame, ctx) {
  const W = ctx.width, H = ctx.height, t = frame / ctx.fps;
  const sky = { stops: [{ at: 0, color: "#1b1464" }, { at: 0.55, color: "#c2410c" }, { at: 1, color: "#fbbf24" }] };
  const chrome = { stops: [{ at: 0, color: "#ffffff" }, { at: 0.46, color: "#9aa3b8" }, { at: 0.5, color: "#262b3d" }, { at: 0.56, color: "#c3cadb" }, { at: 1, color: "#ffffff" }] };
  const draw = interpolate(frame, [0, 45], [0, 1], { easing: Easing.inOutCubic });
  const out = interpolate(frame, [100, 119], [0, 1], { easing: Easing.inCubic });

  // --- skyline: flat vector towers whose outlines draw on, then fill in
  const towers = [[60, 1320, 150, 380], [230, 1220, 120, 480], [370, 1380, 180, 320], [570, 1160, 130, 540], [720, 1300, 150, 400], [890, 1240, 130, 460]];
  const skyline = towers.map(function (tw, i) {
    const p = clamp(draw * 1.4 - i * 0.12, 0, 1), f = clamp((draw - 0.7) * 3 - i * 0.1, 0, 1);
    const grow = Easing.outCubic(clamp((frame - i * 3) / 24, 0, 1));
    const h = tw[3] * grow, y = 1700 - h;
    return [
      rect(tw[0], y, tw[2], h, { fill: { stops: [{ at: 0, color: mix("#2a2150", "#4c3a7a", i / 6) }, { at: 1, color: "#120d2b" }] } }),
      rect(tw[0], y, tw[2], h, { stroke: "#ffe9b0", strokeWidth: 4, lineJoin: "round", trim: { start: 0, end: p }, opacity: 1 - f * 0.7 }),
    ];
  });

  // --- liquid swoosh: a smooth curve with a travelling wave and a soft shadow
  const swoosh = smoothPath([[-60, 1500], [240, 1380], [520, 1470], [820, 1330], [1160, 1420]], { stroke: "#7dd3fc", strokeWidth: 26, lineCap: "round",
    trim: { start: clamp((frame - 10) / 70, 0, 1) * 0.0, end: clamp((frame - 6) / 40, 0, 1) }, opacity: 0.9 });
  const swooshLayer = group([swoosh], { effects: [{ name: "wave", amount: 14, wavelength: 260, angle: 0, phase: frame * 9 }, { name: "dropShadow", color: "rgba(0,0,0,0.5)", radius: 18, x: 0, y: 16 }] });

  // --- shooting star: a tapered streak with a star head, flying across
  const sp = clamp((frame - 20) / 40, 0, 1), sx = interpolate(sp, [0, 1], [1200, -100]), sy = interpolate(sp, [0, 1], [180, 700]);
  const shooting = group([
    line(sx + 340, sy - 140, sx, sy, { stroke: "#ffffff", strokeWidth: 6, lineCap: "round", opacity: 0.6 }),
    line(sx + 180, sy - 75, sx, sy, { stroke: "#ffffff", strokeWidth: 12, lineCap: "round" }),
    star(sx, sy, 4, 34, 10, { color: "#fff" }),
  ], { effects: [{ name: "glow", radius: 24, amount: 0.9 }], opacity: sp > 0 && sp < 1 ? 1 : 0 });

  // --- floating hearts
  const hearts = [0, 1, 2, 3, 4, 5].map(function (i) {
    const hx = 120 + i * 170 + Math.sin(t * 2 + i) * 30, hy = 1850 - ((frame * (4 + i % 3) + i * 140) % 1500), s = 70 + (i % 3) * 30;
    return heart(hx, hy, s, { fill: { stops: [{ at: 0, color: "#fda4af" }, { at: 1, color: "#e11d48" }] }, opacity: clamp(1 - hy / 1600, 0.25, 0.9) });
  });

  // --- chrome type with tilted echoes (perspective copies behind)
  const headline = "SPROCKET";
  const tp = Easing.outBack(clamp((frame - 14) / 26, 0, 1));
  const ttext = function (extra) { return text(headline, Object.assign({ x: 0, y: 330, width: W, size: 230, weight: 900, italic: true }, extra)); };
  const echoes = [4, 3, 2, 1].map(function (k) {
    return ttext({ stroke: "#ffffff", strokeWidth: 3, color: "#00000000", opacity: 0.16 * (5 - k) * tp,
      transform: { rotateX: 55, perspective: 900, translateY: k * 70 + 120, scale: 1 - k * 0.05, originX: W / 2, originY: 450 } });
  });
  const logo = group([
    ttext({ fill: chrome, stroke: "#1e1b4b", strokeWidth: 4, shadow: { color: "rgba(0,0,0,0.6)", blur: 24, x: 0, y: 14 }, opacity: tp }),
  ], { transform: { translateY: (1 - tp) * -160, scale: 0.6 + 0.4 * tp, originX: W / 2, originY: 450 } });

  // --- glitch letter scramble that settles into "NEW  CUT"
  const target = "COPY ANY REEL";
  const glyphs = layoutText(target, { x: 0, y: 640, width: W, size: 110, weight: 800, letterSpacing: 6 });
  const pool = "#%&*+=?/\\<>01";
  const letters = glyphs.map(function (g) {
    if (g.char === " ") return null;
    const settle = 40 + g.index * 3, live = frame < settle;
    const ch = live ? pool.charAt(Math.floor(random(frame * 31 + g.index) * pool.length)) : g.char;
    return text(ch, { x: g.x, y: g.y, width: 300, align: "left", size: 110, weight: 800, letterSpacing: 6,
      color: live ? "#7dd3fc" : "#ffffff", opacity: clamp((frame - 28) / 6, 0, 1),
      transform: { translateX: live ? (random(frame + g.index * 7) - 0.5) * 16 : 0 } });
  });
  const glitching = frame >= 28 && frame < 78 ? 0.5 : (frame >= 78 && frame < 84 ? 0.25 : 0);

  // --- hand-drawn underline
  const under = smoothPath(wobble([[130, 830], [400, 842], [700, 826], [950, 838]], 6, 11), { stroke: "#fbbf24", strokeWidth: 12, lineCap: "round",
    trim: { start: 0, end: clamp((frame - 70) / 22, 0, 1) } });

  const scene = group([
    rect(0, 0, W, H, { fill: sky }),
    group(hearts),
    skyline,
    swooshLayer,
    shooting,
    group(echoes),
    logo,
    group([group(letters, { effects: glitching ? [{ name: "glitch", amount: glitching, seed: frame, slices: 6 }] : [] }), under]),
  ], { effects: out > 0 ? [{ name: "scanlines", amount: 0.6 * out, spacing: 8 }, { name: "posterize", levels: Math.round(lerp(40, 5, out)) }] : [] });

  return [scene, rect(0, 0, W, H, { color: "#000", opacity: out * 0.55 })];
});
