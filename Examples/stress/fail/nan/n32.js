// rect(0, 0, 100, 100, { blend: 5 })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), rect(0, 0, 100, 100, { blend: 5 })];
});
