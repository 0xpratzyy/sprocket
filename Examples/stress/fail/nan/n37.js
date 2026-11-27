// image("pic", { x: 0, y: 0, width: 0, height: 0 })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), image("pic", { x: 0, y: 0, width: 0, height: 0 })];
});
