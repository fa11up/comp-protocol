// The Note: flat master (3264x1400), then angled / square / sheet compositions. No lettering anywhere.
const NW = 3264, NH = 1400;

function rosette(c, cx, cy, R, o) {
  c.save(); c.beginPath(); c.arc(cx, cy, R + 10, 0, 7); c.fillStyle = PAL.ivory; c.fill(); c.clip();
  c.lineWidth = o.lw || 1.3;
  for (const [col, n, count, a, b, rr] of o.layers) {
    c.strokeStyle = col;
    for (let j = 0; j < count; j++) {
      c.beginPath();
      for (let i = 0; i <= 720; i++) {
        const th = (i / 720) * Math.PI * 2;
        const r = R * rr * (a + b * Math.cos(n * th + (j / count) * Math.PI * 2));
        const x = cx + r * Math.cos(th), y = cy + r * Math.sin(th);
        i ? c.lineTo(x, y) : c.moveTo(x, y);
      }
      c.stroke();
    }
  }
  c.restore();
  c.strokeStyle = PAL.ink;
  for (const [r, w] of [[R + 4, 5], [R - 12, 1.5], [R * 0.3, 3], [R * 0.3 - 8, 1.5]]) { c.lineWidth = w; c.beginPath(); c.arc(cx, cy, r, 0, 7); c.stroke(); }
}

// Guilloché lace: rotated copies of a hypotrochoid (the curve a geometric lathe cuts), in rings.
function lace(c, cx, cy, R, rings) {
  c.save(); c.beginPath(); c.arc(cx, cy, R + 10, 0, 7); c.fillStyle = PAL.ivory; c.fill(); c.clip();
  for (const { col, alpha, lw, inner, outer, lobes, copies, loop } of rings) {
    c.strokeStyle = col; c.globalAlpha = alpha ?? 1; c.lineWidth = lw;
    const mid = (inner + outer) / 2, amp = (outer - inner) / 2;
    for (let j = 0; j < copies; j++) {
      const ph = (j / copies) * (Math.PI * 2 / lobes);
      c.beginPath();
      for (let i = 0; i <= 2400; i++) {
        const t = (i / 2400) * Math.PI * 2;
        // a radius that swings between inner and outer `lobes` times, plus a small looping term
        const r = R * (mid + amp * Math.cos(lobes * t) + loop * Math.cos(lobes * 3 * t));
        const th = t + ph + loop * 0.9 * Math.sin(lobes * t);
        const x = cx + r * Math.cos(th), y = cy + r * Math.sin(th);
        i ? c.lineTo(x, y) : c.moveTo(x, y);
      }
      c.stroke();
    }
  }
  // petal outlines over the lattice, so the rosette reads as a flower at thumbnail size
  const petals = (n, r0, r1, col, w, rot = 0) => {
    c.strokeStyle = col; c.globalAlpha = 1; c.lineWidth = w; c.beginPath();
    for (let i = 0; i <= 1440; i++) {
      const th = (i / 1440) * Math.PI * 2, r = R * (r0 + (r1 - r0) * Math.abs(Math.cos((n / 2) * (th + rot))));
      const x = cx + r * Math.cos(th), y = cy + r * Math.sin(th); i ? c.lineTo(x, y) : c.moveTo(x, y);
    }
    c.stroke();
  };
  petals(12, 0.62, 0.97, PAL.green, 4);
  petals(12, 0.62, 0.97, PAL.ink, 1.5, Math.PI / 12);
  petals(9, 0.3, 0.5, PAL.ink, 3);
  petals(6, 0.08, 0.22, PAL.green, 3);
  c.restore();
  c.strokeStyle = PAL.ink; c.globalAlpha = 1;
  for (const [r, w] of [[R + 4, 5], [R - 12, 1.5]]) { c.lineWidth = w; c.beginPath(); c.arc(cx, cy, r, 0, 7); c.stroke(); }
}

