// group([rect(0, 0, 50, 50, { color: "#f00" })], { effects: [{ name: "blur", radius: NaN }, { name: "contrast", amount: Infinity }, { name: "hue", angle: NaN }] })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), group([rect(0, 0, 50, 50, { color: "#f00" })], { effects: [{ name: "blur", radius: NaN }, { name: "contrast", amount: Infinity }, { name: "hue", angle: NaN }] })];
});
