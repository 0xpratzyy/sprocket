// text("inf width", { y: 800, width: Infinity, size: 30, color: "#fff" })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), text("inf width", { y: 800, width: Infinity, size: 30, color: "#fff" })];
});
