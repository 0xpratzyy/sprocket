// ellipse(NaN, NaN, 50, 50, { color: "#ff0" })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), ellipse(NaN, NaN, 50, 50, { color: "#ff0" })];
});
