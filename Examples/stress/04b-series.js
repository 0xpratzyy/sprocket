// Prints series()/sequence()/interpolate/spring/random numeric results as large text for exact reading.
composition({ width: 1080, height: 600, fps: 30, durationInFrames: 140 }, function (frame) {
  const items = [{ durationInFrames: 40 }, { durationInFrames: 40 }, { durationInFrames: 40 }];
  const s = series(frame, items, 10, (a, b, p, ia, ib, l) => "ia=" + ia + " ib=" + ib + " p=" + (p === null ? "null" : p.toFixed(3)) + " frame=" + l.frame + " frameB=" + l.frameB + " start=" + l.start);
  const sq = sequence(frame, [{ durationInFrames: 30, render: (lf, i) => "seg" + i + " lf" + lf }, { durationInFrames: 30, render: (lf, i) => "seg" + i + " lf" + lf }]);
  const ex = [[-5, "clamp"], [-5, "extend"], [50, "clamp"], [50, "extend"]].map(([v, m]) => interpolate(v, [0, 10, 20], [0, 100, 50], { extrapolateLeft: m, extrapolateRight: m }));
  return [solid("#000"),
    text("f=" + frame + " series: " + s, { x: 20, y: 20, width: 1040, size: 36, align: "left", color: "#fff" }),
    text("sequence: " + sq, { x: 20, y: 150, width: 1040, size: 36, align: "left", color: "#ff0" }),
    text("interp -5clamp,-5ext,50clamp,50ext = " + ex.join(", "), { x: 20, y: 250, width: 1040, size: 36, align: "left", color: "#0f0" }),
    text("spring f0=" + spring({ frame: 0, fps: 30 }).toFixed(3) + " f15=" + spring({ frame: 15, fps: 30 }).toFixed(3) + " f60=" + spring({ frame: 60, fps: 30 }).toFixed(3) + " from5to10 f0=" + spring({ frame: 0, fps: 30, from: 5, to: 10 }).toFixed(2) + " delay20 f10=" + spring({ frame: 10, fps: 30, delay: 20 }).toFixed(2), { x: 20, y: 350, width: 1040, size: 30, align: "left", color: "#0ff" }),
    text("random(1)=" + random(1).toFixed(4) + " random('a')=" + random("a").toFixed(4) + " mix=" + mix("#ff0000", "#0000ff", 0.5) + " noise(0.5,0.5)=" + noise(0.5, 0.5).toFixed(3) + " bez=" + Easing.bezier(0.42, 0, 0.58, 1)(0.5).toFixed(3) + " inOutCubic(.25)=" + Easing.inOutCubic(0.25).toFixed(3), { x: 20, y: 450, width: 1040, size: 28, align: "left", color: "#f8f" }),
  ];
});
