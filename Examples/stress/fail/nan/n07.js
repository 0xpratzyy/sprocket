// rect(0, 500, 100, 100, { color: "#0ff", opacity: 99 })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), rect(0, 500, 100, 100, { color: "#0ff", opacity: 99 })];
});
