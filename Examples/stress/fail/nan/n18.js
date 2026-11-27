// gradient([{ at: NaN, color: "#f00" }, { at: 1, color: "#00f" }], { from: { x: 0, y: 0 }, to: { x: 0, y: 0 } })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), gradient([{ at: NaN, color: "#f00" }, { at: 1, color: "#00f" }], { from: { x: 0, y: 0 }, to: { x: 0, y: 0 } })];
});
