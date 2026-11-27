// rect(0, 0, 100, 100, { clip: { x: 0, y: 0, width: -5, height: NaN, radius: -1 } })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), rect(0, 0, 100, 100, { clip: { x: 0, y: 0, width: -5, height: NaN, radius: -1 } })];
});
