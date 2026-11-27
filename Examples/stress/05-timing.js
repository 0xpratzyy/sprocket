// Video timing: 10 tiles 540x384, each labelled with the source time it asks for.
const TW = 540, TH = 384;
function tile(i, label, src, time, extra) {
  const x = (i % 2) * TW, y = Math.floor(i / 2) * TH;
  return [
    video(src, Object.assign({ time: time, x: x, y: y, width: TW, height: TH, clip: { x: x, y: y, width: TW, height: TH, radius: 0 } }, extra || {})),
    rect(x, y, TW, 44, { color: "#000000", opacity: 0.65 }),
    text(label + "  t=" + time.toFixed(2), { x: x, y: y + 6, width: TW, size: 28, color: "#fff" }),
  ];
}
composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 180 }, function (frame, ctx) {
  const t = frame / 30;
  // speed ramp: speed 1 -> 3 over 0..6s, integrated: time = t + 0.5*(2/6)*t^2 ... speed(t)=1+t/3 -> time = t + t^2/6
  const ramp = t + t * t / 6;
  const jc = Math.floor(frame / 3) % 5;
  return [
    solid("#202020"),
    tile(0, "1 normal", "c1", t),
    tile(1, "2x", "c1", t * 2),
    tile(2, "0.5x slow-mo", "c1", t * 0.5),
    tile(3, "reverse", "c1", 5.9 - t),
    tile(4, "freeze @2s", "c1", 2),
    tile(5, "ramp 1x->3x", "c1", ramp),
    // same clip at two times in one frame
    [video("c2", { time: t, x: 0, y: 3 * TH, width: TW / 2, height: TH, fit: "cover", clip: { x: 0, y: 3 * TH, width: TW / 2, height: TH } }),
     video("c2", { time: 3 + t, x: TW / 2, y: 3 * TH, width: TW / 2, height: TH, fit: "cover", clip: { x: TW / 2, y: 3 * TH, width: TW / 2, height: TH } }),
     rect(0, 3 * TH, TW, 44, { color: "#000", opacity: 0.65 }), text("7 same clip t and t+3", { x: 0, y: 3 * TH + 6, width: TW, size: 26, color: "#fff" })],
    tile(7, "8 time past end (+5)", "c3", 5 + t),
    tile(8, "9 jump cut /3f x5 clips jc=" + jc, "c" + (1 + jc), 1 + t * 0.2),
    [rect(TW, 4 * TH, TW, TH, { color: "#222" }), text("frame " + frame, { x: TW, y: 4 * TH + 150, width: TW, size: 60, color: "#fff" })],
  ];
});