function chamferPath(x, y, w, h, k) {
  const p = new Path2D();
  p.moveTo(x + k, y); p.lineTo(x + w - k, y); p.lineTo(x + w, y + k); p.lineTo(x + w, y + h - k); p.lineTo(x + w - k, y + h);
  p.lineTo(x + k, y + h); p.lineTo(x, y + h - k); p.lineTo(x, y + k); p.closePath();
  return p;
}

// Empty ornamental frame: lathe lattice ring around a blank ivory field.
function emptyFrame(c, x, y, w, h, k, ring) {
  c.save();
  c.fillStyle = PAL.ivory; c.fill(chamferPath(x, y, w, h, k));
  const inner = chamferPath(x + ring, y + ring, w - 2 * ring, h - 2 * ring, Math.max(k - ring * 0.6, 4));
  const outer = chamferPath(x, y, w, h, k);
  c.save();
  const rp = new Path2D(); rp.addPath(outer); rp.addPath(inner);
  c.clip(rp, "evenodd");
  c.strokeStyle = PAL.green; c.lineWidth = 1.2;
  for (const dir of [1, -1]) {
    for (let t = -h; t < w + h; t += 5) {
      c.beginPath();
      for (let s = 0; s <= h; s += 4) { const px = x + t + dir * s + 6 * Math.sin(s / 9 + t), py = y + s; s ? c.lineTo(px, py) : c.moveTo(px, py); }
      c.stroke();
    }
  }
  c.restore();
  c.strokeStyle = PAL.ink;
  c.lineWidth = 6; c.stroke(outer);
  c.lineWidth = 2; c.stroke(chamferPath(x + 11, y + 11, w - 22, h - 22, Math.max(k - 7, 4)));
  c.lineWidth = 4; c.stroke(inner);
  c.strokeStyle = PAL.hair; c.lineWidth = 2;
  c.stroke(chamferPath(x + ring + 9, y + ring + 9, w - 2 * ring - 18, h - 2 * ring - 18, Math.max(k - ring, 3)));
  c.restore();
}

function lathe(c, x, y, w, h, vertical) {
  c.save(); c.beginPath(); c.rect(x, y, w, h); c.clip();
  c.fillStyle = PAL.ivory; c.fillRect(x, y, w, h);
  const L = vertical ? h : w, T = vertical ? w : h;
  c.lineWidth = 1.2;
  for (const [col, ph] of [[PAL.green, 0], [PAL.ink, 1.57]]) {
    c.strokeStyle = col; c.globalAlpha = col === PAL.ink ? 0.55 : 1;
    for (let j = 0; j < 14; j++) for (const sg of [1, -1]) {
      c.beginPath();
      for (let s = 0; s <= L; s += 3) {
        const u = T / 2 + (T * 0.4) * Math.sin(s / 17 * sg + j * 0.45 + ph);
        vertical ? (s ? c.lineTo(x + u, y + s) : c.moveTo(x + u, y + s)) : (s ? c.lineTo(x + s, y + u) : c.moveTo(x + s, y + u));
      }
      c.stroke();
    }
  }
  c.restore();
}

function waveField(c, x0, y0, x1, y1) {
  c.save(); c.beginPath(); c.rect(x0, y0, x1 - x0, y1 - y0); c.clip();
  c.strokeStyle = PAL.hair; c.lineWidth = 1.3;
  for (let y = y0 - 40; y < y1 + 40; y += 7) {
    c.beginPath();
    for (let x = x0; x <= x1; x += 6) { const yy = y + 9 * Math.sin(x / 70 + y / 40) + 5 * Math.sin(x / 23 - y / 31); x === x0 ? c.moveTo(x, yy) : c.lineTo(x, yy); }
    c.stroke();
  }
  c.strokeStyle = PAL.green; c.globalAlpha = 0.28; c.lineWidth = 1;
  for (let y = y0 - 40; y < y1 + 40; y += 28) {
    c.beginPath();
    for (let x = x0; x <= x1; x += 6) { const yy = y + 12 * Math.sin(x / 90 + y / 33); x === x0 ? c.moveTo(x, yy) : c.lineTo(x, yy); }
    c.stroke();
  }
  c.restore();
}

