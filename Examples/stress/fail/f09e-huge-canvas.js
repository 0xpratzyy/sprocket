composition({ width: 20000, height: 20000, fps: 30, durationInFrames: 5 }, function (frame) { return [solid("#336699"), text("f" + frame, { y: 400, size: 100, color: "#fff" })]; });
