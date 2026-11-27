// image("pic", { fit: "bogus", focusX: 99 })
composition({ width: 540, height: 960, fps: 30, durationInFrames: 3 }, function (frame) {
  return [solid("#224"), image("pic", { fit: "bogus", focusX: 99 })];
});
