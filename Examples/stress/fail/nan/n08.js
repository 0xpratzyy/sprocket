// group([rect(0, 600, 100, 100, { color: "#fa0" })], { transform: { scale: NaN, rotate: Infinity, translateX: -Infinity } })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), group([rect(0, 600, 100, 100, { color: "#fa0" })], { transform: { scale: NaN, rotate: Infinity, translateX: -Infinity } })];
});
