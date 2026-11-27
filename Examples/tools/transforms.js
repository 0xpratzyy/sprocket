// skewX / skewY, rotateX / rotateY with perspective. Each card is a 300x300 tile with a grid and an arrow.
composition({ width: 960, height: 960, fps: 30, durationInFrames: 30, background: "#101018" }, function (frame, ctx) {
  function card(cx, cy, color, tf, label) {
    const x = cx - 130, y = cy - 130;
    const kids = [
      rect(x, y, 260, 260, { color: color, radius: 16 }),
      rect(x + 20, y + 20, 100, 100, { color: "#ffffff" }),
      polygon([[x + 140, y + 40], [x + 240, y + 130], [x + 140, y + 220]], { color: "#101018" }),
      text(label, { x: x, y: y + 215, width: 260, size: 28, weight: 800, color: "#fff" }),
    ];
    const o = { originX: cx, originY: cy };
    for (const k in tf) o[k] = tf[k];
    return group(kids, { transform: o });
  }
  return [
    card(170, 170, "#e8456b", {}, "none"),
    card(480, 170, "#e8a23c", { skewX: 20 }, "skewX 20"),
    card(790, 170, "#3cc2e8", { skewY: 15 }, "skewY 15"),
    card(170, 480, "#7a5cf0", { rotateX: 50 }, "rotateX 50"),
    card(480, 480, "#3ce88a", { rotateY: 50 }, "rotateY 50"),
    card(790, 480, "#f06292", { rotateX: 40, rotateY: -35, rotate: 10 }, "X40 Y-35 r10"),
    card(170, 790, "#ffd23f", { rotateY: 70, perspective: 500 }, "persp 500"),
    card(480, 790, "#e8456b", { rotateX: -45, scale: 0.9, translateY: -20, skewX: 12 }, "mix"),
    card(790, 790, "#9ad", { rotateY: interpolate(frame, [0, 29], [-80, 80]), rotateX: 15 }, "spin"),
  ];
});
