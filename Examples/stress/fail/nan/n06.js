// rect(0, 400, 100, 100, { color: "#f0f", opacity: -5 })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), rect(0, 400, 100, 100, { color: "#f0f", opacity: -5 })];
});
