composition({ width: 540, height: 960, fps: 30, durationInFrames: 60 }, function (frame) { return [video("c1", { time: frame / 30 })]; });
