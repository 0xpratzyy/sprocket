composition({ width: 540, height: 960, fps: 30, durationInFrames: 0 }, function (frame) { return [solid("#336699"), text("f" + frame, { y: 400, size: 100, color: "#fff" })]; });
