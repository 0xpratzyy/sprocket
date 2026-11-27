// rect(10, 230, -100, -100, { color: "#00f" })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), rect(10, 230, -100, -100, { color: "#00f" })];
});
