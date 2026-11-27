// rect(0, 850, 100, 100, { color: "notacolor" })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), rect(0, 850, 100, 100, { color: "notacolor" })];
});
