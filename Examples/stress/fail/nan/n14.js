// rect(0, 850, 50, 50, { color: "#xyz" })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), rect(0, 850, 50, 50, { color: "#xyz" })];
});
