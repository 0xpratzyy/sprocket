composition({ width: 540, height: 960, fps: 30, durationInFrames: 10 }, function (frame) {
  let n = rect(0, 0, 10, 10, { color: "#fff" });
  for (let i = 0; i < 6000; i++) n = group([n]);   // 6000-deep nesting
  return n;
});
