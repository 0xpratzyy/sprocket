composition({ width: 540, height: 960, fps: 30, durationInFrames: 12 }, function (frame) {
  if (frame < 3) return 42;
  if (frame < 6) return "a string";
  if (frame < 9) return { type: "bogus" };
  return [null, undefined, false, [[[solid("#0a0")]]], 0, "x", {}];
});
