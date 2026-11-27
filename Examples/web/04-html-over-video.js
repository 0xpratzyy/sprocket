// An html layer over a video(): a CSS-animated lower third, composited with a blend mode (screen) and a clip, then a second
// copy under a luma mask. Run with:  --asset c1=/path/to/04a-base-video.mp4
const LOWER = `
<style>
  body { width: 720px; height: 420px; font-family: "Avenir Next", "Helvetica Neue", Arial, sans-serif; color: #fff; }
  .tag { position: absolute; left: 40px; top: 90px; padding: 22px 36px; font-size: 52px; font-weight: 800; letter-spacing: -1px; white-space: nowrap;
         background: linear-gradient(90deg, #ff3d71, #ff8a00); border-radius: 18px; transform-origin: left center;
         animation: slidein .7s cubic-bezier(.2,.9,.2,1) both; }
  .sub { position: absolute; left: 44px; top: 210px; font-size: 34px; font-weight: 500; opacity: .95; animation: slidein .7s .25s both cubic-bezier(.2,.9,.2,1); }
  .ring { position: absolute; right: 50px; top: 60px; width: 120px; height: 120px; border-radius: 50%; border: 10px solid #fff;
          border-top-color: transparent; animation: spin 1.4s linear infinite; }
  @keyframes slidein { from { opacity: 0; transform: translateX(-220px) skewX(-12deg); } to { opacity: 1; transform: none; } }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
<div class="tag">LIVE FROM LISBON</div><div class="sub">frame <b style="font-variant-numeric:tabular-nums" id="n"></b></div><div class="ring"></div>
<style>#n::before { content: counter(c); counter-reset: c var(--frame); }</style>`;

composition({ width: 720, height: 1280, fps: 30, durationInFrames: 90, background: "#000" }, function (frame, ctx) {
  return [
    video("c1", { time: frame / ctx.fps }),
    html(LOWER, { x: 0, y: 760, width: 720, height: 420, blend: "screen" }),
    html(LOWER, { x: 0, y: 120, width: 720, height: 420, opacity: 0.85, clip: { x: 0, y: 120, width: 720, height: 300, radius: 40 },
                  transform: { scale: 0.8, rotate: -6, translateY: 20 } }),
  ];
});
