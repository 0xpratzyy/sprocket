// line 1
composition({ width: 540, height: 960, fps: 30, durationInFrames: 60 }, function (frame) {
  // line 3
  if (frame === 40) {
    throw new Error("boom at forty");   // line 5
  }
  return solid("#0a0");
});
