// Engraved Pepe oval. drawOval() returns a 1640x2000 canvas: the framed oval on a transparent ground.
const PAL = { ivory: "#F7F5EF", ink: "#16202E", green: "#2F5D50", oxblood: "#8C2F2F", hair: "#D8D3C7" };
const OW = 1640, OH = 2000, OCX = 820, OCY = 1000, IRX = 715, IRY = 880; // inner portrait ellipse

function mk(w, h) { const c = document.createElement("canvas"); c.width = w; c.height = h; return c; }

function p2(d) { return new Path2D(d); }
const P = {
  head: p2("M410,960 C380,820 470,705 600,695 C700,688 770,730 800,790 C850,720 960,672 1090,672 C1250,672 1350,790 1335,935 C1350,1060 1330,1160 1285,1250 C1225,1370 1050,1450 800,1448 C580,1446 440,1370 400,1220 C375,1120 395,1040 410,960 Z"),
  // Upper lids are built by eyes(): openness 1 is the delivered portrait, 0 is closed (the upper lid
  // lies on the lower one). setEyes() rewrites these four entries; drawOval() renders whatever is set.
  eyeL: null, eyeR: null, lidL: null, lidR: null,
  lowL: p2("M430,945 Q590,1040 730,935"),
  lowR: p2("M880,935 Q1110,1030 1310,905"),
  upLip: p2("M420,1175 C600,1150 1000,1150 1290,1128 L1285,1170 C1000,1240 650,1245 430,1215 Z"),
  loLip: p2("M430,1215 C650,1245 1000,1240 1285,1170 C1250,1262 1050,1335 800,1330 C600,1325 480,1285 430,1215 Z"),
  mouth: p2("M430,1215 C650,1245 1000,1240 1292,1160"),
  smile: p2("M1285,1170 C1305,1160 1318,1140 1322,1118"),
  lipTop: p2("M420,1175 C600,1150 1000,1150 1290,1128"),
  coat: p2("M170,2000 C200,1720 420,1480 640,1395 L1000,1395 C1220,1480 1440,1720 1470,2000 Z"),
  cravat: p2("M640,1395 C690,1480 730,1570 745,1720 L900,1720 C915,1570 955,1480 1000,1395 Z"),
};

// Openness interpolates each upper-lid control point toward its lower-lid one, so a closed lid is the
// lower curve: the aperture's area goes to zero and the skin engraving covers the eye.
function setEyes(open) {
  const lerp = (a, b) => a + (b - a) * (1 - open);
  const L = [lerp(580, 590), lerp(895, 1040)], R = [lerp(1095, 1110), lerp(875, 1030)];
  P.eyeL = p2(`M430,945 Q${L[0]},${L[1]} 730,935 Q590,1040 430,945 Z`);
  P.eyeR = p2(`M880,935 Q${R[0]},${R[1]} 1310,905 Q1110,1030 880,935 Z`);
  P.lidL = p2(`M430,945 Q${L[0]},${L[1]} 730,935`);
  P.lidR = p2(`M880,935 Q${R[0]},${R[1]} 1310,905`);
}
setEyes(1);

// Where he looks: 0 is the delivered side-eye, 1 is straight at the viewer (pupils centred in each
// aperture and a touch larger, so the stare reads at a distance). Used for the video's last beat.
let LOOK = 0;
function setLook(k) { LOOK = k; }
function pupils() {
  const m = (a, b) => a + (b - a) * LOOK;
  return [[m(545, 588), m(950, 952), m(58, 62)], [m(1000, 1092), m(940, 940), m(66, 71)]];
}

