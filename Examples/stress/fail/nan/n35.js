// text(null, { y: 100, size: 30 })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), text(null, { y: 100, size: 30 })];
});
