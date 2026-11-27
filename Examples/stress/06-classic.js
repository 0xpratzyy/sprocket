// Classic edits as code, 12 segments of 30 frames each (360 frames @30fps, 1080x1920) with a label per segment.
const W = 1080, H = 1920;
const seg = [];
function lab(s) { return text(s, { y: 60, size: 56, weight: 800, color: "#fff", stroke: "#000", strokeWidth: 6 }); }
function v(c, t, p) { return video("c" + c, Object.assign({ time: t }, p || {})); }
composition({ width: W, height: H, fps: 30, durationInFrames: 12 * 30 + 60 }, function (frame, ctx) {
  const i = Math.floor(frame / 30), f = frame % 30, p = f / 29, t = f / 30;
  switch (i) {
  case 0: // crossfade
    return [v(1, t), v(2, t, { opacity: p }), lab("crossfade")];
  case 1: // wipe left->right
    return [v(1, t), group([v(2, t)], { clip: { x: 0, y: 0, width: W * p, height: H, radius: 0 } }), rect(W * p - 4, 0, 8, H, { color: "#fff" }), lab("wipe")];
  case 2: // circle reveal
    return [v(1, t), group([v(2, t)], { mask: [ellipse(W / 2 - 1300 * p, H / 2 - 1300 * p, 2600 * p, 2600 * p, { color: "#fff" })] }), lab("circle reveal")];
  case 3: { // zoom punch with motion blur
    const s = 1 + 0.6 * Easing.outExpo(p) ;
    return [v(3, t, { transform: { scale: s }, effects: [{ name: "motionBlur", radius: 60 * (1 - p), angle: 90 }, { name: "zoomBlur", amount: 80 * (1 - p) }] }), lab("zoom punch + motion blur")]; }
  case 4: { // whip pan: both slide with horizontal motion blur
    const x = W * Easing.inOutCubic(p), bl = 150 * Math.sin(Math.PI * p);
    return [group([v(1, t)], { transform: { translateX: -x }, effects: [{ name: "motionBlur", radius: bl, angle: 0 }] }), group([v(2, t)], { transform: { translateX: W - x }, effects: [{ name: "motionBlur", radius: bl, angle: 0 }] }), lab("whip pan")]; }
  case 5: // split screen 2
    return [v(1, t, { y: 0, height: H / 2, clip: { x: 0, y: 0, width: W, height: H / 2 } }), v(2, t, { y: H / 2, height: H / 2, clip: { x: 0, y: H / 2, width: W, height: H / 2 } }), rect(0, H / 2 - 3, W, 6, { color: "#fff" }), lab("split 2-up")];
  case 6: // split 3
    return [0, 1, 2].map(k => v(4 + k, t, { y: k * H / 3, height: H / 3, clip: { x: 0, y: k * H / 3, width: W, height: H / 3 } })).concat([rect(0, H / 3 - 2, W, 4, { color: "#fff" }), rect(0, 2 * H / 3 - 2, W, 4, { color: "#fff" }), lab("split 3-up")]);
  case 7: { // PiP rounded + shadow
    const px = 600, py = 1250, pw = 400, ph = 300;
    return [v(1, t), rect(px, py, pw, ph, { color: "#000000", radius: 40, opacity: 0.5, effects: [{ name: "blur", radius: 25 }], transform: { translateY: 20, translateX: 10, originX: px, originY: py, } }), v(2, t, { x: px, y: py, width: pw, height: ph, clip: { x: px, y: py, width: pw, height: ph, radius: 40 } }), rect(px, py, pw, ph, { color: "transparent", stroke: "#fff", strokeWidth: 6, radius: 40 }), lab("picture-in-picture")]; }
  case 8: { // Ken Burns
    const s = 1 + 0.4 * p;
    return [v(5, t, { transform: { scale: s, translateX: -80 * p, translateY: -40 * p } }), lab("Ken Burns")]; }
  case 9: { // glitch
    const j = random(frame) > 0.4;
    return [v(6, t, { transform: { translateX: j ? (random(frame + 1) - 0.5) * 80 : 0 }, effects: [{ name: "rgbSplit", amount: j ? 30 + 30 * random(frame + 2) : 4, angle: 0 }, { name: "grain", amount: 0.3, seed: frame }] }),
            j ? group([v(6, t + 0.5, { y: 500, height: 200, clip: { x: 0, y: 500, width: W, height: 200 } })], { transform: { translateX: 60 } }) : null, lab("glitch")]; }
  case 10: { // kinetic captions
    const words = ["THIS", "IS", "KINETIC", "TYPE", "POPPING"];
    const wi = Math.min(4, Math.floor(f / 6)), lf = f - wi * 6;
    const sc = spring({ frame: lf, fps: 30, from: 0.3, to: 1, stiffness: 300, damping: 12 });
    return [v(7, t), rect(0, 0, W, H, { color: "#000", opacity: 0.35 }), text(words[wi], { y: 850, size: 200, weight: 900, color: wi % 2 ? "#ffeb3b" : "#fff", stroke: "#000", strokeWidth: 10, transform: { scale: sc, originX: 540, originY: 950 } }), lab("kinetic captions")]; }
  case 11: { // lower third spring
    const x = spring({ frame: f, fps: 30, from: -700, to: 60, stiffness: 120, damping: 14 });
    return [v(8, t), group([rect(0, 1500, 700, 160, { color: "#e53935", radius: 20 }), text("Ada Lovelace", { x: 30, y: 1520, width: 640, size: 56, weight: 800, color: "#fff", align: "left" }), text("Founder, Sprocket", { x: 30, y: 1595, width: 640, size: 34, color: "#ffe", align: "left" })], { transform: { translateX: x - 60 } }), lab("lower third spring")]; }
  default: // past the last segment: black
    return [solid("#003300"), text("END frame " + frame, { y: 900, size: 80, color: "#fff" })];
  }
});
