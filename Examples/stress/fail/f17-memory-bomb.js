composition({ width: 540, height: 960, fps: 30, durationInFrames: 5 }, function (frame) {
  const a = []; for (let i = 0; i < 3e7; i++) a.push(i);   // memory/time bomb at frame 0
  return solid("#f00");
});
