// Every node type on one canvas. Red rect top-left w/ white stroke, green ellipse, blue star path, gradients, image, video, text.
composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 90 }, function (frame, ctx) {
  const t = frame / 90;
  return [
    solid("#101820"),
    // row 1 y 40..240: rect(radius,stroke), ellipse, path
    rect(40, 40, 300, 200, { color: "#e53935", radius: 40, stroke: "#ffffff", strokeWidth: 12 }),
    rect(380, 40, 200, 200, { color: "transparent", stroke: "#ffeb3b", strokeWidth: 8 }),
    ellipse(620, 40, 200 + 60 * Math.sin(t * 6.28), 200, { color: "#43a047", stroke: "#fff", strokeWidth: 6 }),
    path("M 940 40 L 975 120 L 1040 130 L 990 180 L 1005 240 L 940 205 L 875 240 L 890 180 L 840 130 L 905 120 Z", { color: "#1e88e5", stroke: "#fff", strokeWidth: 5 }),
    // row 2 y 280..520: gradients
    gradient([{ at: 0, color: "#ff0080" }, { at: 0.5, color: "#ffff00" }, { at: 1, color: "#00ffff" }], { kind: "linear", from: { x: 40, y: 280 }, to: { x: 340 + 200 * t, y: 520 }, x: 40, y: 280, width: 500, height: 240 }),
    gradient([{ at: 0, color: "#ffffff" }, { at: 0.4, color: "#ff5722" }, { at: 1, color: "#000000" }], { kind: "radial", from: { x: 810, y: 400 }, to: { x: 810, y: 520 }, x: 560, y: 280, width: 480, height: 240 }),
    // row 3 y 560..860: image (testsrc2 contain), alpha image over image, video w/ radius clip
    image("pic", { x: 40, y: 560, width: 500, height: 300, fit: "contain" }),
    image("alpha", { x: 300, y: 700, width: 200, height: 200 }),
    video("c1", { time: t * 3, x: 580, y: 560, width: 460, height: 300, fit: "cover", clip: { x: 580, y: 560, width: 460, height: 300, radius: 40 } }),
    // text
    text("Helvetica Neue 100", { y: 900, size: 60, weight: 100, font: "Helvetica Neue", color: "#fff", align: "left", x: 40 }),
    text("Georgia 700 italic?", { y: 980, size: 60, weight: 700, font: "Georgia", color: "#ffd54f", align: "center" }),
    text("Menlo 400 right", { y: 1060, size: 60, font: "Menlo", color: "#80cbc4", align: "right", width: 1040 }),
    text("IMPACT 900 stroke", { y: 1140, size: 90, weight: 900, font: "Impact", color: "#fff", stroke: "#e53935", strokeWidth: 8 }),
    text("Shadowed text", { y: 1260, size: 90, weight: 800, color: "#fff", shadow: { color: "#000000", blur: 12, x: 8, y: 8 } }),
    text("This is a long paragraph of text that must wrap inside a 500px wide box and stay readable on several lines.", { x: 40, y: 1380, width: 500, size: 40, align: "left", color: "#fff", lineHeight: 1.3 }),
    text("Spaced out", { x: 560, y: 1380, width: 480, size: 44, letterSpacing: 12, color: "#f48fb1" }),
    text("Emoji 🔥😀🚀👍🏽", { y: 1560, size: 90, color: "#fff" }),
    text("नमस्ते दुनिया, यह एक परीक्षण है", { y: 1680, size: 80, weight: 700, color: "#fff" }),
    text("हिंदी वाक्य जो चौड़ाई में लपेटा जाना चाहिए, क्या यह ठीक दिखता है?", { x: 40, y: 1790, width: 1000, size: 40, color: "#a5d6a7" }),
  ];
});
