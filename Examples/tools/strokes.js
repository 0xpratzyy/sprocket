// Strokes: lineCap, lineJoin, dash, dashOffset, trim (a line that draws itself on).
composition({ width: 720, height: 960, fps: 30, durationInFrames: 60, background: "#111" }, function (frame, ctx) {
  const t = interpolate(frame, [0, 50], [0, 1], { easing: Easing.inOutCubic });
  const zig = "M60 120 L180 40 L300 120";
  return [
    // caps
    path("M60 60 L260 60", { stroke: "#fff", strokeWidth: 30, lineCap: "butt" }),
    path("M60 120 L260 120", { stroke: "#fff", strokeWidth: 30, lineCap: "round" }),
    path("M60 180 L260 180", { stroke: "#fff", strokeWidth: 30, lineCap: "square" }),
    // joins
    group([
      path("M330 100 L420 40 L510 100", { stroke: "#ff5a5f", strokeWidth: 26, lineJoin: "miter" }),
      path("M330 200 L420 140 L510 200", { stroke: "#ffd23f", strokeWidth: 26, lineJoin: "round" }),
      path("M560 100 L620 40 L680 100", { stroke: "#3ec", strokeWidth: 26, lineJoin: "bevel" }),
    ]),
    // dashes: plain, round dots, animated offset
    line(60, 280, 660, 280, { stroke: "#fff", strokeWidth: 8, dash: [30, 20] }),
    line(60, 330, 660, 330, { stroke: "#fa0", strokeWidth: 12, dash: [0, 24], lineCap: "round" }),
    line(60, 380, 660, 380, { stroke: "#0cf", strokeWidth: 8, dash: [40, 16, 8, 16], dashOffset: frame * 6 }),
    // trim on a circle, a rect, a curve (draws on), and a trim window that slides
    ellipse(60, 440, 200, 200, { stroke: "#fff", strokeWidth: 14, lineCap: "round", trim: { start: 0, end: t } }),
    rect(300, 440, 200, 200, { stroke: "#fa0", strokeWidth: 14, lineJoin: "round", trim: { start: 0, end: t } }),
    path("M540 640 C 540 440, 700 440, 700 640", { stroke: "#0cf", strokeWidth: 14, lineCap: "round", trim: { start: 0, end: t } }),
    // trim with a fill: the fill stays whole
    ellipse(60, 700, 200, 200, { color: "#335", stroke: "#fff", strokeWidth: 10, trim: { start: t * 0.5, end: 0.5 + t * 0.5 } }),
    // multi-subpath: total length counts across the subpaths
    path("M300 720 L500 720 M300 800 L500 800 M300 880 L500 880", { stroke: "#f6a", strokeWidth: 16, lineCap: "round", trim: { start: 0, end: t } }),
    path("M560 720 L690 720 L690 880 L560 880 Z", { stroke: "#9f6", strokeWidth: 10, dash: [18, 10], trim: { start: 0, end: t } }),
  ];
});
