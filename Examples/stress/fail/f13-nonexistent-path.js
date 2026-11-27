composition({ width: 540, height: 960, fps: 30, durationInFrames: 30 }, function (frame) {
  return [solid("#224"), video("nonexist", { time: frame / 30 }), text("nonexistent path", { y: 400, size: 50, color: "#fff" })];
});
