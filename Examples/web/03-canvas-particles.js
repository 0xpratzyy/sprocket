// Canvas 2D particles driven by window.sprocketFrame(t, frame). The picture is a pure function of t: every particle's
// position is computed from its index and the time (no state carried between frames), so any frame renders the same
// whether or not the frames before it were drawn.
const PAGE = `
<canvas id="c" width="1080" height="1920" style="display:block"></canvas>
<script>
  const cv = document.getElementById("c"), g = cv.getContext("2d");
  function rnd(i, k) { const x = Math.sin(i * 127.1 + k * 311.7) * 43758.5453; return x - Math.floor(x); }
  const N = 320;
  window.sprocketFrame = function (t, frame) {
    g.clearRect(0, 0, 1080, 1920);
    g.globalCompositeOperation = "lighter";
    for (let i = 0; i < N; i++) {
      const life = 3.2 + rnd(i, 1) * 2.4, born = rnd(i, 2) * life;
      const age = ((t + born) % life) / life;                     // 0..1 within this particle's life
      const ang = rnd(i, 3) * Math.PI * 2, speed = 220 + rnd(i, 4) * 520;
      const r = speed * age * (1.2 - 0.4 * age);
      const x = 540 + Math.cos(ang + t * 0.35) * r, y = 960 + Math.sin(ang + t * 0.35) * r - 260 * age * age;
      const size = (1 - age) * (6 + rnd(i, 5) * 22) + 1;
      const hue = 190 + rnd(i, 6) * 170 + t * 30;
      const grd = g.createRadialGradient(x, y, 0, x, y, size * 3);
      grd.addColorStop(0, "hsla(" + hue + ",100%,70%," + (0.9 * (1 - age)) + ")");
      grd.addColorStop(1, "hsla(" + hue + ",100%,50%,0)");
      g.fillStyle = grd;
      g.beginPath(); g.arc(x, y, size * 3, 0, Math.PI * 2); g.fill();
    }
    // a ring pulsing at the centre
    g.globalCompositeOperation = "source-over";
    g.lineWidth = 6; g.strokeStyle = "rgba(255,255,255," + (0.7 - 0.4 * Math.abs(Math.sin(t * 2))) + ")";
    g.beginPath(); g.arc(540, 960, 90 + 14 * Math.sin(t * 4), 0, Math.PI * 2); g.stroke();
  };
</script>`;

composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 90, background: "#05060d" }, function (frame, ctx) {
  return [
    gradient([{ at: 0, color: "#0d1030" }, { at: 1, color: "#03030a" }]),
    html(PAGE),
    text("canvas via sprocketFrame", { y: 1700, size: 54, weight: 700, color: "#ffffffcc", letterSpacing: 2 }),
  ];
});
