// The new effects, each on the same test picture (a gradient card with shapes and text), labelled.
composition({ width: 960, height: 1280, fps: 30, durationInFrames: 30, background: "#0b0b12" }, function (frame, ctx) {
  const W = 240, H = 240;
  function pic(x, y, label, fx, bare) {
    const kids = bare ? [
      ellipse(x + 30, y + 30, 90, 90, { color: "#ffd23f" }),
      rect(x + 130, y + 50, 80, 120, { color: "#e8456b", radius: 10 }),
      text("Sprocket", { x: x, y: y + 150, width: W, size: 44, weight: 800, color: "#fff" }),
    ] : [
      gradient([{ at: 0, color: "#ff5f6d" }, { at: 1, color: "#3a7bd5" }], { x: x, y: y, width: W, height: H }),
      ellipse(x + 30, y + 30, 90, 90, { color: "#ffd23f" }),
      rect(x + 130, y + 50, 80, 120, { color: "#101018", radius: 10 }),
      polygon([[x + 40, y + 200], [x + 100, y + 130], [x + 160, y + 200]], { color: "#ffffff" }),
      text("Sprocket", { x: x, y: y + 150, width: W, size: 44, weight: 800, color: "#fff" }),
    ];
    return [
      group(kids, bare ? { effects: fx } : { effects: fx, clip: { x: x, y: y, width: W, height: H } }),
      text(label, { x: x, y: y + H + 4, width: W, size: 22, weight: 600, color: "#9aa" }),
    ];
  }
  const items = [
    ["dropShadow", [{ name: "dropShadow", color: "rgba(0,0,0,0.9)", radius: 12, x: 10, y: 14 }]],
    ["wave", [{ name: "wave", amount: 10, wavelength: 80, angle: 0, phase: frame * 20 }]],
    ["wave angle 90", [{ name: "wave", amount: 12, wavelength: 60, angle: 90, phase: 0 }]],
    ["twirl", [{ name: "twirl", x: 120 + 0, y: 120, radius: 110, angle: 120 }]],
    ["bulge", [{ name: "bulge", radius: 110, amount: 0.8 }]],
    ["pinch (bulge < 0)", [{ name: "bulge", radius: 110, amount: -0.8 }]],
    ["displace", [{ name: "displace", amount: 14, scale: 50, seed: 3 }]],
    ["glitch", [{ name: "glitch", amount: 0.6, seed: 5, slices: 12 }]],
    ["scanlines", [{ name: "scanlines", amount: 0.5, spacing: 6 }]],
    ["posterize 3", [{ name: "posterize", levels: 3 }]],
    ["threshold .5", [{ name: "threshold", amount: 0.5 }]],
    ["halftone", [{ name: "halftone", radius: 4, angle: 20 }]],
    ["duotone", [{ name: "duotone", dark: "#1b0b3a", light: "#ffb36b" }]],
    ["mirror x", [{ name: "mirror", axis: "x" }]],
    ["mirror y", [{ name: "mirror", axis: "y" }]],
    ["edges", [{ name: "edges", amount: 3 }]],
  ];
  const out = [];
  items.forEach(function (it, i) {
    const col = i % 4, row = Math.floor(i / 4);
    out.push(pic(8 + col * 238, 8 + row * 318, it[0], it[1].map(function (e) {
      // effects work in canvas space: shift per-picture centres to the picture
      const o = {}; for (const k in e) o[k] = e[k];
      const px = 8 + col * 238, py = 8 + row * 318;
      if (o.name === "twirl" || o.name === "bulge") { o.x = px + 120; o.y = py + 120; }
      if (o.name === "mirror") { if (o.axis === "x") o.x = px + 120; else o.y = py + 120; }
      return o;
    }), it[0] === "dropShadow"));
  });
  return out;
});