function tonePass(tc, rc) {
  const t = tc.getContext("2d"), r = rc.getContext("2d");
  const g = (v) => `rgb(${Math.round(255 * v)},${Math.round(255 * v)},${Math.round(255 * v)})`;
  // background: darker toward the edge, lighter halo behind the head
  t.fillStyle = g(0.5); t.fillRect(0, 0, OW, OH);
  let gr = t.createRadialGradient(820, 1000, 300, 820, 1000, 950);
  gr.addColorStop(0, g(0.28)); gr.addColorStop(1, g(0.78));
  t.fillStyle = gr; t.fillRect(0, 0, OW, OH);
  r.fillStyle = "rgb(0,0,0)"; r.fillRect(0, 0, OW, OH);
  const reg = (path, id) => { r.fillStyle = `rgb(${id * 20},0,0)`; r.fill(path); };

  // coat
  t.fillStyle = g(0.74); t.fill(P.coat); reg(P.coat, 4);
  t.save(); t.clip(P.coat); t.filter = "blur(30px)";
  t.strokeStyle = g(0.98); t.lineWidth = 90;
  t.beginPath(); t.moveTo(640, 1400); t.bezierCurveTo(520, 1560, 420, 1760, 400, 2000); t.stroke();
  t.beginPath(); t.moveTo(1000, 1400); t.bezierCurveTo(1120, 1560, 1220, 1760, 1240, 2000); t.stroke();
  t.restore();
  // cravat
  t.fillStyle = g(0.14); t.fill(P.cravat); reg(P.cravat, 5);
  // head
  t.fillStyle = g(0.27); t.fill(P.head); reg(P.head, 1);
  t.save(); t.clip(P.head);
  t.filter = "blur(60px)";
  // rim darkening
  t.strokeStyle = g(0.7); t.lineWidth = 80; t.stroke(P.head);
  t.globalCompositeOperation = "lighter";
  t.filter = "blur(90px)";
  // right-side form shadow (light from upper left)
  let lg = t.createLinearGradient(500, 0, 1350, 0);
  lg.addColorStop(0, g(0)); lg.addColorStop(1, g(0.22));
  t.fillStyle = lg; t.fillRect(300, 600, 1100, 900);
  // brow shadows under the domes
  t.filter = "blur(26px)"; t.strokeStyle = g(0.5); t.lineWidth = 60;
  t.save(); t.translate(0, -34); t.stroke(P.lidL); t.stroke(P.lidR); t.restore();
  // cheek / mouth-corner shadow, under-lip shadow
  t.strokeStyle = g(0.45); t.lineWidth = 50;
  t.beginPath(); t.moveTo(470, 1350); t.bezierCurveTo(700, 1395, 1000, 1390, 1180, 1300); t.stroke();
  t.restore();
  // highlight on the forehead domes, jowl
  t.save(); t.clip(P.head); t.filter = "blur(40px)";
  t.globalCompositeOperation = "source-over";
  t.fillStyle = g(0.12);
  t.beginPath(); t.ellipse(580, 770, 90, 36, -0.15, 0, 7); t.fill();
  t.beginPath(); t.ellipse(1070, 745, 110, 36, -0.1, 0, 7); t.fill();
  t.fillStyle = g(0.18);
  t.beginPath(); t.ellipse(790, 1380, 220, 36, 0, 0, 7); t.fill();
  t.restore();
  // eyes: whites (shadowed just under the lid)
  for (const [e, lid] of [[P.eyeL, P.lidL], [P.eyeR, P.lidR]]) {
    t.save(); t.clip(e); t.fillStyle = g(0.04); t.fillRect(0, 0, OW, OH);
    t.filter = "blur(14px)"; t.strokeStyle = g(0.62); t.lineWidth = 36; t.stroke(lid);
    t.restore();
    reg(e, 2);
  }
  // lips
  t.fillStyle = g(0.52); t.fill(P.upLip); reg(P.upLip, 3);
  t.fillStyle = g(0.4); t.fill(P.loLip); reg(P.loLip, 3);
  t.save(); t.clip(P.loLip); t.filter = "blur(24px)"; t.fillStyle = g(0.3);
  t.beginPath(); t.ellipse(850, 1285, 200, 22, 0.02, 0, 7); t.fill(); t.restore();
}

