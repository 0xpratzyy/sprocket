// Sprocket prelude: the globals every composition script sees (see API.md). Pure computation only.
(function (global) {
  "use strict";

  // ---------- state ----------
  var RealDate = Date;
  var nowMs = 0;
  var rng = null;
  var registrations = 0;
  var registered = null; // { config, render }
  var MAX_NODES = 5000;

  // ---------- small PRNG + hashing ----------
  function mulberry32(a) {
    return function () {
      a = (a + 0x6D2B79F5) | 0;
      var t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  function hashString(s) {
    var h = 2166136261;
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619);
    }
    h ^= h >>> 16; h = Math.imul(h, 2246822507);
    h ^= h >>> 13; h = Math.imul(h, 3266489909);
    h ^= h >>> 16;
    return h >>> 0;
  }

  // Deterministic Math.random and Date. Reseeded before every render call.
  var seededRandom = function () { return rng ? rng() : 0.5; };
  try { Math.random = seededRandom; } catch (e) {}
  rng = mulberry32(0x9e3779b9);
  var FakeDate = class extends RealDate {
    constructor() {
      if (arguments.length === 0) { super(nowMs); }
      else { super(...arguments); }
    }
    static now() { return nowMs; }
  };
  global.Date = FakeDate;

  // ---------- console (collects into the host) ----------
  var hostLog = global.__motionLog;
  try { delete global.__motionLog; } catch (e) {}
  var hostLayout = global.__motionLayoutText;
  try { delete global.__motionLayoutText; } catch (e) {}
  function fmt(v) {
    if (typeof v === "string") return v;
    if (v === undefined) return "undefined";
    if (typeof v === "function") return "[function]";
    try { var s = JSON.stringify(v); return s === undefined ? String(v) : s; } catch (e) { return String(v); }
  }
  function logFn() {
    var parts = [];
    for (var i = 0; i < arguments.length; i++) parts.push(fmt(arguments[i]));
    var line = parts.join(" ");
    if (line.length > 2000) line = line.slice(0, 2000);
    if (typeof hostLog === "function") hostLog(line);
  }
  global.console = { log: logFn, info: logFn, warn: logFn, error: logFn, debug: logFn };

  // ---------- numeric helpers ----------
  function clamp(v, lo, hi) { return Math.min(Math.max(v, lo), hi); }
  function lerp(a, b, t) { return a + (b - a) * t; }
  function secondsToFrames(s, fps) { return Math.round(s * fps); }
  function framesToSeconds(f, fps) { return f / fps; }

  // ---------- easing ----------
  var c1 = 1.70158, c2 = c1 * 1.525, c3 = c1 + 1, c4 = (2 * Math.PI) / 3;
  function outBounce(x) {
    var n1 = 7.5625, d1 = 2.75;
    if (x < 1 / d1) return n1 * x * x;
    if (x < 2 / d1) { x -= 1.5 / d1; return n1 * x * x + 0.75; }
    if (x < 2.5 / d1) { x -= 2.25 / d1; return n1 * x * x + 0.9375; }
    x -= 2.625 / d1; return n1 * x * x + 0.984375;
  }
  function bezier(x1, y1, x2, y2) {
    function cx(t) { var u = 1 - t; return 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t; }
    function cy(t) { var u = 1 - t; return 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t; }
    function dx(t) { var u = 1 - t; return 3 * u * u * x1 + 6 * u * t * (x2 - x1) + 3 * t * t * (1 - x2); }
    return function (x) {
      if (x <= 0) return 0;
      if (x >= 1) return 1;
      var t = x, i;
      for (i = 0; i < 8; i++) {
        var err = cx(t) - x;
        if (Math.abs(err) < 1e-7) return cy(t);
        var d = dx(t);
        if (Math.abs(d) < 1e-6) break;
        t -= err / d;
      }
      var lo = 0, hi = 1; t = x;
      for (i = 0; i < 60; i++) {
        var v = cx(t);
        if (Math.abs(v - x) < 1e-7) break;
        if (v < x) lo = t; else hi = t;
        t = (lo + hi) / 2;
      }
      return cy(t);
    };
  }
  var Easing = {
    linear: function (x) { return x; },
    inQuad: function (x) { return x * x; },
    outQuad: function (x) { return 1 - (1 - x) * (1 - x); },
    inOutQuad: function (x) { return x < 0.5 ? 2 * x * x : 1 - Math.pow(-2 * x + 2, 2) / 2; },
    inCubic: function (x) { return x * x * x; },
    outCubic: function (x) { return 1 - Math.pow(1 - x, 3); },
    inOutCubic: function (x) { return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2; },
    inQuart: function (x) { return x * x * x * x; },
    outQuart: function (x) { return 1 - Math.pow(1 - x, 4); },
    inOutQuart: function (x) { return x < 0.5 ? 8 * x * x * x * x : 1 - Math.pow(-2 * x + 2, 4) / 2; },
    inExpo: function (x) { return x === 0 ? 0 : Math.pow(2, 10 * x - 10); },
    outExpo: function (x) { return x === 1 ? 1 : 1 - Math.pow(2, -10 * x); },
    inOutExpo: function (x) {
      if (x === 0) return 0;
      if (x === 1) return 1;
      return x < 0.5 ? Math.pow(2, 20 * x - 10) / 2 : (2 - Math.pow(2, -20 * x + 10)) / 2;
    },
    inBack: function (x) { return c3 * x * x * x - c1 * x * x; },
    outBack: function (x) { return 1 + c3 * Math.pow(x - 1, 3) + c1 * Math.pow(x - 1, 2); },
    inOutBack: function (x) {
      return x < 0.5
        ? (Math.pow(2 * x, 2) * ((c2 + 1) * 2 * x - c2)) / 2
        : (Math.pow(2 * x - 2, 2) * ((c2 + 1) * (x * 2 - 2) + c2) + 2) / 2;
    },
    outElastic: function (x) {
      if (x === 0) return 0;
      if (x === 1) return 1;
      return Math.pow(2, -10 * x) * Math.sin((x * 10 - 0.75) * c4) + 1;
    },
    outBounce: outBounce,
    bezier: bezier
  };

  // ---------- interpolate ----------
  function interpolate(value, inR, outR, opts) {
    opts = opts || {};
    if (!Array.isArray(inR) || !Array.isArray(outR) || inR.length < 2 || inR.length !== outR.length)
      throw new Error("interpolate: input and output ranges must be arrays of the same length (at least 2)");
    var n = inR.length, i;
    for (i = 1; i < n; i++)
      if (!(inR[i] >= inR[i - 1])) throw new Error("interpolate: the input range must be non-decreasing");
    var easing = opts.easing || Easing.linear;
    var left = opts.extrapolateLeft || "clamp", right = opts.extrapolateRight || "clamp";
    function seg(k, v) {
      var a = inR[k], b = inR[k + 1];
      return b === a ? (v >= b ? 1 : 0) : (v - a) / (b - a);
    }
    if (value < inR[0]) {
      if (left !== "extend") return outR[0];
      return outR[0] + (outR[1] - outR[0]) * seg(0, value);
    }
    if (value > inR[n - 1]) {
      if (right !== "extend") return outR[n - 1];
      return outR[n - 2] + (outR[n - 1] - outR[n - 2]) * seg(n - 2, value);
    }
    var k = 0;
    for (i = 0; i < n - 1; i++) { if (value >= inR[i]) k = i; }
    if (k > n - 2) k = n - 2;
    var t = seg(k, value);
    return outR[k] + (outR[k + 1] - outR[k]) * easing(t);
  }

  // ---------- spring (analytic damped oscillator, starts at rest) ----------
  function spring(o) {
    o = o || {};
    var fps = o.fps || 30, from = o.from === undefined ? 0 : o.from, to = o.to === undefined ? 1 : o.to;
    var k = o.stiffness === undefined ? 100 : o.stiffness;
    var c = o.damping === undefined ? 10 : o.damping;
    var m = o.mass === undefined ? 1 : o.mass;
    var t = ((o.frame || 0) - (o.delay || 0)) / fps;
    if (!(t > 0)) return from;
    var w0 = Math.sqrt(k / m), z = c / (2 * Math.sqrt(k * m)), x;
    if (z < 1) {
      var wd = w0 * Math.sqrt(1 - z * z);
      x = 1 - Math.exp(-z * w0 * t) * (Math.cos(wd * t) + (z * w0 / wd) * Math.sin(wd * t));
    } else if (z === 1) {
      x = 1 - Math.exp(-w0 * t) * (1 + w0 * t);
    } else {
      var s = Math.sqrt(z * z - 1), r1 = -w0 * (z - s), r2 = -w0 * (z + s);
      x = 1 - (r2 * Math.exp(r1 * t) - r1 * Math.exp(r2 * t)) / (r2 - r1);
    }
    return from + (to - from) * x;
  }

  // ---------- colour ----------
  var NAMES = {
    white: [255, 255, 255, 1], black: [0, 0, 0, 1], red: [255, 0, 0, 1], green: [0, 128, 0, 1],
    blue: [0, 0, 255, 1], yellow: [255, 255, 0, 1], orange: [255, 165, 0, 1], purple: [128, 0, 128, 1],
    pink: [255, 192, 203, 1], gray: [128, 128, 128, 1], transparent: [0, 0, 0, 0]
  };
  function hslToRgb(h, s, l) {
    h = ((h % 360) + 360) % 360 / 360;
    if (s === 0) { var g = Math.round(l * 255); return [g, g, g]; }
    var q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
    function f(t) {
      if (t < 0) t += 1; if (t > 1) t -= 1;
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    }
    return [Math.round(f(h + 1 / 3) * 255), Math.round(f(h) * 255), Math.round(f(h - 1 / 3) * 255)];
  }
  function parseColor(str) {
    var s = String(str).trim().toLowerCase(), m;
    if (NAMES.hasOwnProperty(s)) return NAMES[s].slice();
    if ((m = /^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/.exec(s))) {
      var h = m[1];
      if (h.length <= 4) h = h.split("").map(function (ch) { return ch + ch; }).join("");
      return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16),
              h.length === 8 ? parseInt(h.slice(6, 8), 16) / 255 : 1];
    }
    if ((m = /^(rgba?|hsla?)\(([^)]*)\)$/.exec(s))) {
      var parts = m[2].split(/[\s,\/]+/).filter(function (p) { return p.length; });
      if (parts.length >= 3) {
        var pct = function (p) { return p.slice(-1) === "%" ? parseFloat(p) / 100 : null; };
        var a = parts.length > 3 ? (pct(parts[3]) !== null ? pct(parts[3]) : parseFloat(parts[3])) : 1;
        if (m[1].charAt(0) === "r") {
          var rgb = parts.slice(0, 3).map(function (p) { return pct(p) !== null ? pct(p) * 255 : parseFloat(p); });
          if (rgb.every(isFinite) && isFinite(a)) return [rgb[0], rgb[1], rgb[2], a];
        } else {
          var hh = parseFloat(parts[0]), ss = parseFloat(parts[1]) / 100, ll = parseFloat(parts[2]) / 100;
          if ([hh, ss, ll, a].every(isFinite)) { var r = hslToRgb(hh, ss, ll); return [r[0], r[1], r[2], a]; }
        }
      }
    }
    throw new Error('mix: cannot parse colour "' + str + '"');
  }
  function hex2(v) { var n = Math.round(clamp(v, 0, 255)); return (n < 16 ? "0" : "") + n.toString(16); }
  function mix(a, b, t) {
    var A = parseColor(a), B = parseColor(b);
    var r = lerp(A[0], B[0], t), g = lerp(A[1], B[1], t), bl = lerp(A[2], B[2], t), al = clamp(lerp(A[3], B[3], t), 0, 1);
    if (al >= 1) return "#" + hex2(r) + hex2(g) + hex2(bl);
    return "rgba(" + Math.round(clamp(r, 0, 255)) + "," + Math.round(clamp(g, 0, 255)) + "," +
      Math.round(clamp(bl, 0, 255)) + "," + (Math.round(al * 1000) / 1000) + ")";
  }

  // ---------- random + noise ----------
  function random(seed) {
    return mulberry32(hashString(String(seed)))();
  }
  function lattice(ix, iy) {
    var h = (Math.imul(ix, 374761393) + Math.imul(iy, 668265263)) | 0;
    h = Math.imul(h ^ (h >>> 13), 1274126177);
    h ^= h >>> 16;
    return ((h >>> 0) / 4294967296) * 2 - 1;
  }
  function fade(t) { return t * t * t * (t * (t * 6 - 15) + 10); }
  function noise(x, y) {
    y = y === undefined ? 0 : y;
    var ix = Math.floor(x), iy = Math.floor(y), fx = x - ix, fy = y - iy;
    var u = fade(fx), v = fade(fy);
    var a = lattice(ix, iy), b = lattice(ix + 1, iy), c = lattice(ix, iy + 1), d = lattice(ix + 1, iy + 1);
    return lerp(lerp(a, b, u), lerp(c, d, u), v);
  }

  // ---------- sequence / series ----------
  function sequence(frame, items) {
    var start = 0;
    for (var i = 0; i < items.length; i++) {
      var d = items[i].durationInFrames;
      if (frame >= start && frame < start + d) return items[i].render(frame - start, i);
      start += d;
    }
    return null;
  }
  // Segment i spans [S_i, S_i + d_i). In the last `overlap` frames of a segment that has a next item,
  // b is that next item and progress runs 0 -> 1 reaching 1 at the next segment's first frame.
  // A sixth argument gives the local frames: { frame (in a), frameB (in b, negative until b's own segment starts), start }.
  function series(frame, items, overlap, render) {
    overlap = Math.max(0, overlap || 0);
    var start = 0;
    for (var i = 0; i < items.length; i++) {
      var d = items[i].durationInFrames;
      if (frame >= start && frame < start + d) {
        var ov = Math.min(overlap, d);
        var ts = start + d - ov;
        if (i + 1 < items.length && ov > 0 && frame >= ts) {
          return render(items[i], items[i + 1], (frame - ts) / ov, i, i + 1,
            { frame: frame - start, frameB: frame - (start + d), start: start });
        }
        return render(items[i], null, 0, i, null, { frame: frame - start, frameB: null, start: start });
      }
      start += d;
    }
    return null;
  }

  // ---------- node constructors ----------
  function mk(type, base, props) {
    var n = { type: type };
    var k;
    for (k in base) if (Object.prototype.hasOwnProperty.call(base, k)) n[k] = base[k];
    if (props) for (k in props) if (Object.prototype.hasOwnProperty.call(props, k)) n[k] = props[k];
    n.type = type;
    return n;
  }
  function group(children, props) { return mk("group", { children: children }, props); }
  function solid(color, props) { return mk("solid", { color: color }, props); }
  function rect(x, y, w, h, props) { return mk("rect", { x: x, y: y, width: w, height: h }, props); }
  function ellipse(x, y, w, h, props) { return mk("ellipse", { x: x, y: y, width: w, height: h }, props); }
  function path(d, props) { return mk("path", { d: d }, props); }
  function gradient(stops, props) { return mk("gradient", { stops: stops }, props); }
  function image(src, props) { return mk("image", { src: src }, props); }
  function video(src, props) { return mk("video", { src: src }, props); }
  // cutout(src, { time, kind }): a video node whose picture is the white-on-black mask of the clip's person ("person",
  // default) or main foreground thing ("subject"). Same box / fit / focus props as video(), so it lines up with the clip.
  function cutout(src, props) {
    var n = mk("video", { src: src }, props);
    var kind = n.kind;
    if (kind === undefined || kind === null) kind = "person";
    delete n.kind;
    n.matte = kind;
    return n;
  }
  function text(str, props) {
    if (typeof str === "number") str = String(str);
    if (typeof str !== "string")
      throw new Error("text(): the first argument must be a string (or a number), got " + describe(str) + ". Pass the words to draw, e.g. text(\"Hello\", { y: 100 }).");
    return mk("text", { text: str }, props);
  }

  // html(markup, { x, y, width, height, time }): a web layer (HTML / CSS / SVG / canvas / WebGL drawn by a sealed
  // WebKit page, composited like any other node). See "Web layer" in API.md.
  function html(markup, props) {
    if (typeof markup !== "string")
      throw new Error("html(): the first argument must be a string of HTML markup, got " + describe(markup) + ". Pass the page to draw, e.g. html(\"<h1>Hello</h1>\", { width: 800, height: 300 }).");
    return mk("html", { html: markup }, props);
  }

  // ---------- shape helpers: all return path(...) nodes ----------
  function num3(v) { return String(Math.round(v * 1000) / 1000); }
  // [[x, y], ...] or [{ x, y }, ...] to [[x, y], ...]
  function toPoints(points, who) {
    if (!Array.isArray(points))
      throw new Error(who + "(): points must be an array of [x, y] or { x, y }, got " + describe(points));
    return points.map(function (p, i) {
      var x, y;
      if (Array.isArray(p)) { x = p[0]; y = p[1]; } else if (isObj(p)) { x = p.x; y = p.y; }
      if (typeof x !== "number" || typeof y !== "number")
        throw new Error(who + "(): point " + i + " must be [x, y] or { x, y } with numbers, got " + brief(p));
      return [x, y];
    });
  }
  function line(x1, y1, x2, y2, props) {
    return path("M" + num3(x1) + " " + num3(y1) + "L" + num3(x2) + " " + num3(y2), props);
  }
  function pointsD(pts, close) {
    var d = "";
    for (var i = 0; i < pts.length; i++) d += (i === 0 ? "M" : "L") + num3(pts[i][0]) + " " + num3(pts[i][1]);
    return close && pts.length ? d + "Z" : d;
  }
  function polyline(points, props) { return path(pointsD(toPoints(points, "polyline"), false), props); }
  function polygon(points, props) { return path(pointsD(toPoints(points, "polygon"), true), props); }
  // A star with n points, the first one straight up; innerR is the radius of the notches.
  function star(cx, cy, n, outerR, innerR, props) {
    var pts = [], k = Math.max(2, Math.round(n));
    for (var i = 0; i < k * 2; i++) {
      var a = -Math.PI / 2 + i * Math.PI / k, r = i % 2 === 0 ? outerR : innerR;
      pts.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]);
    }
    return path(pointsD(pts, true), props);
  }
  // An open arc of the circle (cx, cy, r). Degrees run clockwise on screen from 3 o'clock (0 = right, 90 = down); an end
  // below the start runs the other way. At most one full turn.
  function arc(cx, cy, r, startDeg, endDeg, props) {
    var sweep = clamp(endDeg - startDeg, -360, 360);
    var segs = Math.max(1, Math.ceil(Math.abs(sweep) / 90)), step = sweep / segs * Math.PI / 180;
    var k = 4 / 3 * Math.tan(step / 4), a = startDeg * Math.PI / 180;
    var d = "M" + num3(cx + r * Math.cos(a)) + " " + num3(cy + r * Math.sin(a));
    for (var i = 0; i < segs; i++) {
      var b = a + step, c1 = Math.cos(a), s1 = Math.sin(a), c2 = Math.cos(b), s2 = Math.sin(b);
      d += "C" + num3(cx + r * (c1 - k * s1)) + " " + num3(cy + r * (s1 + k * c1)) + " " +
           num3(cx + r * (c2 + k * s2)) + " " + num3(cy + r * (s2 - k * c2)) + " " +
           num3(cx + r * c2) + " " + num3(cy + r * s2);
      a = b;
    }
    return path(d, props);
  }
  // A heart `size` px wide, centred on (cx, cy).
  function heart(cx, cy, size, props) {
    var s = size / 2, oy = cy - 0.11 * s;
    function P(x, y) { return num3(cx + x * s) + " " + num3(oy + y * s); }
    var d = "M" + P(0, -0.35) + "C" + P(0, -0.85) + " " + P(-1, -0.85) + " " + P(-1, -0.3) +
            "C" + P(-1, 0.25) + " " + P(-0.35, 0.55) + " " + P(0, 0.95) +
            "C" + P(0.35, 0.55) + " " + P(1, 0.25) + " " + P(1, -0.3) +
            "C" + P(1, -0.85) + " " + P(0, -0.85) + " " + P(0, -0.35) + "Z";
    return path(d, props);
  }
  // A smooth curve through the points (Catmull-Rom turned into cubic Beziers); closed = true joins the end to the start.
  function smoothPath(points, props, closed) {
    var p = toPoints(points, "smoothPath"), n = p.length;
    if (n === 0) return path("", props);
    if (n === 1) return path("M" + num3(p[0][0]) + " " + num3(p[0][1]), props);
    function at(i) {
      if (closed) return p[((i % n) + n) % n];
      return p[Math.min(n - 1, Math.max(0, i))];
    }
    var d = "M" + num3(p[0][0]) + " " + num3(p[0][1]), segs = closed ? n : n - 1;
    for (var i = 0; i < segs; i++) {
      var p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2);
      d += "C" + num3(p1[0] + (p2[0] - p0[0]) / 6) + " " + num3(p1[1] + (p2[1] - p0[1]) / 6) + " " +
           num3(p2[0] - (p3[0] - p1[0]) / 6) + " " + num3(p2[1] - (p3[1] - p1[1]) / 6) + " " +
           num3(p2[0]) + " " + num3(p2[1]);
    }
    return path(closed ? d + "Z" : d, props);
  }
  // The points, each moved by up to `amount` px in x and y, the same way for the same seed (hand-drawn look).
  function wobble(points, amount, seed) {
    var s = seed === undefined ? 0 : seed;
    return toPoints(points, "wobble").map(function (p, i) {
      return [p[0] + (random(s + ":x" + i) * 2 - 1) * amount, p[1] + (random(s + ":y" + i) * 2 - 1) * amount];
    });
  }

  // layoutText(string, props): one { char, index, line, x, y, width, height } per character, from the same CoreText layout
  // text() draws with. Needs the host (__motionLayoutText); the props are checked like a text node's.
  function layoutText(str, props) {
    var n = normNode(text(str, props), { n: 0 }, 0, -1);
    trailType.length = 0; trailIdx.length = 0;
    if (n.type !== "text") return [];
    return JSON.parse(hostLayout(JSON.stringify(n)));
  }

  // ---------- frame normalisation and validation ----------
  // normNode copies a node into plain data and checks it on the way: every known prop must have the right type, and
  // a problem is reported with a readable path ("root > group[2] > rect[14]"). Rule for non-finite numbers: a
  // non-finite (NaN, Infinity) geometry value makes the node draw nothing; opacity NaN is ignored and opacity is
  // clamped to 0...1; video time Infinity holds the last frame and NaN the first; any other non-finite number is
  // dropped (the default applies).
  var NODE_TYPES = ["group", "solid", "rect", "ellipse", "path", "gradient", "image", "video", "text", "html"];
  var K_NUM = 1, K_STR = 2, K_TRANSFORM = 3, K_CLIP = 4, K_MASK = 5, K_EFFECTS = 6, K_CHILDREN = 7,
      K_STOPS = 8, K_POINT = 9, K_SHADOW = 10, K_NUMS = 11, K_TRIM = 12, K_FILL = 13, K_BOOL = 14;
  var COMMON = { opacity: K_NUM, transform: K_TRANSFORM, blend: K_STR, mask: K_MASK, maskMode: K_STR, clip: K_CLIP, effects: K_EFFECTS };
  var BOX = { x: K_NUM, y: K_NUM, width: K_NUM, height: K_NUM };
  var SPEC_OWN = {
    group: { children: K_CHILDREN },
    solid: { color: K_STR },
    rect: { x: K_NUM, y: K_NUM, width: K_NUM, height: K_NUM, color: K_STR, radius: K_NUM, stroke: K_STR, strokeWidth: K_NUM,
            lineCap: K_STR, lineJoin: K_STR, dash: K_NUMS, dashOffset: K_NUM, trim: K_TRIM, fill: K_FILL },
    ellipse: { x: K_NUM, y: K_NUM, width: K_NUM, height: K_NUM, color: K_STR, radius: K_NUM, stroke: K_STR, strokeWidth: K_NUM,
               lineCap: K_STR, lineJoin: K_STR, dash: K_NUMS, dashOffset: K_NUM, trim: K_TRIM, fill: K_FILL },
    path: { d: K_STR, color: K_STR, stroke: K_STR, strokeWidth: K_NUM,
            lineCap: K_STR, lineJoin: K_STR, dash: K_NUMS, dashOffset: K_NUM, trim: K_TRIM, fill: K_FILL },
    gradient: { stops: K_STOPS, kind: K_STR, from: K_POINT, to: K_POINT, x: K_NUM, y: K_NUM, width: K_NUM, height: K_NUM },
    image: { src: K_STR, x: K_NUM, y: K_NUM, width: K_NUM, height: K_NUM, fit: K_STR, focusX: K_NUM, focusY: K_NUM },
    video: { src: K_STR, time: K_NUM, x: K_NUM, y: K_NUM, width: K_NUM, height: K_NUM, fit: K_STR, focusX: K_NUM, focusY: K_NUM, matte: K_STR },
    text: { text: K_STR, x: K_NUM, y: K_NUM, width: K_NUM, font: K_STR, size: K_NUM, weight: K_NUM, color: K_STR, align: K_STR,
            lineHeight: K_NUM, letterSpacing: K_NUM, stroke: K_STR, strokeWidth: K_NUM, shadow: K_SHADOW,
            fill: K_FILL, italic: K_BOOL },
    html: { html: K_STR, x: K_NUM, y: K_NUM, width: K_NUM, height: K_NUM, time: K_NUM }
  };
  var SPEC = {};
  NODE_TYPES.forEach(function (t) {
    var o = {}, k;
    for (k in COMMON) o[k] = COMMON[k];
    for (k in SPEC_OWN[t]) o[k] = SPEC_OWN[t][k];
    SPEC[t] = o;
  });
  var REQUIRED = { solid: "color", path: "d", gradient: "stops", image: "src", video: "src", text: "text", html: "html" };
  var GEOM = { x: 1, y: 1, width: 1, height: 1, radius: 1, size: 1, strokeWidth: 1 };
  var TRANSFORM_KEYS = ["translateX", "translateY", "scale", "scaleX", "scaleY", "rotate", "originX", "originY",
                        "skewX", "skewY", "rotateX", "rotateY", "perspective"];
  var EFFECT_NUM = ["amount", "radius", "angle", "x", "y", "seed", "levels", "spacing", "wavelength", "phase", "slices", "scale"];
  var EFFECT_STR = ["color", "dark", "light", "axis"];
  var HIDDEN = { type: "group", children: [] };

  // Where we are in the tree, for error messages: parallel stacks of node type and index (-1 = no index).
  var trailType = [], trailIdx = [];
  function trailString() {
    var s = "root";
    for (var i = 0; i < trailType.length; i++) {
      var part = trailType[i] + (trailIdx[i] >= 0 ? "[" + trailIdx[i] + "]" : "");
      if (part) s += " > " + part;
    }
    return s;
  }
  function bad(msg) { throw new Error(msg + " (at " + trailString() + ")"); }
  function describe(v) {
    if (v === null) return "null";
    if (v === undefined) return "undefined";
    if (Array.isArray(v)) return "array";
    return typeof v;
  }
  function brief(v) {
    var s = fmt(v);
    return s.length > 60 ? s.slice(0, 57) + "..." : s;
  }
  function isObj(v) { return v !== null && typeof v === "object"; }
  function isUnset(v) { return v === undefined || v === null || typeof v === "function"; }

  function flatten(v, out, depth) {
    if (depth > 64) throw new Error("nodes are nested too deeply");
    if (v === null || v === undefined || v === false) return out;
    if (Array.isArray(v)) { for (var i = 0; i < v.length; i++) flatten(v[i], out, depth + 1); return out; }
    out.push(v);
    return out;
  }
  // Copies plain data; non-finite numbers are dropped from objects and become 0 inside arrays.
  function clean(v, depth) {
    if (depth > 64) throw new Error("value is nested too deeply");
    if (Array.isArray(v)) {
      return v.map(function (e) {
        if (typeof e === "number") return isFinite(e) ? e : 0;
        return isObj(e) ? clean(e, depth + 1) : (typeof e === "function" ? null : e);
      });
    }
    var o = {};
    var keys = Object.keys(v);
    for (var i = 0; i < keys.length; i++) {
      var val = v[keys[i]];
      if (val === undefined || typeof val === "function") continue;
      if (typeof val === "number") { if (isFinite(val)) o[keys[i]] = val; }
      else o[keys[i]] = isObj(val) ? clean(val, depth + 1) : val;
    }
    return o;
  }
  function plainObject(v, what) {
    if (!isObj(v) || Array.isArray(v)) bad(what + " must be an object, got " + describe(v));
  }
  // Reads one numeric field of a helper object (transform, clip, point...). Returns false when it is non-finite geometry.
  function numField(obj, key, label, out, geometry) {
    var v = obj[key];
    if (isUnset(v)) return true;
    if (typeof v !== "number") bad(label + " must be a number, got " + describe(v));
    if (!isFinite(v)) return !geometry;
    out[key] = v;
    return true;
  }
  function checkTransform(t, out) {
    plainObject(t, "transform");
    var o = {}, ok = true, i;
    for (i = 0; i < TRANSFORM_KEYS.length; i++) if (!numField(t, TRANSFORM_KEYS[i], "transform." + TRANSFORM_KEYS[i], o, true)) ok = false;
    out.transform = o;
    return ok;
  }
  function checkClip(c, out) {
    plainObject(c, "clip");
    var req = ["x", "y", "width", "height"], o = {}, ok = true, i;
    for (i = 0; i < 4; i++) {
      if (isUnset(c[req[i]])) bad('clip is missing "' + req[i] + '" (a clip is { x, y, width, height, radius? } in canvas pixels)');
      if (!numField(c, req[i], "clip." + req[i], o, true)) ok = false;
    }
    if (!numField(c, "radius", "clip.radius", o, true)) ok = false;
    out.clip = o;
    return ok;
  }
  function checkPoint(p, name, out, label) {
    label = label || name;
    plainObject(p, label);
    var o = {}, ok = true;
    ["x", "y"].forEach(function (k) {
      if (isUnset(p[k])) bad(label + ' is missing "' + k + '" (a point is { x, y } in canvas pixels)');
      if (!numField(p, k, label + "." + k, o, true)) ok = false;
    });
    out[name] = o;
    return ok;
  }
  function checkStops(stops, out, what) {
    what = what || "gradient stops";
    if (!Array.isArray(stops)) bad(what + " must be an array of { at, color }, got " + describe(stops));
    if (stops.length === 0) bad(what + ' is empty; give at least one stop { at: 0...1, color: "#rrggbb" }');
    var res = [];
    for (var i = 0; i < stops.length; i++) {
      var st = stops[i], label = what + "[" + i + "]";
      if (!isObj(st) || Array.isArray(st)) bad(label + " must be an object { at, color }, got " + describe(st));
      if (isUnset(st.at)) bad(label + ' is missing "at" (a number 0...1)');
      if (isUnset(st.color)) bad(label + ' is missing "color"');
      if (typeof st.at !== "number") bad(label + ".at must be a number, got " + describe(st.at));
      if (!isFinite(st.at)) bad(label + ".at must be a finite number, got " + st.at);
      if (typeof st.color !== "string") bad(label + ".color must be a string, got " + describe(st.color));
      res.push({ at: st.at, color: st.color });
    }
    out.stops = res;
  }
  function checkShadow(sh, out) {
    plainObject(sh, "shadow");
    var o = {};
    if (!isUnset(sh.color)) {
      if (typeof sh.color !== "string") bad("shadow.color must be a string, got " + describe(sh.color));
      o.color = sh.color;
    }
    ["blur", "x", "y"].forEach(function (k) { numField(sh, k, "shadow." + k, o, false); });
    out.shadow = o;
  }
  // dash: [on, off, ...] in px
  function checkNums(v, name, out) {
    if (!Array.isArray(v)) bad(name + " must be an array of numbers, got " + describe(v));
    var res = [];
    for (var i = 0; i < v.length; i++) {
      if (typeof v[i] !== "number") bad(name + "[" + i + "] must be a number, got " + describe(v[i]));
      res.push(isFinite(v[i]) ? v[i] : -1);   // a non-finite entry makes the whole dash invalid, so the stroke stays solid
    }
    out[name.split(".").pop()] = res;
  }
  // trim: { start, end }, fractions 0...1 of the outline
  function checkTrim(t, type, out) {
    plainObject(t, type + ".trim");
    var o = {};
    numField(t, "start", type + ".trim.start", o, false);
    numField(t, "end", type + ".trim.end", o, false);
    out.trim = o;
  }
  // fill: a gradient object { kind, stops, from, to } (same meaning as the gradient node)
  function checkFill(f, type, out) {
    var what = type + ".fill";
    plainObject(f, what);
    var o = {}, ok = true;
    if (!isUnset(f.kind)) {
      if (typeof f.kind !== "string") bad(what + ".kind must be a string, got " + describe(f.kind));
      o.kind = f.kind;
    }
    if (isUnset(f.stops)) bad(what + ' is missing "stops" (a fill is { kind, stops: [{ at, color }], from, to })');
    var tmp = {};
    checkStops(f.stops, tmp, what + ".stops");
    o.stops = tmp.stops;
    ["from", "to"].forEach(function (k) {
      if (!isUnset(f[k]) && !checkPoint(f[k], k, o, what + "." + k)) ok = false;
    });
    out.fill = o;
    return ok;
  }
  function checkEffects(fx, out) {
    if (!Array.isArray(fx)) bad("effects must be an array of { name, ... }, got " + describe(fx));
    var res = [];
    for (var i = 0; i < fx.length; i++) {
      var e = fx[i], label = "effects[" + i + "]";
      if (!isObj(e) || Array.isArray(e)) bad(label + " must be an object { name, ... }, got " + describe(e));
      if (isUnset(e.name)) bad(label + ' is missing "name" (e.g. { name: "blur", radius: 8 })');
      if (typeof e.name !== "string") bad(label + ".name must be a string, got " + describe(e.name));
      for (var j = 0; j < EFFECT_NUM.length; j++) {
        var pv = e[EFFECT_NUM[j]];
        if (!isUnset(pv) && typeof pv !== "number") bad(label + "." + EFFECT_NUM[j] + " must be a number, got " + describe(pv));
      }
      for (var sj = 0; sj < EFFECT_STR.length; sj++) {
        var sv = e[EFFECT_STR[sj]];
        if (!isUnset(sv) && typeof sv !== "string") bad(label + "." + EFFECT_STR[sj] + " must be a string, got " + describe(sv));
      }
      if (!isUnset(e.matrix)) {
        if (!Array.isArray(e.matrix)) bad(label + ".matrix must be an array of 20 numbers, got " + describe(e.matrix));
        for (var m = 0; m < e.matrix.length; m++)
          if (typeof e.matrix[m] !== "number") bad(label + ".matrix[" + m + "] must be a number, got " + describe(e.matrix[m]));
      }
      res.push(clean(e, 0));
    }
    out.effects = res;
  }

  function normList(v, counter, depth, tag) {
    var list = flatten(v, [], 0), res = new Array(list.length);
    if (tag) { trailType.push(tag); trailIdx.push(-1); }
    for (var i = 0; i < list.length; i++) res[i] = normNode(list[i], counter, depth + 1, i);
    if (tag) { trailType.pop(); trailIdx.pop(); }
    return res;
  }

  function normNode(n, counter, depth, idx) {
    if (depth > 64) throw new Error("nodes are nested too deeply");
    if (!isObj(n) || Array.isArray(n)) {
      trailType.push(""); trailIdx.push(idx);
      bad("render returned something that is not a node: " + brief(n) + ". A node comes from group(), solid(), rect(), ellipse(), path(), gradient(), image(), video() or text()");
    }
    var type = n.type;
    trailType.push(typeof type === "string" ? type : ""); trailIdx.push(idx);
    if (typeof type !== "string")
      bad('render returned an object that is not a node (it has no string "type"): ' + brief(n));
    var spec = SPEC.hasOwnProperty(type) ? SPEC[type] : null;
    if (spec === null) bad('unknown node type "' + type + '"; valid types: ' + NODE_TYPES.join(", "));
    if (++counter.n > MAX_NODES) throw new Error("a frame may hold at most " + MAX_NODES + " nodes");
    var out = { type: type }, hidden = false;
    var keys = Object.keys(n);
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i], val = n[key];
      if (key === "type" || isUnset(val)) continue;
      var kind = spec[key];
      switch (kind) {
        case K_NUM:
          if (typeof val !== "number") bad(type + "." + key + " must be a number, got " + describe(val));
          if (isFinite(val)) { out[key] = key === "opacity" ? (val < 0 ? 0 : val > 1 ? 1 : val) : val; }
          else if (GEOM[key] === 1) hidden = true;
          else if (key === "opacity") { if (val === Infinity) out[key] = 1; else if (val === -Infinity) out[key] = 0; }
          else if (key === "time") { out[key] = val === Infinity ? Number.MAX_VALUE : 0; }
          break;
        case K_STR:
          if (key === "matte" && val !== "person" && val !== "subject")
            bad('cutout kind must be "person" or "subject", got ' + (typeof val === "string" ? '"' + val + '"' : brief(val)));
          if (typeof val !== "string") bad(type + "." + key + " must be a string, got " + describe(val));
          out[key] = val;
          break;
        case K_TRANSFORM: if (!checkTransform(val, out)) hidden = true; break;
        case K_CLIP: if (!checkClip(val, out)) hidden = true; break;
        case K_MASK:
          if (!isObj(val)) bad("mask must be a node or array of nodes, got " + describe(val));
          out.mask = normList(val, counter, depth, "mask");
          break;
        case K_EFFECTS: checkEffects(val, out); break;
        case K_CHILDREN:
          if (!isObj(val)) bad(type + ".children must be a node or an array of nodes, got " + describe(val));
          out.children = normList(val, counter, depth, null);
          break;
        case K_STOPS: checkStops(val, out); break;
        case K_POINT: if (!checkPoint(val, key, out)) hidden = true; break;
        case K_SHADOW: checkShadow(val, out); break;
        case K_NUMS: checkNums(val, type + "." + key, out); break;
        case K_TRIM: checkTrim(val, type, out); break;
        case K_FILL: if (!checkFill(val, type, out)) hidden = true; break;
        case K_BOOL:
          if (typeof val !== "boolean") bad(type + "." + key + " must be true or false, got " + describe(val));
          out[key] = val;
          break;
        default:   // not a known prop: copied as plain data
          if (typeof val === "number") { if (isFinite(val)) out[key] = val; }
          else out[key] = isObj(val) ? clean(val, 0) : val;
      }
    }
    var req = REQUIRED[type];
    if (req !== undefined && out[req] === undefined) bad(type + ' is missing "' + req + '"' + (req === "src" ? " (the asset id)" : ""));
    trailType.pop(); trailIdx.pop();
    return hidden ? HIDDEN : out;
  }

  function renderFrame(frame) {
    var cfg = registered.config;
    rng = mulberry32((Math.imul(frame, 2654435761) ^ 0x9e3779b9) >>> 0);
    nowMs = Math.round(frame * 1000 / cfg.fps);
    var ctx = {
      frame: frame, fps: cfg.fps, width: cfg.width, height: cfg.height,
      durationInFrames: cfg.durationInFrames, time: frame / cfg.fps
    };
    var result = registered.render(frame, ctx);
    var counter = { n: 0 };
    var root;
    trailType.length = 0; trailIdx.length = 0;
    if (Array.isArray(result)) {
      root = { type: "group", children: normList(result, counter, 0, null) };
    } else if (result === null || result === undefined || result === false) {
      root = { type: "group", children: [] };
    } else {
      root = normNode(result, counter, 0, -1);
    }
    return JSON.stringify(root);
  }

  // ---------- composition config ----------
  function configFail(msg) { throw new Error("invalid composition config: " + msg); }
  function intField(c, name, lo, hi, even) {
    var v = c[name];
    var rule = (even ? "an even integer " : "an integer ") + lo + "..." + hi;
    if (v === undefined || v === null) configFail(name + " is required; it must be " + rule);
    if (typeof v !== "number")
      configFail(name + " must be a number, got " + describe(v) + (typeof v === "string" ? ' "' + v + '"' : "") + " (rule: " + rule + ")");
    if (!isFinite(v) || Math.floor(v) !== v)
      configFail(name + " must be an integer, got " + v + " (rule: " + rule + ")");
    if (v < lo || v > hi) configFail(name + " must be in " + lo + "..." + hi + ", got " + v + " (rule: " + rule + ")");
    if (even && v % 2 !== 0)
      configFail(name + " must be an even number, got " + v + " (odd sizes are an error, not rounded; use " + (v - 1) + " or " + (v + 1) + ")");
  }
  function checkConfig(c) {
    intField(c, "width", 16, 4096, true);
    intField(c, "height", 16, 4096, true);
    intField(c, "fps", 1, 120, false);
    intField(c, "durationInFrames", 1, 36000, false);
    if (!isUnset(c.background) && typeof c.background !== "string")
      configFail("background must be a string (a colour), got " + describe(c.background));
    if (!isUnset(c.audio)) {
      if (!Array.isArray(c.audio)) configFail("audio must be an array of clips { src, ... }, got " + describe(c.audio));
      c.audio.forEach(function (a, i) {
        var label = "audio[" + i + "]";
        if (!isObj(a) || Array.isArray(a)) configFail(label + " must be an object { src, ... }, got " + describe(a));
        if (isUnset(a.src)) configFail(label + ' is missing "src" (an asset id)');
        if (typeof a.src !== "string") configFail(label + ".src must be a string (an asset id), got " + describe(a.src));
        ["startFrame", "durationInFrames"].forEach(function (k) {
          var v = a[k];
          if (isUnset(v)) return;
          if (typeof v !== "number" || !isFinite(v) || Math.floor(v) !== v)
            configFail(label + "." + k + " must be an integer number of frames, got " + (typeof v === "number" ? v : describe(v)));
          if (v < 0) configFail(label + "." + k + " must not be negative, got " + v);
        });
        ["offset", "volume", "fadeIn", "fadeOut"].forEach(function (k) {
          var v = a[k];
          if (isUnset(v)) return;
          if (typeof v !== "number" || !isFinite(v)) configFail(label + "." + k + " must be a finite number, got " + (typeof v === "number" ? v : describe(v)));
        });
      });
    }
  }

  function composition(config, render) {
    registrations++;
    if (registrations > 1) throw new Error("composition() must be called exactly once");
    if (!isObj(config) || Array.isArray(config)) throw new TypeError("composition: the first argument must be a config object");
    if (typeof render !== "function") throw new TypeError("composition: the second argument must be a render function");
    checkConfig(config);
    registered = { config: config, render: render };
  }

  var api = {
    composition: composition, group: group, solid: solid, rect: rect, ellipse: ellipse, path: path,
    gradient: gradient, image: image, video: video, cutout: cutout, text: text,
    line: line, polyline: polyline, polygon: polygon, star: star, arc: arc, heart: heart, smoothPath: smoothPath, wobble: wobble,
    layoutText: layoutText, html: html,
    interpolate: interpolate, Easing: Easing, spring: spring, clamp: clamp, lerp: lerp, mix: mix,
    random: random, noise: noise, sequence: sequence, series: series,
    secondsToFrames: secondsToFrames, framesToSeconds: framesToSeconds
  };
  Object.keys(api).forEach(function (k) {
    Object.defineProperty(global, k, { value: api[k], writable: true, configurable: true, enumerable: false });
  });

  // Host hooks (read by the Swift side, not part of the authoring API).
  Object.defineProperty(global, "__motion", {
    value: Object.freeze({
      registrations: function () { return registrations; },
      configJSON: function () { return registered ? JSON.stringify(registered.config) : null; },
      frame: function (n) { return renderFrame(n); }
    }),
    writable: false, configurable: false, enumerable: false
  });
})(this);
