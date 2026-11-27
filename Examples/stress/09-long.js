// 3 minutes, 1080x1920@30, 5400 frames: 36 scenes of 150 frames cycling 18 clips, 20-frame crossfade/whip transitions, text per scene.
const scenes = [];
for (let i = 0; i < 36; i++) scenes.push({ durationInFrames: 150, src: "c" + (1 + i % 18), from: (i % 5) * 0.5 });
composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 5400, audio: [{ src: "longm", volume: 0.7, fadeIn: 1, fadeOut: 3 }] }, function (frame, ctx) {
  const o = series(frame, scenes, 20, function (a, b, p, ia, ib, local) {
    const layers = [video(a.src, { time: a.from + local.frame / 30, effects: [{ name: "saturation", amount: 1.2 }] })];
    if (b) layers.push(video(b.src, { time: b.from + local.frameB / 30, opacity: p, transform: { translateX: (1 - p) * 200 } }));
    layers.push(text("SCENE " + (ia + 1), { y: 200 + 20 * Math.sin(frame / 10), size: 150, weight: 900, color: "#fff", stroke: "#000", strokeWidth: 8, shadow: { color: "#000", blur: 10, x: 4, y: 4 } }));
    layers.push(rect(0, 1850, 1080 * (frame / 5399), 20, { color: "#ff3d00" }));
    return layers;
  });
  return o;
});