// Variable-width line engraving: parallel lines whose width follows the tone map.
function hatch(ctx, tone, region, o) {
  const W = tone.width, H = tone.height;
  const td = tone.getContext("2d").getImageData(0, 0, W, H).data;
  const rd = region.getContext("2d").getImageData(0, 0, W, H).data;
  const a = (o.angle * Math.PI) / 180, dx = Math.cos(a), dy = Math.sin(a), nx = -dy, ny = dx;
  const diag = Math.hypot(W, H), cx = W / 2, cy = H / 2, step = o.step || 2;
  const ids = o.ids.map((i) => i * 20);
  const path = new Path2D();
  for (let off = -diag / 2; off < diag / 2; off += o.sp) {
    let run = [];
    const flush = () => {
      if (run.length > 2) {
        const L = [], R = [];
        for (const [x, y, w] of run) { L.push([x + (nx * w) / 2, y + (ny * w) / 2]); R.push([x - (nx * w) / 2, y - (ny * w) / 2]); }
        path.moveTo(L[0][0], L[0][1]);
        for (const q of L) path.lineTo(q[0], q[1]);
        for (let i = R.length - 1; i >= 0; i--) path.lineTo(R[i][0], R[i][1]);
        path.closePath();
      }
      run = [];
    };
    for (let s = -diag / 2; s < diag / 2; s += step) {
      let x = cx + dx * s + nx * off, y = cy + dy * s + ny * off;
      if (o.warp) { const [wx, wy] = o.warp(x, y); x += wx; y += wy; }
      const xi = Math.round(x), yi = Math.round(y);
      if (xi < 0 || yi < 0 || xi >= W || yi >= H) { flush(); continue; }
      const k = (yi * W + xi) * 4, id = rd[k];
      let ok = false;
      for (const i of ids) if (Math.abs(id - i) < 7) ok = true;
      const t = td[k] / 255;
      if (!ok || t <= o.min) { flush(); continue; }
      const w = o.sp * o.k * Math.pow((t - o.min) / (1 - o.min), o.gamma);
      if (w < 0.45) { flush(); continue; }
      run.push([x, y, w]);
    }
    flush();
  }
  ctx.fillStyle = o.color; ctx.fill(path);
}

function engravePass(ctx, tc, rc) {
  const warpHead = (x, y) => [0, -Math.pow((x - 820) / 700, 2) * 70 + Math.sin(x / 90) * 2];
  // background ruling, ink
  hatch(ctx, tc, rc, { ids: [0], angle: 0, sp: 10, k: 0.85, min: 0.1, gamma: 1.0, color: PAL.ink });
  // skin: green undertint lines + ink shading + cross-hatch
  hatch(ctx, tc, rc, { ids: [1], angle: -6, sp: 7, k: 0.95, min: 0.04, gamma: 0.7, color: PAL.green, warp: warpHead });
  hatch(ctx, tc, rc, { ids: [1], angle: 38, sp: 7, k: 0.8, min: 0.34, gamma: 1.0, color: PAL.ink });
  hatch(ctx, tc, rc, { ids: [1], angle: 112, sp: 7, k: 0.7, min: 0.58, gamma: 1.0, color: PAL.ink });
  // lips
  hatch(ctx, tc, rc, { ids: [3], angle: 4, sp: 6, k: 0.85, min: 0.05, gamma: 0.9, color: PAL.ink });
  hatch(ctx, tc, rc, { ids: [3], angle: 70, sp: 6, k: 0.6, min: 0.6, gamma: 1.0, color: PAL.ink });
  // eyes: shading under lids
  hatch(ctx, tc, rc, { ids: [2], angle: 0, sp: 5, k: 0.8, min: 0.2, gamma: 1.0, color: PAL.ink });
  // cravat
  hatch(ctx, tc, rc, { ids: [5], angle: 80, sp: 9, k: 0.8, min: 0.06, gamma: 1.0, color: PAL.green });
  // coat
  hatch(ctx, tc, rc, { ids: [4], angle: 58, sp: 8, k: 0.9, min: 0.1, gamma: 0.8, color: PAL.ink });
  hatch(ctx, tc, rc, { ids: [4], angle: -20, sp: 8, k: 0.8, min: 0.55, gamma: 1.0, color: PAL.ink });
  hatch(ctx, tc, rc, { ids: [4], angle: 4, sp: 8, k: 0.6, min: 0.05, gamma: 1.0, color: PAL.green });
}

