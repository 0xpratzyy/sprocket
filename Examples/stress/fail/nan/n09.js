// text("nan size", { y: 700, size: NaN, color: "#fff" })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), text("nan size", { y: 700, size: NaN, color: "#fff" })];
});
