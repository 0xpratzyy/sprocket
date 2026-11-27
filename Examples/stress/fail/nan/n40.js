// rect(0, 0, 100, 100, { transform: { originX: "a", scale: "2" } })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), rect(0, 0, 100, 100, { transform: { originX: "a", scale: "2" } })];
});
