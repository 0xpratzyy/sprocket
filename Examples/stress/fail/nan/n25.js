// video("c1", { time: -1e12 })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), video("c1", { time: -1e12 })];
});
