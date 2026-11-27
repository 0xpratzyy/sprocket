// series(1, [{ durationInFrames: 0 }], 5, () => solid("#f00"))
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), series(1, [{ durationInFrames: 0 }], 5, () => solid("#f00"))];
});
