composition({ width: 540, height: 960, fps: 30, durationInFrames: 5 }, function (frame) {
  return [solid("#224"), rect(0, 850, 100, 100, { color: 12345 })];   // line 2: color is a number
});
