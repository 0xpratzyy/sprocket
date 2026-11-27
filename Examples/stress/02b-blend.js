// Each blend mode: orange (#ff9800) over a horizontal rainbow + vertical grey ramp background, 10 cells.
const BL = ["normal","multiply","screen","overlay","add","darken","lighten","softLight","hardLight","difference","bogusMode"];
composition({ width: 1080, height: 1920, fps: 30, durationInFrames: 2 }, function (frame) {
  const o = [
    gradient([{at:0,color:"#f00"},{at:.2,color:"#ff0"},{at:.4,color:"#0f0"},{at:.6,color:"#0ff"},{at:.8,color:"#00f"},{at:1,color:"#f0f"}], { kind: "linear", from:{x:0,y:0}, to:{x:1080,y:0} }),
  ];
  BL.forEach((b, i) => { const y = 20 + i * 170;
    o.push(rect(300, y, 480, 150, { color: "#ff9800", blend: b }));
    o.push(text(b, { x: 20, y: y + 50, width: 260, size: 44, align: "left", color: "#fff", stroke: "#000", strokeWidth: 4 })); });
  return o;
});
