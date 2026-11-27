composition({ width: 540, height: 960, fps: 30, durationInFrames: 60 }, function (frame) {
  if (frame === 20) { for (;;) {} }   // line 2
  return solid("#0a0");
});