function seal(c, cx, cy, R) {
  const sc = 28;
  c.save();
  c.fillStyle = PAL.ivory; c.beginPath(); c.arc(cx, cy, R + 14, 0, 7); c.fill();
  c.fillStyle = PAL.oxblood; c.beginPath();
  for (let i = 0; i <= sc * 16; i++) { const th = i / (sc * 16) * Math.PI * 2, r = R * (1 + 0.045 * Math.cos(sc * th)); const x = cx + r * Math.cos(th), y = cy + r * Math.sin(th); i ? c.lineTo(x, y) : c.moveTo(x, y); }
  c.fill();
  // engraved rings in ivory cut into the oxblood
  c.strokeStyle = PAL.ivory;
  for (const [r, w] of [[0.9, 3], [0.84, 1.4], [0.8, 1.4], [0.46, 3]]) { c.lineWidth = w; c.beginPath(); c.arc(cx, cy, R * r, 0, 7); c.stroke(); }
  c.lineWidth = 1.4;
  for (let j = 0; j < 36; j++) { c.beginPath(); for (let i = 0; i <= 360; i++) { const th = i / 360 * Math.PI * 2, r = R * (0.62 + 0.1 * Math.cos(18 * th + j * 0.17)); const x = cx + r * Math.cos(th), y = cy + r * Math.sin(th); i ? c.lineTo(x, y) : c.moveTo(x, y); } c.stroke(); }
  // empty centre disc for the lettering
  c.fillStyle = PAL.ivory; c.beginPath(); c.arc(cx, cy, R * 0.43, 0, 7); c.fill();
  c.strokeStyle = PAL.oxblood; c.lineWidth = 5; c.beginPath(); c.arc(cx, cy, R * 0.43, 0, 7); c.stroke();
  c.lineWidth = 1.5; c.beginPath(); c.arc(cx, cy, R * 0.39, 0, 7); c.stroke();
  c.restore();
}

function paperTexture(c) {
  let s = 12345; const rnd = () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296);
  c.save(); c.lineCap = "round";
  for (let i = 0; i < 9000; i++) {
    c.strokeStyle = PAL.hair; c.globalAlpha = 0.25 + rnd() * 0.35; c.lineWidth = 0.8 + rnd();
    const x = rnd() * NW, y = rnd() * NH, a = rnd() * 6.28, l = 6 + rnd() * 22;
    c.beginPath(); c.moveTo(x, y); c.quadraticCurveTo(x + Math.cos(a) * l * 0.5 + 3, y + Math.sin(a) * l * 0.5 - 3, x + Math.cos(a) * l, y + Math.sin(a) * l); c.stroke();
  }
  c.restore();
}

