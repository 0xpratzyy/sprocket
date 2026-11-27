// Makes a plain moving-gradient clip (render it with the CLI) to stand in for camera footage in 04-html-over-video.js.
composition({ width: 720, height: 1280, fps: 30, durationInFrames: 90, background: "#000" }, function (frame, ctx) {
  const t = frame / ctx.fps;
  return [
    gradient([{ at: 0, color: "#0f4c81" }, { at: 0.5, color: "#e07a5f" }, { at: 1, color: "#f2cc8f" }],
             { from: { x: 360 + 300 * Math.cos(t), y: 0 }, to: { x: 360 - 300 * Math.cos(t), y: 1280 } }),
    ellipse(120 + 300 * Math.sin(t * 1.3), 400 + 120 * Math.cos(t * 2), 300, 300, { color: "#ffffffaa", effects: [{ name: "blur", radius: 40 }] }),
  ];
});
