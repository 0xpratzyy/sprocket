// group([rect(0, 0, 100, 100, { color: "#fff" })], { mask: "x" })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), group([rect(0, 0, 100, 100, { color: "#fff" })], { mask: "x" })];
});
