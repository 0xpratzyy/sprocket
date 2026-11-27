// path("M 0 0 L NaN 5 Z garbage", { color: "#fff" })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), path("M 0 0 L NaN 5 Z garbage", { color: "#fff" })];
});
