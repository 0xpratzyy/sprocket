// path("M 10 10 L 100 100", { stroke: "#fff", strokeWidth: 1e9 })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), path("M 10 10 L 100 100", { stroke: "#fff", strokeWidth: 1e9 })];
});
