// imdusd.com's backgrounds: the crafts a banknote or a ledger is made with (guilloché, lathe work,
// contour maps, halftone, hatching), each with its own motion. Drawn by the engine in vibe.tsx.
import type { Scene, Suite } from "./vibe";

export const IMDUSD_SCENES: Scene[] = [
  {
    id: "rosette",
    label: "Rosette",
    icon: (
      <>
        <g fill="none" stroke="currentColor" strokeWidth="1.2">
          <circle cx="12" cy="9" r="4.5" />
          <circle cx="12" cy="15" r="4.5" />
          <circle cx="9" cy="12" r="4.5" />
          <circle cx="15" cy="12" r="4.5" />
        </g>
      </>
    ),
    // Two guilloché rosettes woven from opposite-phase line families, the way the lathe on a note
    // cuts them, turning slowly in opposite directions, with a scalloped frame between them.
    main: `
float rosette(vec2 p, float n, float k, float a, float turn, float rIn, float rOut) {
  float r = length(p);
  float th = atan(p.y, p.x) + turn;
  float wave = a * sin(k * th);
  float A = lines(r * n + wave, 1.0);
  float B = lines(r * n - wave, 1.0);
  float env = smoothstep(rIn, rIn + 0.08, r) * (1.0 - smoothstep(rOut - 0.1, rOut, r));
  return max(A, B) * env;
}
void main() {
  vec2 frag = gl_FragCoord.xy;
  vec2 p = (frag - uCenter) / uScale;
  float t = uTime;
  float outer = rosette(p, 14.0, 24.0, 3.2 + 0.35 * sin(t * 0.19), t * 0.012, 0.5, 1.0);
  float inner = rosette(p, 20.0, 9.0, 2.0, -t * 0.02, 0.1, 0.46);
  float r = length(p);
  float th = atan(p.y, p.x);
  float rim = lines((r - 0.48 - 0.012 * sin(48.0 * th - t * 0.05)) * 70.0, 1.0)
            * smoothstep(0.43, 0.46, r) * (1.0 - smoothstep(0.5, 0.53, r));
  vec2 q = frag / uRes.y;
  float field = lines(q.y * 120.0 + 2.2 * sin(q.x * 5.0 + t * 0.12) + 0.8 * sin(q.x * 13.0 - t * 0.07), 0.9);
  float ink = max(max(outer, rim) * uInk1, inner * uInk1 * 0.9);
  ink = max(ink, field * uInk1 * 0.3);
  outColor = paint(ink);
}`,
  },
  {
    id: "lathe",
    label: "Lathe",
    icon: (
      <>
        <g fill="none" stroke="currentColor" strokeWidth="1.2">
          <path d="M3 9c3-3 6 3 9 0s6-3 9 0M3 15c3-3 6 3 9 0s6-3 9 0" />
        </g>
      </>
    ),
    // Wavy lathe lines in two families a few degrees apart, rolling sideways as the angle between
    // them swings, so broad moiré bands sweep across the page.
    main: `
void main() {
  vec2 f = gl_FragCoord.xy;
  vec2 q = f / uRes.y;
  float t = uTime;
  float a = lines(q.y * 58.0 + 1.6 * sin(q.x * 3.2 + t * 0.45), 1.0);
  vec2 r = rot(0.035 + 0.02 * sin(t * 0.13)) * q;
  float b = lines(r.y * 60.0 + 1.6 * sin(r.x * 3.5 - t * 0.38 + 1.3), 1.0);
  outColor = paint(max(a, b) * uInk1 * presence(f));
}`,
  },
  {
    id: "topography",
    label: "Topography",
    icon: (
      <>
        <g fill="none" stroke="currentColor" strokeWidth="1.2">
          <path d="M4 13c0-5 5-8 9-7s7 4 6 8-6 6-10 5-5-3-5-6z" />
          <path d="M8 13c0-3 2-4 4-4s4 2 3 4-3 3-5 2-2-1-2-2z" />
        </g>
      </>
    ),
    // A survey map whose terrain is alive: the contours swell, split and merge as the land beneath
    // them is slowly folded, every fifth line heavier.
    main: `
void main() {
  vec2 f = gl_FragCoord.xy;
  vec2 p = f / uRes.y * 2.4;
  float t = uTime;
  vec2 warp = vec2(fbm(p + vec2(t * 0.06, 0.0)), fbm(p + vec2(5.2, -t * 0.05)));
  float h = fbm(p + 1.2 * warp + vec2(t * 0.02, 0.0));
  float minor = lines(h * 16.0, 1.0);
  float major = lines(h * 16.0 / 5.0, 1.8);
  outColor = paint(max(minor * 0.7, major) * uInk1 * presence(f));
}`,
  },
  {
    id: "tide",
    label: "Tide",
    icon: (
      <>
        <g fill="none" stroke="currentColor" strokeWidth="1.2">
          <circle cx="12" cy="12" r="2" />
          <circle cx="12" cy="12" r="5.5" />
          <circle cx="12" cy="12" r="9" />
        </g>
      </>
    ),
    // Rings spreading steadily outward from two points and crossing into a moving moiré, as from
    // drops falling in still water.
    main: `
void main() {
  vec2 f = gl_FragCoord.xy;
  vec2 p = f / uRes.y;
  float t = uTime;
  vec2 s1 = uCenter / uRes.y;
  vec2 s2 = s1 + vec2(-0.32, -0.22) * uScale / uRes.y * 1.6;
  float d1 = length(p - s1), d2 = length(p - s2);
  float a = lines(d1 * 55.0 - t * 0.6, 1.0) * (1.0 - smoothstep(0.15, 0.95, d1));
  float b = lines(d2 * 55.0 - t * 0.5, 1.0) * (1.0 - smoothstep(0.1, 0.8, d2));
  outColor = paint(max(a, b) * uInk1 * presence(f));
}`,
  },
  {
    id: "ridgelines",
    label: "Ridgelines",
    icon: (
      <>
        <g fill="none" stroke="currentColor" strokeWidth="1.2">
          <path d="M3 9h5l2-4 2 4h9M3 14h3l3-5 3 5 2-2 2 2h5M3 19h7l2-3 2 3h7" />
        </g>
      </>
    ),
    // Stacked hairlines lifted by a signal that scrolls past like a ticker tape, a market drawn as a
    // mountain range.
    main: `
void main() {
  vec2 f = gl_FragCoord.xy;
  vec2 q = f / uRes.y;
  float t = uTime;
  float N = 24.0;
  float k = floor(q.y * N);
  float px = fwidth(q.y);
  float across = f.x / uRes.x;
  float bump = smoothstep(0.0, 0.35, across) * (1.0 - smoothstep(0.85, 1.0, across)) * 0.7 + 0.3;
  float ink = 0.0;
  for (int j = -6; j <= 1; j++) {
    float row = k + float(j);
    float n = fbm(vec2(q.x * 2.6 + t * 0.12, row * 0.41));
    float h = row / N + pow(max(n - 0.28, 0.0), 1.4) * 0.55 * bump;
    ink = max(ink, 1.0 - smoothstep(0.0, px * 1.2, abs(q.y - h)));
  }
  outColor = paint(ink * uInk1 * 0.9 * presence(f));
}`,
  },
  {
    id: "halftone",
    label: "Halftone",
    icon: (
      <>
        <g fill="currentColor">
          <circle cx="6" cy="6" r="0.7" />
          <circle cx="12" cy="6" r="1.1" />
          <circle cx="18" cy="6" r="1.6" />
          <circle cx="6" cy="12" r="1.1" />
          <circle cx="12" cy="12" r="1.6" />
          <circle cx="18" cy="12" r="2.1" />
          <circle cx="6" cy="18" r="1.6" />
          <circle cx="12" cy="18" r="2.1" />
          <circle cx="18" cy="18" r="2.6" />
        </g>
      </>
    ),
    // A screened print whose tone drifts across the page in slow clouds, the dots swelling and
    // shrinking as it passes.
    main: `
void main() {
  vec2 f = gl_FragCoord.xy;
  float t = uTime;
  float cell = uRes.y / 80.0;
  vec2 p = rot(0.52) * f / cell;
  vec2 id = floor(p);
  vec2 g = fract(p) - 0.5;
  float tone = smoothstep(0.32, 0.78, fbm(id * 0.07 + vec2(t * 0.08, t * 0.05)));
  float r = 0.46 * sqrt(tone);
  float d = length(g);
  float aa = fwidth(d);
  float dotInk = 1.0 - smoothstep(r - aa, r + aa, d);
  outColor = paint(dotInk * uInk1 * 0.75 * presence(f));
}`,
  },
  {
    id: "hatch",
    label: "Hatch",
    icon: (
      <>
        <g fill="none" stroke="currentColor" strokeWidth="1.2">
          <rect x="4" y="4" width="16" height="16" />
          <path d="M4 12 12 4M4 20 20 4M12 20l8-8" />
        </g>
      </>
    ),
    // Engraver's shading moving over the page like weather: hatching, cross-hatching and a third
    // pass laid wherever the drifting cloud is darkest, while the strokes themselves creep.
    main: `
void main() {
  vec2 f = gl_FragCoord.xy;
  vec2 q = f / uRes.y;
  float t = uTime;
  float s = smoothstep(0.3, 0.8, fbm(q * 2.6 + vec2(t * 0.05, t * 0.02)));
  float h1 = lines((q.x + q.y) * 105.0 + t * 0.25, 0.9) * smoothstep(0.18, 0.28, s);
  float h2 = lines((q.x - q.y) * 105.0 - t * 0.2, 0.9) * smoothstep(0.45, 0.55, s);
  float h3 = lines(q.y * 148.0, 0.9) * smoothstep(0.72, 0.82, s);
  outColor = paint(max(max(h1, h2), h3) * uInk1 * 0.85 * presence(f));
}`,
  },
  {
    id: "grid",
    label: "Grid",
    icon: (
      <>
        <g fill="currentColor">
          <circle cx="5" cy="5" r="1.3" />
          <circle cx="5" cy="12" r="1.3" />
          <circle cx="5" cy="19" r="1.3" />
          <circle cx="12" cy="5" r="1.3" />
          <circle cx="12" cy="12" r="1.3" />
          <circle cx="12" cy="19" r="1.3" />
          <circle cx="19" cy="5" r="1.3" />
          <circle cx="19" cy="12" r="1.3" />
          <circle cx="19" cy="19" r="1.3" />
        </g>
      </>
    ),
    // The page's own dot grid with a pulse running through it: rings of displacement travel out
    // from the focus, as if the paper breathed.
    main: `
void main() {
  vec2 f = gl_FragCoord.xy;
  float t = uTime;
  float sp = uRes.y / 38.0;
  vec2 p = f / sp;
  vec2 c = uCenter / sp;
  vec2 dir = p - c;
  float dist = length(dir);
  p += normalize(dir + 1e-4) * 0.32 * sin(dist * 0.45 - t * 1.1) * smoothstep(0.0, 6.0, dist);
  vec2 g = fract(p) - 0.5;
  float d = length(g) * sp;
  float r = sp * 0.07;
  float dotInk = 1.0 - smoothstep(r - 1.0, r + 1.0, d);
  outColor = paint(dotInk * uInk1 * 1.6 * presence(f));
}`,
  },
];

/** The suite: remembered under its own key, focused behind the launch panel on wide screens. */
export const IMDUSD_VIBES: Suite = {
  key: "imdusd-vibe",
  scenes: IMDUSD_SCENES,
  // Wide screens: the focus sits behind the launch panel on the right. Narrow: in the middle.
  focus: (wide) => (wide ? [0.74, 0.69, 0.44] : [0.5, 0.55, 0.48]),
};
