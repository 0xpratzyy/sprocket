composition({ width: 540, height: 960, fps: 30, durationInFrames: 30, audio: [{ src: "garbage" }, { src: "zero" }, { src: "nonexist" }] }, function (frame) {
  return [solid("#224"), image("garbage", {}), image("c1", {}), text("bad image/audio", { y: 400, size: 50, color: "#fff" })];
});
