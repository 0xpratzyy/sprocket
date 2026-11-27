// text("neg size", { y: 750, size: -50, color: "#fff" })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), text("neg size", { y: 750, size: -50, color: "#fff" })];
});