function lineworkPass(c) {
  c.lineCap = "round"; c.lineJoin = "round"; c.strokeStyle = PAL.ink;
  // keylines in ivory first so the contour reads clean against hatching
  const S = (p, w, col) => { c.strokeStyle = col; c.lineWidth = w; c.stroke(p); };
  S(P.head, 16, PAL.ivory); S(P.head, 8, PAL.ink);
  c.save(); c.translate(0, 0); c.scale(1, 1);
  // second, inner contour of the head (double-cut line)
  c.restore();
  for (const p of [P.eyeL, P.eyeR]) { S(p, 5, PAL.ink); }
  S(P.lidL, 11, PAL.ink); S(P.lidR, 11, PAL.ink);
  S(P.lowL, 6, PAL.ink); S(P.lowR, 6, PAL.ink);
  S(P.upLip, 5, PAL.ink); S(P.loLip, 5, PAL.ink);
  S(P.mouth, 10, PAL.ink); S(P.smile, 7, PAL.ink); S(P.lipTop, 8, PAL.ink);
  // pupils (clipped by the lid), with a paper highlight
  const pupil = (e, x, y, r) => {
    c.save(); c.clip(e);
    c.fillStyle = PAL.ink; c.beginPath(); c.arc(x, y, r, 0, 7); c.fill();
    c.fillStyle = PAL.ivory; c.beginPath(); c.arc(x + r * 0.32, y - r * 0.05, r * 0.2, 0, 7); c.fill();
    c.restore();
  };
  const [l, r] = pupils();
  pupil(P.eyeL, ...l); pupil(P.eyeR, ...r);
  // re-stroke lids over pupils
  S(P.lidL, 11, PAL.ink); S(P.lidR, 11, PAL.ink);
  // nostrils
  c.fillStyle = PAL.ink;
  for (const [x, y] of [[690, 1055], [860, 1050]]) { c.beginPath(); c.ellipse(x, y, 11, 6, 0.1, 0, 7); c.fill(); }
  // cheek crease at mouth corner and under-lip fold
  c.lineWidth = 5;
  c.beginPath(); c.moveTo(1322, 1118); c.bezierCurveTo(1345, 1090, 1348, 1050, 1338, 1020); c.stroke();
  c.beginPath(); c.moveTo(500, 1318); c.bezierCurveTo(700, 1365, 1000, 1360, 1190, 1280); c.stroke();
  // coat + cravat
  S(P.coat, 9, PAL.ivory); S(P.coat, 6, PAL.ink);
  S(P.cravat, 7, PAL.ink);
  c.lineWidth = 4;
  for (let i = 0; i < 7; i++) { // cravat ruffle folds
    const y = 1450 + i * 40;
    c.beginPath(); c.moveTo(700 + i * 6, y); c.quadraticCurveTo(820, y + 34, 940 - i * 6, y); c.stroke();
  }
  c.lineWidth = 7;
  c.beginPath(); c.moveTo(640, 1395); c.bezierCurveTo(560, 1560, 470, 1780, 450, 2000); c.stroke();
  c.beginPath(); c.moveTo(1000, 1395); c.bezierCurveTo(1090, 1560, 1180, 1780, 1190, 2000); c.stroke();
}

function ovalFrame(c) {
  // woven lathe ring between the portrait and the outer rules
  const ring = (rx, ry, extra) => { c.beginPath(); c.ellipse(OCX, OCY, rx + extra, ry + extra, 0, 0, 7); };
  c.save();
  c.fillStyle = PAL.ivory; ring(IRX, IRY, 100); c.fill();
  c.restore();
  c.strokeStyle = PAL.green; c.lineWidth = 1.6;
  const strands = 10, lobes = 64;
  for (let j = 0; j < strands; j++) for (const sgn of [1, -1]) {
    c.beginPath();
    for (let i = 0; i <= 1440; i++) {
      const th = (i / 1440) * Math.PI * 2;
      const off = 54 + 30 * Math.sin(lobes * th * sgn + (j * Math.PI * 2) / strands * 1.0) ;
      const x = OCX + (IRX + off) * Math.cos(th), y = OCY + (IRY + off) * Math.sin(th);
      i ? c.lineTo(x, y) : c.moveTo(x, y);
    }
    c.stroke();
  }
  c.strokeStyle = PAL.ink;
  for (const [e, w] of [[8, 7], [28, 2.5], [96, 3], [108, 8]]) { c.lineWidth = w; ring(IRX, IRY, e); c.stroke(); }
  c.strokeStyle = PAL.hair; c.lineWidth = 3; ring(IRX, IRY, 100); c.stroke();
}

function drawOval() {
  const out = mk(OW, OH), c = out.getContext("2d");
  const tc = mk(OW, OH), rc = mk(OW, OH);
  tonePass(tc, rc);
  const art = mk(OW, OH), a = art.getContext("2d");
  a.fillStyle = PAL.ivory; a.fillRect(0, 0, OW, OH);
  engravePass(a, tc, rc);
  lineworkPass(a);
  ovalFrame(c);
  c.save(); c.beginPath(); c.ellipse(OCX, OCY, IRX, IRY, 0, 0, 7); c.clip(); c.setTransform(1.25, 0, 0, 1.25, 820 - 820 * 1.25, 1030 - 1100 * 1.25); c.drawImage(art, 0, 0); c.restore();
  c.strokeStyle = PAL.ink; c.lineWidth = 7; c.beginPath(); c.ellipse(OCX, OCY, IRX + 8, IRY + 8, 0, 0, 7); c.stroke();
  return out;
}
