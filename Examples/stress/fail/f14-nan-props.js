composition({ width: 540, height: 960, fps: 30, durationInFrames: 20 }, function (frame) {
  return [solid("#224"),
    rect(10, 10, NaN, 100, { color: "#f00" }), rect(10, 120, Infinity, 100, { color: "#0f0" }), rect(10, 230, -100, -100, { color: "#00f" }),
    ellipse(NaN, NaN, 50, 50, { color: "#ff0" }), rect(0, 400, 100, 100, { color: "#fff", opacity: NaN }), rect(0, 400, 100, 100, { color: "#f0f", opacity: -5 }), rect(0, 500, 100, 100, { color: "#0ff", opacity: 99 }),
    group([rect(0, 600, 100, 100, { color: "#fa0" })], { transform: { scale: NaN, rotate: Infinity, translateX: -Infinity } }),
    text("nan size", { y: 700, size: NaN, color: "#fff" }), text("neg size", { y: 750, size: -50, color: "#fff" }), text("inf width", { y: 800, width: Infinity, size: 30, color: "#fff" }),
    rect(0, 850, 100, 100, { color: "#abc", radius: NaN, strokeWidth: -3, stroke: "#fff" }),
    rect(0, 850, 100, 100, { color: "notacolor" }), rect(0, 850, 50, 50, { color: "#xyz" }),
    group([rect(0, 0, 50, 50, { color: "#f00" })], { effects: [{ name: "blur", radius: NaN }, { name: "contrast", amount: Infinity }, { name: "hue", angle: NaN }] }),
    gradient([], {}), gradient([{ at: 0, color: "#f00" }], { kind: "radial" }), gradient([{ at: NaN, color: "#f00" }, { at: 1, color: "#00f" }], { from: { x: 0, y: 0 }, to: { x: 0, y: 0 } }),
    path("M 0 0 L NaN 5 Z garbage", { color: "#fff" }), path("", {}), path("M 10 10 L 100 100", { stroke: "#fff", strokeWidth: 1e9 }),
    video("c1", { time: NaN }), video("c1", { time: Infinity }), video("c1", { time: -1e12 }),
    colorMatrixTest(),
  ];
  function colorMatrixTest() { return group([rect(0, 0, 100, 100, { color: "#fff" })], { effects: [{ name: "colorMatrix", matrix: [1, 2, 3] }, { name: "colorMatrix" }, { name: "tint" }] }); }
});
