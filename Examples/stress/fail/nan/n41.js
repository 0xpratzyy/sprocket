// spring({ frame: 5, fps: 0 }) + 1
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), spring({ frame: 5, fps: 0 }) + 1];
});