function drawNote(oval) {
  const cv = mk(NW, NH), c = cv.getContext("2d");
  c.fillStyle = PAL.ivory; c.fillRect(0, 0, NW, NH);
  paperTexture(c);
  const IN = 172;
  waveField(c, IN, IN, NW - IN, NH - IN);
  // outer border: rules + lathe band
  c.strokeStyle = PAL.ink; c.lineWidth = 7; c.strokeRect(34, 34, NW - 68, NH - 68);
  c.lineWidth = 2; c.strokeRect(50, 50, NW - 100, NH - 100);
  const B = 62, BT = 92;
  lathe(c, B + 0, B, NW - 2 * B, BT, false); lathe(c, B, NH - B - BT, NW - 2 * B, BT, false);
  lathe(c, B, B, BT, NH - 2 * B, true); lathe(c, NW - B - BT, B, BT, NH - 2 * B, true);
  c.strokeStyle = PAL.ink; c.lineWidth = 4; c.strokeRect(B, B, NW - 2 * B, NH - 2 * B);
  c.lineWidth = 4; c.strokeRect(B + BT, B + BT, NW - 2 * (B + BT), NH - 2 * (B + BT));
  c.strokeStyle = PAL.hair; c.lineWidth = 3; c.strokeRect(B + BT + 8, B + BT + 8, NW - 2 * (B + BT + 8), NH - 2 * (B + BT + 8));

  // left & right rosettes
  // left: a lathe-cut guilloché rosette. right: the treasury seal, in its own place (as on a real note,
  // where the seals sit either side of the portrait) instead of overlapping a second rosette.
  lace(c, 724, 700, 320, [
    { col: PAL.green, lw: 1.4, inner: 0.52, outer: 0.98, lobes: 12, copies: 16, loop: 0.03 },
    { col: PAL.ink, alpha: 0.7, lw: 0.9, inner: 0.22, outer: 0.5, lobes: 9, copies: 14, loop: 0.02 },
    { col: PAL.green, lw: 1, inner: 0.02, outer: 0.2, lobes: 6, copies: 10, loop: 0 },
  ]);
  // oval portrait, oversized, centred
  const sc = 924 / OH, ow = OW * sc;
  c.drawImage(oval, NW / 2 - ow / 2, 302, ow, 924);
  seal(c, 2540, 700, 280);
  // empty frames: banner, four cartouches, serial strips
  emptyFrame(c, 560, IN - 6, NW - 1120, 126, 30, 20);
  const cw = 330, ch = 250;
  for (const [x, y] of [[IN, IN - 6], [NW - IN - cw, IN - 6], [IN, NH - IN - ch + 6], [NW - IN - cw, NH - IN - ch + 6]]) emptyFrame(c, x, y, cw, ch, 44, 28);
  emptyFrame(c, 560, NH - IN - 70, 700, 76, 22, 14);
  emptyFrame(c, NW - 560 - 700 + 0, NH - IN - 70 + 0, 700, 76, 22, 14);
  if (!globalThis.NO_LETTERING) lettering(c);
  // edge
  c.strokeStyle = PAL.hair; c.lineWidth = 4; c.strokeRect(2, 2, NW - 4, NH - 4);
  return cv;
}

// Our lettering on the empty frames: the site's lockup in the banner, the denomination in the corners,
// green serial numbers, and the pixel I in the seal. Monospace, like imdusd.com.
const MONO = "'SFMono-Regular', Menlo, Consolas, 'Liberation Mono', monospace";
const MARK = [[5,4,7,1,1],[8,4,1,8,1],[5,11,7,1,1],[4,4,1,1,.5],[12,4,1,1,.5],[4,11,1,1,.5],[12,11,1,1,.5],[5,7,3,2,.5],[9,7,3,2,.5],[4,7,1,2,.25],[12,7,1,2,.25]];
function pixelMark(c, cx, cy, size, col) {
  const u = size / 16; c.save(); c.fillStyle = col;
  for (const [x, y, w, h, a] of MARK) { c.globalAlpha = a; c.fillRect(Math.round(cx - size / 2 + x * u), Math.round(cy - size / 2 + y * u), Math.ceil(w * u), Math.ceil(h * u)); }
  c.restore();
}
function lettering(c) {
  const IN = 172;
  c.save(); c.textBaseline = "middle"; c.fillStyle = PAL.ink;
  // banner: imd + bold USD, centred in the banner frame
  const by = IN - 6 + 63, bx = NW / 2, size = 104;
  c.font = `400 ${size}px ${MONO}`; const w1 = c.measureText("imd").width;
  c.font = `700 ${size}px ${MONO}`; const w2 = c.measureText("USD").width;
  const x0 = bx - (w1 + w2) / 2;
  c.font = `400 ${size}px ${MONO}`; c.textAlign = "left"; c.fillText("imd", x0, by + 10);
  c.font = `700 ${size}px ${MONO}`; c.fillText("USD", x0 + w1, by + 10);
  // denominations
  c.textAlign = "center"; c.font = `700 150px ${MONO}`;
  const cw = 330, ch = 250;
  for (const [x, y] of [[IN, IN - 6], [NW - IN - cw, IN - 6], [IN, NH - IN - ch + 6], [NW - IN - cw, NH - IN - ch + 6]]) c.fillText("1", x + cw / 2, y + ch / 2 + 8);
  // serial numbers, in engraved green as on a real note
  c.fillStyle = PAL.green; c.font = `700 44px ${MONO}`;
  for (const x of [560 + 350, NW - 560 - 350]) c.fillText("IMD 00000001 A", x, NH - IN - 70 + 38 + 2);
  c.restore();
  // the seal's centre carries the mark
  pixelMark(c, 2540, 700, 192, PAL.oxblood); // 192 = 12 px per mark pixel, so every edge lands on a whole pixel
}

