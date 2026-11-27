// Every effect, one after another (20 frames each), animated, with a label naming it.
const FX = [
 ["blur", p => ({ name: "blur", radius: 40 * p })],
 ["motionBlur", p => ({ name: "motionBlur", radius: 80 * p, angle: 30 })],
 ["zoomBlur", p => ({ name: "zoomBlur", amount: 120 * p, x: 300, y: 600 })],
 ["brightness", p => ({ name: "brightness", amount: -0.8 + 1.6 * p })],
 ["contrast", p => ({ name: "contrast", amount: 0 + 3 * p })],
 ["saturation", p => ({ name: "saturation", amount: 3 * (1 - p) })],
 ["exposure", p => ({ name: "exposure", amount: -3 + 6 * p })],
 ["hue", p => ({ name: "hue", angle: 360 * p })],
 ["invert", p => ({ name: "invert" })],
 ["sepia", p => ({ name: "sepia", amount: p })],
 ["grayscale", p => ({ name: "grayscale", amount: p })],
 ["vignette", p => ({ name: "vignette", amount: 2 * p, radius: 0.8 })],
 ["pixellate", p => ({ name: "pixellate", radius: 4 + 60 * p })],
 ["sharpen", p => ({ name: "sharpen", amount: 2 * p })],
 ["glow", p => ({ name: "glow", radius: 30, amount: p })],
 ["grain", p => ({ name: "grain", amount: p, seed: 3 })],
 ["rgbSplit", p => ({ name: "rgbSplit", amount: 40 * p, angle: 0 })],
 ["tint", p => ({ name: "tint", color: "#ff0000", amount: p })],
 ["colorMatrix", p => ({ name: "colorMatrix", matrix: [0,1,0,0,0, 0,0,1,0,0, 1,0,0,0,0, 0,0,0,1,0] })],
 ["unknownEffect (should be ignored)", p => ({ name: "doesNotExist", amount: 5 })],
];
const PER = 20;
composition({ width: 1080, height: 1920, fps: 30, durationInFrames: FX.length * PER }, function (frame, ctx) {
  const i = Math.floor(frame / PER), p = (frame % PER) / (PER - 1);
  const [label, mk] = FX[i];
  return [
    video("c" + (1 + i % 9), { time: (frame % PER) / 30, effects: [mk(p)] }),
    rect(0, 80, 1080, 120, { color: "#000000", opacity: 0.6 }),
    text(label, { y: 100, size: 72, weight: 800, color: "#fff" }),
  ];
});
