// text("weight999", { y: 100, size: 30, weight: 99999, font: "NoSuchFontFamilyXYZ", color: "#fff" })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), text("weight999", { y: 100, size: 30, weight: 99999, font: "NoSuchFontFamilyXYZ", color: "#fff" })];
});