// perspective: draw the flat note into a w x h canvas, projected by a homography
function solveH(src, dst) {
  const A = [], b = [];
  for (let i = 0; i < 4; i++) {
    const [x, y] = src[i], [u, v] = dst[i];
    A.push([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.push(u);
    A.push([0, 0, 0, x, y, 1, -v * x, -v * y]); b.push(v);
  }
  for (let i = 0; i < 8; i++) {
    let m = i; for (let r = i + 1; r < 8; r++) if (Math.abs(A[r][i]) > Math.abs(A[m][i])) m = r;
    [A[i], A[m]] = [A[m], A[i]]; [b[i], b[m]] = [b[m], b[i]];
    for (let r = 0; r < 8; r++) if (r !== i) { const f = A[r][i] / A[i][i]; for (let k = i; k < 8; k++) A[r][k] -= f * A[i][k]; b[r] -= f * b[i]; }
  }
  return b.map((v, i) => v / A[i][i]);
}

function angled(note, w, h, widthFrac) {
  const out = mk(w, h), c = out.getContext("2d");
  c.fillStyle = PAL.ink; c.fillRect(0, 0, w, h);
  // 3D: note plane rotated about Y (-24deg) and X (14deg), perspective camera
  const ry = -24 * Math.PI / 180, rx = 13 * Math.PI / 180, aspect = NH / NW;
  const pts = [[-0.5, -aspect / 2], [0.5, -aspect / 2], [0.5, aspect / 2], [-0.5, aspect / 2]].map(([x, y]) => {
    let X = x * Math.cos(ry), Z = -x * Math.sin(ry), Y = y;
    const Y2 = Y * Math.cos(rx) - Z * Math.sin(rx), Z2 = Y * Math.sin(rx) + Z * Math.cos(rx);
    const d = 2.4; return [X / (Z2 + d), Y2 / (Z2 + d)];
  });
  const minx = Math.min(...pts.map((p) => p[0])), maxx = Math.max(...pts.map((p) => p[0]));
  const miny = Math.min(...pts.map((p) => p[1])), maxy = Math.max(...pts.map((p) => p[1]));
  const s = (w * widthFrac) / (maxx - minx);
  const dst = pts.map(([x, y]) => [w / 2 + (x - (minx + maxx) / 2) * s, h / 2 + (y - (miny + maxy) / 2) * s]);
  const sw = Math.round(Math.min(NW, (Math.hypot(dst[1][0] - dst[0][0], dst[1][1] - dst[0][1]) * 1.6)));
  const sh = Math.round((sw * NH) / NW);
  const src = mk(sw, sh); src.getContext("2d").drawImage(note, 0, 0, sw, sh);
  const sd = src.getContext("2d").getImageData(0, 0, sw, sh).data;
  const H = solveH(dst, [[0, 0], [sw, 0], [sw, sh], [0, sh]]); // dst pixel -> src pixel
  const img = c.getImageData(0, 0, w, h), od = img.data;
  const SS = 2, ink = [0x16, 0x20, 0x2e];
  // raking light from the upper left: gentle falloff across the note
  const light = (u, v) => 1.035 - 0.15 * u + 0.03 * (1 - v) + 0.02 * Math.sin(u * 5 + v * 2) ;
  // soft contact shadow behind the note
  const shadowCv = mk(w, h), sc2 = shadowCv.getContext("2d");
  sc2.fillStyle = "#000"; sc2.beginPath(); dst.forEach(([x, y], i) => (i ? sc2.lineTo(x + 26, y + 34) : sc2.moveTo(x + 26, y + 34))); sc2.closePath(); sc2.filter = "blur(26px)"; sc2.fill();
  c.globalAlpha = 0.5; c.drawImage(shadowCv, 0, 0); c.globalAlpha = 1;
  const base = c.getImageData(0, 0, w, h).data;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let r = 0, g = 0, b = 0, cov = 0, u = 0, v = 0;
    for (let j = 0; j < SS; j++) for (let i = 0; i < SS; i++) {
      const X = x + (i + 0.5) / SS, Y = y + (j + 0.5) / SS;
      const dnm = H[6] * X + H[7] * Y + 1, sx = (H[0] * X + H[1] * Y + H[2]) / dnm, sy = (H[3] * X + H[4] * Y + H[5]) / dnm;
      if (sx < 0 || sy < 0 || sx >= sw - 1 || sy >= sh - 1) continue;
      const x0 = sx | 0, y0 = sy | 0, fx = sx - x0, fy = sy - y0, k = (y0 * sw + x0) * 4;
      for (let ch = 0; ch < 3; ch++) {
        const v00 = sd[k + ch], v10 = sd[k + 4 + ch], v01 = sd[k + sw * 4 + ch], v11 = sd[k + sw * 4 + 4 + ch];
        const val = v00 * (1 - fx) * (1 - fy) + v10 * fx * (1 - fy) + v01 * (1 - fx) * fy + v11 * fx * fy;
        if (ch === 0) r += val; else if (ch === 1) g += val; else b += val;
      }
      cov++; u += sx / sw; v += sy / sh;
    }
    if (!cov) continue;
    const k = (y * w + x) * 4, f = cov / (SS * SS), L = light(u / cov, v / cov);
    for (let ch = 0; ch < 3; ch++) {
      const val = Math.min(255, ([r, g, b][ch] / cov) * L);
      od[k + ch] = val * f + base[k + ch] * (1 - f);
    }
    od[k + 3] = 255;
  }
  c.putImageData(img, 0, 0);
  // faint raking sheen across the paper
  c.save(); c.beginPath(); dst.forEach(([x, y], i) => (i ? c.lineTo(x, y) : c.moveTo(x, y))); c.closePath(); c.clip();
  const lg = c.createLinearGradient(0, 0, w, h * 0.6);
  lg.addColorStop(0, "rgba(247,245,239,0.10)"); lg.addColorStop(0.5, "rgba(247,245,239,0)"); lg.addColorStop(1, "rgba(22,32,46,0.08)");
  c.fillStyle = lg; c.fillRect(0, 0, w, h); c.restore();
  return out;
}

function flat(note, w, h, widthFrac) {
  const out = mk(w, h), c = out.getContext("2d");
  c.fillStyle = PAL.ink; c.fillRect(0, 0, w, h);
  const nw = w * widthFrac, nh = (nw * NH) / NW;
  c.imageSmoothingQuality = "high";
  c.drawImage(note, (w - nw) / 2, (h - nh) / 2, nw, nh);
  return out;
}

function sheet(imgs) {
  const H = 420, gap = 44, widths = imgs.map((i) => Math.round((i.width * H) / i.height));
  const W = widths.reduce((a, b) => a + b, 0) + gap * (imgs.length + 1);
  const cv = mk(W, H + gap * 2), c = cv.getContext("2d");
  c.fillStyle = PAL.ink; c.fillRect(0, 0, W, cv.height);
  let x = gap; c.imageSmoothingQuality = "high";
  imgs.forEach((im, i) => { c.drawImage(im, x, gap, widths[i], H); c.strokeStyle = PAL.hair; c.lineWidth = 2; c.strokeRect(x, gap, widths[i], H); x += widths[i] + gap; });
  return cv;
}
