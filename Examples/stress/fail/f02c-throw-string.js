composition({ width: 540, height: 960, fps: 30, durationInFrames: 10 }, function (frame) {
  if (frame === 5) throw "just a string";   // line 2
  return solid("#0a0");
});
