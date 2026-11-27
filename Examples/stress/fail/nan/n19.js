// gradient([{ at: 0, color: "#f00" }, { at: 1, color: "#00f" }], { from: { x: 5, y: 5 }, to: { x: 5, y: 5 } })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), gradient([{ at: 0, color: "#f00" }, { at: 1, color: "#00f" }], { from: { x: 5, y: 5 }, to: { x: 5, y: 5 } })];
});
