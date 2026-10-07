// infer.imdusd.com's backgrounds: what inference looks like, drawn on the site's printed stock (ruled
// paper, dotted leaders, a dot-grid sheet) in its two inks. Each scene moves in its own way. Drawn
// by the engine in ../vibe.tsx.
import type { Scene, Suite } from "../vibe";

export const INFER_SCENES: Scene[] = [
  {
    id: "network",
    label: "Network",
    icon: (
      <>
        <g fill="none" stroke="currentColor" strokeWidth="1.2">
          <path d="M7 7l10 4M7 12h10M7 17l10-4" />
          <circle cx="5" cy="6" r="2" />
          <circle cx="5" cy="12" r="2" />
          <circle cx="5" cy="18" r="2" />
          <circle cx="19" cy="12" r="2" />
        </g>
      </>
    ),
    // Layers of a network wired to the next, with signals running forward along the live weights
    // while the nodes bob in place: a forward pass, over and over.
    main: `
vec2 node(float c, float j, float sx) {
  float h = hash(vec2(c, j) + 0.37);
  return vec2((c + 0.5) * sx, (j + 0.5) / 6.0 + 0.035 * sin(uTime * 0.45 + h * 6.283));
}
float seg(vec2 p, vec2 a, vec2 b) {
  vec2 pa = p - a, ba = b - a;
  float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return length(pa - ba * h);
}
void main() {
  vec2 f = gl_FragCoord.xy;
  vec2 p = f / uRes.y;
  float t = uTime;
  float sx = (uRes.x / uRes.y) / 8.0;
  float c = floor(p.x / sx - 0.5);
  float px = 1.0 / uRes.y;
  float ink = 0.0;
  for (int j = 0; j < 6; j++) {
    for (int k = 0; k < 6; k++) {
      float h = hash(vec2(c * 7.0 + float(j), float(k) * 3.1 + c));
      if (h < 0.55) continue;
      vec2 a = node(c, float(j), sx), b = node(c + 1.0, float(k), sx);
      ink = max(ink, (1.0 - smoothstep(0.0, 1.2, seg(p, a, b) / px)) * 0.5);
      float s = fract(t * 0.2 + h * 9.0);
      float dp = length(p - mix(a, b, s)) / px;
      ink = max(ink, 1.0 - smoothstep(1.5, 3.0, dp));
    }
  }
  for (int j = 0; j < 6; j++) {
    for (int e = 0; e < 2; e++) {
      float d = length(p - node(c + float(e), float(j), sx)) / px;
      ink = max(ink, 1.0 - smoothstep(0.0, 1.2, abs(d - 5.0)));
    }
  }
  outColor = paint(ink * uInk1 * 1.2 * presence(f));
}`,
  },
  {
    id: "ledger",
    label: "Ledger",
    icon: (
      <>
        <g fill="none" stroke="currentColor" strokeWidth="1.2">
          <path d="M3 6h18M3 11h18M3 16h18M3 21h18M7 3v20M9 3v20" />
        </g>
      </>
    ),
    // Ruled ledger stock feeding up the page: a double margin, figure columns, and entries drawn as
    // dotted leaders running out to tick-mark figures.
    main: `
float vline(float x, float at) { return 1.0 - smoothstep(0.0, 1.1, abs(x - at)); }
void main() {
  vec2 f = gl_FragCoord.xy;
  float t = uTime;
  float rh = uRes.y / 30.0;
  float y = f.y / rh - t * 0.4;
  float row = floor(y), fy = fract(y);
  float x = f.x / uRes.x;
  float ink = lines(y, 1.0) * 0.8;
  float m = uRes.x * 0.08, gap = uRes.y * 0.004;
  ink = max(ink, max(vline(f.x, m), vline(f.x, m + gap)));
  ink = max(ink, max(vline(f.x, uRes.x * 0.72), vline(f.x, uRes.x * 0.86)) * 0.7);
  float live = step(0.3, hash(vec2(row, 7.0)));
  float start = 0.11 + 0.35 * hash(vec2(row, 3.0));
  float pitch = rh * 0.32;
  vec2 dd = vec2((fract(f.x / pitch) - 0.5) * pitch, (fy - 0.3) * rh);
  float dots = (1.0 - smoothstep(0.6, 1.6, length(dd))) * step(start, x) * step(x, 0.7);
  ink = max(ink, dots * live);
  float fig0 = 0.74 + 0.04 * hash(vec2(row, 5.0)), fig1 = 0.845;
  float tick = 1.0 - smoothstep(0.0, 1.1, abs((fract(f.x / (rh * 0.22)) - 0.5) * rh * 0.22));
  float fig = tick * step(fig0, x) * step(x, fig1) * step(0.22, fy) * step(fy, 0.62);
  ink = max(ink, fig * live * 0.9);
  outColor = paint(ink * uInk1 * presence(f));
}`,
  },
  {
    id: "tape",
    label: "Tape",
    icon: (
      <>
        <g fill="none" stroke="currentColor" strokeWidth="1.2">
          <path d="M2 6h20M2 18h20" />
          <circle cx="6" cy="10" r="1.6" />
          <circle cx="14" cy="10" r="1.6" />
          <circle cx="10" cy="14" r="1.6" />
          <circle cx="18" cy="14" r="1.6" />
          <circle cx="6" cy="14" r="0.6" fill="currentColor" />
          <circle cx="10" cy="10" r="0.6" fill="currentColor" />
          <circle cx="14" cy="14" r="0.6" fill="currentColor" />
          <circle cx="18" cy="10" r="0.6" fill="currentColor" />
        </g>
      </>
    ),
    // Punched paper tape, the oldest way a machine reads: bands of eight-track tape running past in
    // alternate directions, holes for ones, a small sprocket hole in every column.
    main: `
void main() {
  vec2 f = gl_FragCoord.xy;
  float t = uTime;
  float u = uRes.y / 90.0;
  float bandH = 11.0, period = 18.0;
  float Y = f.y / u;
  float band = floor(Y / period);
  float yb = Y - band * period;
  float ink = 0.0;
  if (yb < bandH) {
    float dir = mod(band, 2.0) < 1.0 ? 1.0 : -1.0;
    float speed = 1.4 + 1.2 * hash(vec2(band, 3.0));
    float X = f.x / u + dir * t * speed + band * 37.0;
    float col = floor(X);
    ink = max(ink, 1.0 - smoothstep(0.0, 1.1, min(yb, bandH - yb) * u));
    float tr = yb - 1.5;
    float ti = floor(tr + 0.5);
    if (ti >= 0.0 && ti <= 8.0) {
      float d = length(vec2(fract(X) - 0.5, tr - ti)) * u;
      if (ti == 3.0) {
        ink = max(ink, 1.0 - smoothstep(u * 0.13 - 0.7, u * 0.13 + 0.7, d));
      } else if (hash(vec2(col, ti + band * 11.0)) > 0.5) {
        ink = max(ink, (1.0 - smoothstep(u * 0.3 - 0.8, u * 0.3 + 0.8, d)) * 0.75);
      }
    }
  }
  outColor = paint(ink * uInk1 * presence(f));
}`,
  },
  {
    id: "attention",
    label: "Attention",
    icon: (
      <g fill="none" stroke="currentColor" strokeWidth="1.2">
        <path d="M2 19h20M3 19a5 5 0 0 1 10 0M7 19a7 7 0 0 1 14 0M14 19a2.5 2.5 0 0 1 5 0" />
      </g>
    ),
    // Lines of tokens streaming past, each reaching back to an earlier one with an arc whose weight
    // waxes and wanes, the way attention maps are drawn.
    main: `
void main() {
  vec2 f = gl_FragCoord.xy;
  float t = uTime;
  float T = uRes.y / 34.0;
  float H = uRes.y / 4.5;
  float band = floor(f.y / H);
  float by = f.y - band * H - H * 0.2;
  float dir = mod(band, 2.0) < 1.0 ? 1.0 : -1.0;
  float X = f.x / T + dir * t * 0.35 + band * 13.0;
  float ink = (1.0 - smoothstep(0.0, 1.1, abs(by))) * 0.6;
  float tick = 1.0 - smoothstep(0.0, 1.1, abs(fract(X) - 0.5) * T);
  ink = max(ink, tick * step(-T * 0.18, by) * step(by, 0.0) * 0.8);
  if (by > 0.0) {
    float i0 = floor(X);
    for (int k = -7; k <= 0; k++) {
      float i = i0 + float(k);
      float h = hash(vec2(i, band));
      float span = 1.0 + floor(h * 6.0);
      vec2 c = vec2((i + 0.5 + span * 0.5) * T, 0.0);
      float r = span * 0.5 * T;
      vec2 q = vec2(X * T, by);
      float d = abs(length(q - c) - r);
      float w = pow(0.5 + 0.5 * sin(t * 0.7 + h * 40.0), 3.0);
      ink = max(ink, (1.0 - smoothstep(0.0, 1.1, d)) * (0.2 + 0.9 * w));
    }
  }
  outColor = paint(ink * uInk1 * presence(f));
}`,
  },
  {
    id: "descent",
    label: "Descent",
    icon: (
      <g fill="none" stroke="currentColor" strokeWidth="1.2">
        <path d="M3 4c2 10 5 15 9 15s7-5 9-15" />
        <circle cx="4.6" cy="9" r="1.1" fill="currentColor" />
        <circle cx="6.6" cy="13.6" r="1.1" fill="currentColor" />
        <circle cx="9" cy="16.9" r="1.1" fill="currentColor" />
        <circle cx="12" cy="19" r="1.6" fill="currentColor" />
      </g>
    ),
    // A loss surface as a contour map, and runs of gradient descent dropped on its rim that step,
    // dot by dot, down to the minimum before the next run starts.
    main: `
float L(vec2 p) {
  p = rot(0.5 + 0.15 * sin(uTime * 0.05)) * p;
  return p.x * p.x * 0.6 + p.y * p.y * 2.2 + 0.12 * sin(3.0 * p.x + 1.0) * sin(2.5 * p.y);
}
vec2 grad(vec2 p) {
  float e = 0.002;
  return vec2(L(p + vec2(e, 0.0)) - L(p - vec2(e, 0.0)), L(p + vec2(0.0, e)) - L(p - vec2(0.0, e))) / (2.0 * e);
}
void main() {
  vec2 f = gl_FragCoord.xy;
  float t = uTime;
  vec2 p = (f - uCenter) / uScale;
  float px = 1.0 / uScale;
  float ink = lines(log(L(p) + 0.3) * 5.0, 1.0) * 0.75;
  for (int k = 0; k < 3; k++) {
    float ph = t / 12.0 + float(k) / 3.0;
    float run = floor(ph), u = fract(ph);
    float a = hash(vec2(run, float(k))) * 6.283;
    vec2 x = vec2(cos(a), sin(a)) * vec2(1.7, 0.95);
    float shown = u * 1.2 * 36.0;
    float fade = 1.0 - smoothstep(0.85, 1.0, u);
    for (int n = 0; n < 36; n++) {
      if (float(n) > shown) break;
      vec2 xn = x - 0.08 * grad(x);
      ink = max(ink, (1.0 - smoothstep(1.5, 3.0, length(p - x) / px)) * fade * 2.4);
      vec2 pa = p - x, ba = xn - x;
      float hh = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
      ink = max(ink, (1.0 - smoothstep(0.0, 1.1, length(pa - ba * hh) / px)) * fade * 1.4);
      x = xn;
    }
  }
  outColor = paint(ink * uInk1 * presence(f));
}`,
  },
  {
    id: "diffusion",
    label: "Diffusion",
    icon: (
      <>
        <g fill="currentColor">
          <circle cx="12" cy="4" r="1" />
          <circle cx="17.7" cy="6.3" r="1" />
          <circle cx="20" cy="12" r="1" />
          <circle cx="17.7" cy="17.7" r="1" />
          <circle cx="12" cy="20" r="1" />
          <circle cx="6.3" cy="17.7" r="1" />
          <circle cx="4" cy="12" r="1" />
          <circle cx="6.3" cy="6.3" r="1" />
          <circle cx="12" cy="12" r="1" />
          <circle cx="15" cy="9.5" r="1" />
          <circle cx="8.7" cy="14.5" r="1" />
        </g>
      </>
    ),
    // A stipple picture being generated: dots wander as noise, settle into a shaded sphere, hold it
    // for a moment, then dissolve back into noise.
    main: `
void main() {
  vec2 f = gl_FragCoord.xy;
  float t = uTime;
  float cell = uRes.y / 70.0;
  vec2 P = f / cell;
  vec2 id0 = floor(P);
  float sigma = smoothstep(0.15, 0.85, 0.5 + 0.5 * cos(t * 6.283 / 14.0));
  float ink = 0.0;
  for (int dy = -1; dy <= 1; dy++) {
    for (int dx = -1; dx <= 1; dx++) {
      vec2 id = id0 + vec2(float(dx), float(dy));
      vec2 jit = vec2(noise(id * 1.7 + vec2(t * 0.6, 0.0)), noise(id * 1.3 + vec2(5.0, t * 0.6))) - 0.5;
      vec2 c = id + 0.5 + jit * 1.8 * sigma;
      vec2 s = ((id + 0.5) * cell - uCenter) / uScale;
      float r2 = dot(s, s);
      float tone = 0.08;
      if (r2 < 1.0) {
        vec3 n = vec3(s, sqrt(1.0 - r2));
        tone = 0.15 + 0.85 * clamp(dot(n, normalize(vec3(-0.5, 0.6, 0.62))), 0.0, 1.0);
        tone = 1.0 - tone * 0.85;
      }
      float r = 0.46 * sqrt(mix(tone, 0.22, sigma));
      float d = length(P - c);
      ink = max(ink, 1.0 - smoothstep(r - 0.06, r + 0.06, d));
    }
  }
  outColor = paint(ink * uInk1 * 0.8 * presence(f));
}`,
  },
  {
    id: "softmax",
    label: "Softmax",
    icon: (
      <>
        <g fill="none" stroke="currentColor" strokeWidth="1.2">
          <path d="M2 20h20" />
          <rect x="4" y="14" width="3" height="6" />
          <rect x="15" y="11" width="3" height="9" />
          <rect x="9.5" y="5" width="3" height="15" fill="currentColor" />
        </g>
      </>
    ),
    // A sheet of small next-token distributions: the bars shift as the logits drift, and the most
    // likely token in each is inked solid.
    main: `
void main() {
  vec2 f = gl_FragCoord.xy;
  float t = uTime;
  vec2 cs = vec2(0.26, 0.17) * uRes.y;
  vec2 id = floor(f / cs);
  vec2 g = fract(f / cs);
  vec2 box = cs * vec2(0.8, 0.62);
  vec2 q = (g - vec2(0.1, 0.2)) * cs;
  float ink = 0.0;
  if (q.x > -2.0 && q.x < box.x + 2.0) ink = max(ink, 1.0 - smoothstep(0.0, 1.1, abs(q.y)));
  if (q.x >= 0.0 && q.x < box.x && q.y >= 0.0 && q.y < box.y) {
    float slot = box.x / 12.0;
    float b = floor(q.x / slot);
    float bx = q.x - b * slot;
    float seed = hash(id) * 50.0;
    float sum = 0.0, best = -1e9, mine = 0.0, arg = 0.0;
    for (int i = 0; i < 12; i++) {
      float l = 4.0 * noise(vec2(float(i) * 0.9 + seed, t * 0.4 + seed));
      float e = exp(l);
      sum += e;
      if (l > best) { best = l; arg = float(i); }
      if (float(i) == b) mine = e;
    }
    float top = min(mine / sum * 2.4, 1.0) * box.y;
    float l0 = slot * 0.18, r0 = slot * 0.82;
    bool inside = bx > l0 && bx < r0 && q.y < top;
    if (inside) {
      float e = min(min(bx - l0, r0 - bx), top - q.y);
      ink = max(ink, b == arg ? 0.9 : 1.0 - smoothstep(0.0, 1.1, e));
    }
  }
  outColor = paint(ink * uInk1 * presence(f));
}`,
  },
  {
    id: "sheet",
    label: "Sheet",
    icon: (
      <>
        <g fill="currentColor">
          <circle cx="5" cy="5" r="1" />
          <circle cx="5" cy="12" r="1" />
          <circle cx="5" cy="19" r="1" />
          <circle cx="12" cy="5" r="1" />
          <circle cx="12" cy="12" r="1.9" />
          <circle cx="12" cy="19" r="1" />
          <circle cx="19" cy="5" r="1" />
          <circle cx="19" cy="12" r="1" />
          <circle cx="19" cy="19" r="1" />
        </g>
        <circle
          cx="12"
          cy="12"
          r="5"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.2"
        />
      </>
    ),
    // The site's own dot-grid sheet, quickened: rings of activation spread from points across it,
    // swelling each dot as they pass.
    main: `
void main() {
  vec2 f = gl_FragCoord.xy;
  float t = uTime;
  float sp = uRes.y / 40.0;
  vec2 P = f / sp;
  vec2 c = floor(P) + 0.5;
  vec2 w = c * sp / uRes.y;
  float bump = 0.0;
  for (int k = 0; k < 4; k++) {
    float life = 7.0;
    float ph = t / life + float(k) * 0.25;
    float run = floor(ph), age = fract(ph);
    vec2 src = vec2(hash(vec2(run, float(k))) * uRes.x / uRes.y, hash(vec2(float(k), run + 3.0)));
    float d = length(w - src);
    float r = age * 0.9;
    bump += exp(-pow((d - r) / 0.045, 2.0)) * (1.0 - age);
  }
  float rad = sp * (0.07 + 0.2 * min(bump, 1.0));
  float d = length(P - c) * sp;
  float ink = 1.0 - smoothstep(rad - 1.0, rad + 1.0, d);
  outColor = paint(ink * uInk1 * 1.4 * presence(f));
}`,
  },
];

/** The suite: remembered apart from imdusd.com's, focused on the middle of the page. */
export const INFER_VIBES: Suite = {
  key: "infer-vibe",
  scenes: INFER_SCENES,
  focus: (wide) => (wide ? [0.5, 0.5, 0.42] : [0.5, 0.5, 0.46]),
};
