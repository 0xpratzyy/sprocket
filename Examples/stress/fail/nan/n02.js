// rect(10, 120, Infinity, 100, { color: "#0f0" })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), rect(10, 120, Infinity, 100, { color: "#0f0" })];
});
