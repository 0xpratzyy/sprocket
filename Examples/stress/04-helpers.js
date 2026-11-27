// Helpers visualised: each row is a bar/dot whose x is a helper output. Labels on the left.
const names = ["inQuad","outQuad","inOutQuad","inCubic","outCubic","inOutCubic","inQuart","outQuart","inOutQuart","inExpo","outExpo","inOutExpo","inBack","outBack","inOutBack","outElastic","outBounce","linear"];
composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 90 }, function (frame, ctx) {
  const o = [solid("#111")];
  let y = 20;
  const dot = (label, v, color) => { o.push(text(label, { x: 10, y: y, width: 300, size: 24, align: "left", color: "#bbb" })); o.push(rect(320, y + 12, 720, 2, { color: "#333" })); o.push(ellipse(320 + 720 * v - 10, y + 3, 20, 20, { color: color || "#ffca28" })); y += 32; };
  names.forEach(n => dot("Easing." + n, interpolate(frame, [0, 89], [0, 1], { easing: Easing[n] })));
  dot("bezier(.2,.8,.2,1)", interpolate(frame, [0, 89], [0, 1], { easing: Easing.bezier(0.2, 0.8, 0.2, 1) }));
  dot("multi-seg [0,30,60,89]->[0,1,.2,.8]", interpolate(frame, [0, 30, 60, 89], [0, 1, 0.2, 0.8]), "#4fc3f7");
  // extrapolation: input frame - 45 over [20,40]
  const f2 = frame - 30;
  dot("clamp left/right", interpolate(f2, [20, 40], [0.2, 0.8]), "#81c784");
  dot("extend left/right (x0.01)", 0.5 + 0.01 * (interpolate(f2, [20, 40], [0.2, 0.8], { extrapolateLeft: "extend", extrapolateRight: "extend" }) - 0.5) * 100 / 100, "#e57373");
  dot("extend left only", 0.5 + 0.1 * (interpolate(f2, [20, 40], [0.2, 0.8], { extrapolateLeft: "extend" }) - 0.5), "#ba68c8");
  dot("extend right only", 0.5 + 0.1 * (interpolate(f2, [20, 40], [0.2, 0.8], { extrapolateRight: "extend" }) - 0.5), "#f06292");
  dot("spring default", spring({ frame, fps: 30 }) / 1.5 );
  dot("spring stiff 300 damp 8", spring({ frame, fps: 30, stiffness: 300, damping: 8 }) / 1.5, "#4dd0e1");
  dot("spring delay 30 from 0 to 1", spring({ frame, fps: 30, delay: 30, damping: 20 }) / 1.5, "#aed581");
  dot("spring mass 3", spring({ frame, fps: 30, mass: 3 }) / 1.5, "#ff8a65");
  dot("noise(frame/20)", 0.5 + 0.5 * noise(frame / 20), "#fff176");
  dot("noise(x,y) 2D", 0.5 + 0.5 * noise(frame / 20, 7.3), "#fff176");
  dot("random(frame)", random(frame), "#90a4ae");
  dot("random('abc') constant", random("abc"), "#90a4ae");
  dot("Math.random() per-frame", Math.random(), "#78909c");
  // mix
  o.push(rect(10, y, 520, 40, { color: mix("#ff0000", "#0000ff", frame / 89) })); o.push(text("mix red->blue", { x: 10, y: y + 5, width: 520, size: 26, color: "#fff" }));
  o.push(rect(550, y, 480, 40, { color: mix("rgb(255,255,0)", "hsl(200,100%,50%)", frame / 89) })); y += 60;
  // sequence + series
  const seq = sequence(frame, [{ durationInFrames: 30, render: (lf, i) => text("seg " + i + " lf " + lf, { y: y, size: 40, color: "#f66" }) }, { durationInFrames: 30, render: (lf, i) => text("seg " + i + " lf " + lf, { y: y, size: 40, color: "#6f6" }) }]);
  o.push(seq); o.push(text("seq past end -> null: " + (sequence(100, [{ durationInFrames: 30, render: () => 1 }]) === null), { y: y + 50, size: 28, color: "#fff" })); y += 110;
  const items = [{ durationInFrames: 40 }, { durationInFrames: 40 }, { durationInFrames: 40 }];
  const s = series(frame, items, 10, (a, b, p, ia, ib, local) => text(`series ia${ia} ib${ib} p${p.toFixed(2)} lf${local.frame} fB${local.frameB} st${local.start}`, { y: y, size: 30, color: "#fc6" }));
  o.push(s);
  o.push(text("clamp(15,0,10)=" + clamp(15, 0, 10) + " lerp(0,10,.3)=" + lerp(0, 10, 0.3) + " s2f=" + secondsToFrames(1.5, 30) + " f2s=" + framesToSeconds(45, 30), { y: y + 60, size: 28, color: "#fff" }));
  return o;
});
