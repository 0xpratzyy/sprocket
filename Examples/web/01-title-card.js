// A CSS-animated title card: gradient text with a glow, a sweeping highlight and staggered letters.
// Everything animates with plain @keyframes; the engine seeks every animation to the frame's time.
const PAGE = `
<style>
  :root { --a: #7c5cff; --b: #ff4d8d; }
  body { width: 1080px; height: 1920px; position: relative; font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; }
  .card {
    position: absolute; left: 90px; top: 700px; width: 900px; box-sizing: border-box; padding: 70px 60px; border-radius: 56px;
    background: linear-gradient(135deg, rgba(20,20,40,.82), rgba(40,10,60,.82));
    box-shadow: 0 40px 120px rgba(124,92,255,.55), inset 0 0 0 2px rgba(255,255,255,.12);
    backdrop-filter: blur(20px);
    animation: rise 1.2s cubic-bezier(.2,.9,.2,1) both;
  }
  .kicker { color: #b9b4ff; letter-spacing: 14px; font-size: 34px; font-weight: 700; text-transform: uppercase;
            animation: fade 1s .4s both; }
  h1 { margin: 24px 0 0; font-size: 150px; line-height: 1; font-weight: 900; letter-spacing: -4px; }
  h1 span { display: inline-block; background: linear-gradient(90deg, var(--a), var(--b), var(--a)); background-size: 200% 100%;
            -webkit-background-clip: text; background-clip: text; color: transparent;
            filter: drop-shadow(0 0 28px rgba(255,77,141,.65));
            animation: letter .9s cubic-bezier(.2,1.4,.4,1) both, slide 3s linear infinite; }
  h1 span:nth-child(1){animation-delay:.5s,0s} h1 span:nth-child(2){animation-delay:.58s,0s} h1 span:nth-child(3){animation-delay:.66s,0s}
  h1 span:nth-child(4){animation-delay:.74s,0s} h1 span:nth-child(5){animation-delay:.82s,0s} h1 span:nth-child(6){animation-delay:.9s,0s}
  .bar { height: 10px; margin-top: 50px; border-radius: 5px; background: linear-gradient(90deg, var(--a), var(--b));
         transform-origin: left; animation: grow 1.4s 1s cubic-bezier(.7,0,.2,1) both; }
  .shine { position: absolute; inset: 0; border-radius: 56px; overflow: hidden; pointer-events: none; }
  .shine::after { content: ""; position: absolute; top: -50%; bottom: -50%; width: 160px; left: -200px;
                  background: linear-gradient(90deg, transparent, rgba(255,255,255,.35), transparent); transform: rotate(20deg);
                  animation: sweep 2.2s 1.6s ease-in-out infinite; }
  @keyframes rise { from { opacity: 0; transform: translateY(160px) scale(.9) rotateX(25deg); } to { opacity: 1; transform: none; } }
  @keyframes fade { from { opacity: 0; transform: translateY(20px); } to { opacity: 1; transform: none; } }
  @keyframes letter { from { opacity: 0; transform: translateY(80px) rotate(12deg) scale(.6); } to { opacity: 1; transform: none; } }
  @keyframes slide { to { background-position: 200% 0; } }
  @keyframes grow { from { transform: scaleX(0); } to { transform: scaleX(1); } }
  @keyframes sweep { from { left: -200px; } to { left: 1100px; } }
</style>
<div class="card">
  <div class="kicker">Sprocket presents</div>
  <h1><span>M</span><span>O</span><span>T</span><span>I</span><span>O</span><span>N</span></h1>
  <div class="bar"></div>
  <div class="shine"></div>
</div>`;

composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 90, background: "#0b0b14" }, function (frame, ctx) {
  return [
    gradient([{ at: 0, color: "#1a1038" }, { at: 1, color: "#05050c" }]),
    html(PAGE),
  ];
});
