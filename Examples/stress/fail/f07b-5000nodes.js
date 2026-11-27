composition({ width: 540, height: 960, fps: 30, durationInFrames: 10 }, function (frame) {
  const o = [];
  for (let i = 0; i < 5000; i++) o.push(rect((i % 100) * 5, Math.floor(i / 100) * 5, 4, 4, { color: "#fff" }));
  return o;
});
