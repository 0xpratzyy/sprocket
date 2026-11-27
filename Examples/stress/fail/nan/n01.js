// rect(10, 10, NaN, 100, { color: "#f00" })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), rect(10, 10, NaN, 100, { color: "#f00" })];
});
