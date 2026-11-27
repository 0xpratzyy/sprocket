// series(5, [{ durationInFrames: 10 }, { durationInFrames: 10 }], 50, (a, b, p) => text("p=" + p + " b=" + b, { y: 100, size: 30, color: "#fff" }))
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), series(5, [{ durationInFrames: 10 }, { durationInFrames: 10 }], 50, (a, b, p) => text("p=" + p + " b=" + b, { y: 100, size: 30, color: "#fff" }))];
});
