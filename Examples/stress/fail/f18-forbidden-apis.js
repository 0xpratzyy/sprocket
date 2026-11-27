composition({ width: 540, height: 960, fps: 30, durationInFrames: 5 }, function (frame) {
  const found = [typeof fetch, typeof XMLHttpRequest, typeof setTimeout, typeof require, typeof process, typeof document, typeof window, typeof console, typeof Date, typeof performance].join(",");
  return [solid("#123"), text(found, { y: 300, size: 24, width: 500, color: "#fff" }), text("Date.now=" + Date.now() + " rand=" + Math.random().toFixed(4) + " new Date=" + new Date().getTime(), { y: 500, size: 24, width: 500, color: "#fff" })];
});
