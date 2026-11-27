composition({ width: 540, height: 960, fps: 30, durationInFrames: 30 }, function (frame) {
  return [solid("#224"), video("not_mapped", { time: frame / 30 }), image("not_mapped_img", {}), text("missing asset ids", { y: 400, size: 50, color: "#fff" })];
});
