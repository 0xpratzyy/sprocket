// Props: opacity, transform, every blend mode, mask alpha/luma/video-luma, clip radius, nested groups.
const BL = ["normal","multiply","screen","overlay","add","darken","lighten","softLight","hardLight","difference"];
composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 90 }, function (frame, ctx) {
  const t = frame / 90;
  const out = [video("c2", { time: t * 3 })]; // background
  // blend modes: 10 cells of 200x200 in 2 cols x5 rows (left half), each a gradient overlay on the video
  BL.forEach((b, i) => {
    const x = 20 + (i % 2) * 260, y = 20 + Math.floor(i / 2) * 230;
    out.push(rect(x, y, 240, 210, { color: "#ff9800", blend: b }));
    out.push(text(b, { x: x, y: y + 80, width: 240, size: 34, color: "#fff", stroke: "#000", strokeWidth: 3 }));
  });
  // opacity ramp: 3 white squares opacity .25 .5 1 
  out.push(rect(560, 20, 120, 120, { color: "#fff", opacity: 0.25 }), rect(700, 20, 120, 120, { color: "#fff", opacity: 0.5 }), rect(840, 20, 120, 120, { color: "#fff", opacity: 1 }));
  // transforms: rotate about custom origin, scale, translate
  out.push(group([rect(0, 0, 120, 120, { color: "#e53935" }), text("A", { x: 0, y: 20, width: 120, size: 80, color: "#fff" })], { transform: { originX: 60, originY: 60, rotate: 360 * t, translateX: 600, translateY: 200 } }));
  out.push(group([rect(0, 0, 120, 120, { color: "#43a047" }), text("B", { x: 0, y: 20, width: 120, size: 80, color: "#fff" })], { transform: { originX: 0, originY: 0, rotate: 45, scaleX: 1.5, scaleY: 0.7, translateX: 780, translateY: 200 } }));
  out.push(group([rect(0, 0, 120, 120, { color: "#1e88e5" }), text("C", { x: 0, y: 20, width: 120, size: 80, color: "#fff" })], { transform: { originX: 60, originY: 60, scale: 1 + t, translateX: 900, translateY: 300 } }));
  // masks
  const alphaMask = [ellipse(40, 1200, 400, 400, { color: "#fff" })];
  out.push(group([video("c3", { time: 1 + t * 2, x: 40, y: 1200, width: 400, height: 400 })], { mask: alphaMask }));
  const gradMask = gradient([{ at: 0, color: "#fff" }, { at: 1, color: "#000" }], { kind: "linear", from: { x: 460, y: 0 }, to: { x: 860, y: 0 }, x: 460, y: 1200, width: 400, height: 400 });
  out.push(group([video("c4", { time: 1 + t * 2, x: 460, y: 1200, width: 400, height: 400 })], { mask: [gradMask], maskMode: "luma" }));
  out.push(text("alpha mask / luma grad mask", { y: 1620, size: 36, color: "#fff", stroke: "#000", strokeWidth: 3 }));
  // video as luma mask: red solid revealed where c5's brightness is
  out.push(group([rect(0, 1680, 1080, 240, { color: "#00e5ff" })], { mask: [video("c5", { time: t * 3, x: 0, y: 1680, width: 1080, height: 240 })], maskMode: "luma" }));
  // clip with radius
  out.push(video("c6", { time: t * 3, clip: { x: 880, y: 1200, width: 180, height: 300, radius: 60 } }));
  // nested groups three deep, each rotating 10 deg and 0.9 opacity
  const inner = group([rect(0, 0, 100, 100, { color: "#ffeb3b" })], { transform: { rotate: 20, translateX: 40, originX: 0, originY: 0 }, opacity: 0.9 });
  const mid = group([inner, rect(0, 0, 60, 60, { color: "#f44336" })], { transform: { rotate: 15 + 30 * t, translateX: 20, translateY: 20, originX: 0, originY: 0 }, opacity: 0.9 });
  const outer = group([mid, rect(0, 0, 40, 40, { color: "#4caf50" })], { transform: { translateX: 600, translateY: 520, scale: 1.5, originX: 0, originY: 0 }, opacity: 0.9 });
  out.push(outer);
  return out;
});
