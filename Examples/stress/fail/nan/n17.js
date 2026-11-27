// gradient([{ at: 0, color: "#f00" }], { kind: "radial" })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), gradient([{ at: 0, color: "#f00" }], { kind: "radial" })];
});
