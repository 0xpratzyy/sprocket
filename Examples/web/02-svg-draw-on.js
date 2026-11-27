// An SVG illustration that draws itself on: stroke-dashoffset animated by CSS @keyframes (pathLength="1" makes the
// dash lengths unit-free). A second layer, a fill that fades in, shows several animations on one page.
const PAGE = `
<style>
  body { width: 1080px; height: 1080px; display: flex; align-items: center; justify-content: center; }
  svg { width: 900px; height: 900px; overflow: visible; }
  .draw { fill: none; stroke-linecap: round; stroke-linejoin: round; stroke-dasharray: 1; stroke-dashoffset: 1;
          animation: draw 1.6s cubic-bezier(.6,0,.3,1) forwards; }
  .d1 { stroke: #ffd166; stroke-width: 14; animation-delay: .1s; }
  .d2 { stroke: #ef476f; stroke-width: 14; animation-delay: .7s; }
  .d3 { stroke: #06d6a0; stroke-width: 14; animation-delay: 1.3s; }
  .d4 { stroke: #ffffff; stroke-width: 8; animation-delay: 2s; animation-duration: 1s; }
  .glow { filter: drop-shadow(0 0 16px currentColor); }
  .fill { opacity: 0; animation: fill .8s 2.4s ease-out forwards; }
  @keyframes draw { to { stroke-dashoffset: 0; } }
  @keyframes fill { to { opacity: .35; } }
</style>
<svg viewBox="0 0 600 600">
  <g class="glow" style="color:#ffd166"><circle class="fill" cx="300" cy="300" r="120" fill="#ffd166"/></g>
  <g class="glow" style="color:#ffd166"><path class="draw d1" pathLength="1" d="M300 180 A120 120 0 1 1 299.9 180"/></g>
  <g class="glow" style="color:#ef476f"><path class="draw d2" pathLength="1" d="M60 440 C 150 300, 250 560, 340 420 S 520 300, 560 400"/></g>
  <g class="glow" style="color:#06d6a0"><path class="draw d3" pathLength="1" d="M120 120 L 300 60 L 480 120 L 420 200 L 180 200 Z"/></g>
  <path class="draw d4" pathLength="1" d="M250 300 L 285 335 L 355 255"/>
</svg>`;

composition({ width: 1080, height: 1080, fps: 30, durationInFrames: 120, background: "#10121c" }, function (frame, ctx) {
  const t = frame / ctx.fps;
  return [
    gradient([{ at: 0, color: "#1b2036" }, { at: 1, color: "#0a0b12" }], { kind: "radial", from: { x: 540, y: 540 }, to: { x: 900, y: 540 } }),
    html(PAGE),
    text("drawn with stroke-dashoffset", { y: 980, size: 34, weight: 600, color: "#8a90a8", opacity: interpolate(t, [2.6, 3.2], [0, 1]) }),
  ];
});
