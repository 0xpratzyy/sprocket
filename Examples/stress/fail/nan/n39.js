// video("c1", { fit: "bogus", focusX: -99, time: 1 })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), video("c1", { fit: "bogus", focusX: -99, time: 1 })];
});
