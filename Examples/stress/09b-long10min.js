// 10 minutes, 720x1280@30, 18000 frames (memory-growth check).
const scenes = [];
for (let i = 0; i < 120; i++) scenes.push({ durationInFrames: 150, src: "c" + (1 + i % 18), from: (i % 5) * 0.5 });
composition({ width: 720, height: 1280, fps: 30, durationInFrames: 18000, audio: [{ src: "longm", volume: 0.7, fadeIn: 1, fadeOut: 3 }] }, function (frame, ctx) {
  const o = series(frame, scenes, 20, function (a, b, p, ia, ib, local) {
    const layers = [video(a.src, { time: a.from + local.frame / 30, effects: [{ name: "saturation", amount: 1.2 }] })];
    if (b) layers.push(video(b.src, { time: b.from + local.frameB / 30, opacity: p, transform: { translateX: (1 - p) * 200 } }));
    layers.push(text("SCENE " + (ia + 1), { y: 200 + 20 * Math.sin(frame / 10), size: 150, weight: 900, color: "#fff", stroke: "#000", strokeWidth: 8, shadow: { color: "#000", blur: 10, x: 4, y: 4 } }));
    layers.push(rect(0, 1850, 720 * (frame / 17999), 20, { color: "#ff3d00" }));
    return layers;
  });
  return o;
});
