// Gradient fills (rect, ellipse, path, text) and the shape helpers.
composition({ width: 720, height: 960, fps: 30, durationInFrames: 30, background: "#14141c" }, function (frame, ctx) {
  const chrome = { kind: "linear", stops: [
    { at: 0, color: "#ffffff" }, { at: 0.45, color: "#8a93a6" }, { at: 0.5, color: "#1c2030" }, { at: 0.55, color: "#aeb6c8" }, { at: 1, color: "#ffffff" }] };
  const gold = { stops: [{ at: 0, color: "#fff3a0" }, { at: 0.5, color: "#e0a526" }, { at: 1, color: "#7a4a07" }] };
  const sunset = { stops: [{ at: 0, color: "#ff5f6d" }, { at: 1, color: "#ffc371" }], from: { x: 40, y: 40 }, to: { x: 320, y: 300 } };
  const pts = [[60, 560], [140, 480], [220, 600], [300, 500], [380, 580]];
  return [
    rect(40, 40, 280, 260, { radius: 30, fill: sunset }),
    ellipse(360, 40, 300, 260, { fill: { kind: "radial", stops: [{ at: 0, color: "#fff" }, { at: 1, color: "#3a7bd5" }] } }),
    path("M60 460 L200 330 L340 460 Z", { fill: { stops: [{ at: 0, color: "#7f00ff" }, { at: 1, color: "#e100ff" }] }, stroke: "#fff", strokeWidth: 6, lineJoin: "round" }),
    text("CHROME", { x: 0, y: 330, width: 720, size: 150, weight: 900, fill: chrome }),
    text("GOLD", { x: 0, y: 470, width: 720, size: 120, weight: 800, italic: true, fill: gold, stroke: "#4a2c00", strokeWidth: 3 }),
    // helpers
    smoothPath(pts, { stroke: "#0cf", strokeWidth: 8, lineCap: "round" }),
    polyline(pts, { stroke: "#ffffff55", strokeWidth: 2 }),
    smoothPath(wobble([[60, 650], [360, 650], [660, 650]], 14, 7), { stroke: "#fa0", strokeWidth: 6 }),
    smoothPath([[460, 600], [560, 560], [640, 640], [560, 720], [470, 680]], { color: "#33415c", stroke: "#9cf", strokeWidth: 4 }, true),
    star(120, 790, 5, 80, 34, { color: "#ffd23f" }),
    star(290, 790, 8, 70, 50, { stroke: "#fff", strokeWidth: 5, lineJoin: "round" }),
    polygon([[400, 860], [470, 720], [540, 860]], { color: "#3ec" }),
    heart(620, 790, 150, { fill: { stops: [{ at: 0, color: "#ff9aa2" }, { at: 1, color: "#e5274b" }] } }),
    arc(120, 905, 40, -90, 180, { stroke: "#fff", strokeWidth: 10, lineCap: "round" }),
    arc(260, 905, 40, 0, interpolate(frame, [0, 29], [0, 330]), { stroke: "#f6a", strokeWidth: 10, lineCap: "round" }),
    line(340, 880, 460, 930, { stroke: "#9f6", strokeWidth: 8, lineCap: "round" }),
  ];
});
