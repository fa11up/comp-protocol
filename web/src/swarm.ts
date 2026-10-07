// A beeswarm: circles keep their exact x (a position's collateral ratio) and move up or down only as far as
// they must to stop overlapping, so a cluster of loans reads as a mass at its ratio instead of a staircase.
// The vertical offset carries no value. Pure, so it is unit-tested apart from the page.

export type Circle = { id: string; x: number; r: number };

/**
 * Vertical offsets (0 = the centre line) for circles placed in order, largest first, so the biggest debts sit
 * on the line and smaller ones settle around them. For each circle, the candidates are the centre and every
 * height at which it would just touch an already placed circle; it takes the one nearest the centre that
 * touches nothing. Deterministic: the same book always draws the same way.
 */
export function swarm(circles: Circle[], gap = 2): Map<string, number> {
  const order = [...circles].sort((a, b) => b.r - a.r || a.x - b.x || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  const placed: { x: number; y: number; r: number }[] = [];
  const out = new Map<string, number>();
  for (const c of order) {
    const clear = (y: number) =>
      placed.every((p) => (c.x - p.x) ** 2 + (y - p.y) ** 2 >= (c.r + p.r + gap) ** 2 - 1e-6);
    const candidates = [0];
    for (const p of placed) {
      const need = c.r + p.r + gap;
      const dx = Math.abs(c.x - p.x);
      if (dx >= need) continue;
      const dy = Math.sqrt(need * need - dx * dx);
      candidates.push(p.y + dy, p.y - dy);
    }
    candidates.sort((a, b) => Math.abs(a) - Math.abs(b) || a - b);
    const y = candidates.find(clear) ?? 0;
    placed.push({ x: c.x, y, r: c.r });
    out.set(c.id, y);
  }
  return out;
}

/** How far the swarm reaches above or below the centre line. */
export function extent(circles: Circle[], ys: Map<string, number>) {
  return circles.reduce((m, c) => Math.max(m, Math.abs(ys.get(c.id) ?? 0) + c.r), 0);
}

/** The smallest hit radius a circle is ever packed at: a 24px touch target (WCAG 2.5.8). */
export const HIT_RADIUS = 12;

export type Dot = { id: string; x: number; dot: number };

/**
 * Lay a book out: every circle keeps its x, its visible dot shrinks (down to 0.8^5 of its size) while the
 * cloud would outgrow `maxHeight`, but its HIT circle never shrinks below HIT_RADIUS, so no two touch
 * targets overlap and none is under 24px whatever the data. When the floor packing is taller than
 * `maxHeight` the plot takes the height it needs rather than clipping circles at its edge: a terminal's
 * pane scrolls, a clipped or overlapping target does not work. (An earlier version shrank the hit circle
 * with the dot and clipped at the cap, and a dense book at some ratios failed the target-size check.)
 */
export function pack(dots: Dot[], maxHeight: number, minHeight = 96) {
  let scale = 1;
  let circles: (Circle & { dot: number })[] = [];
  let ys = new Map<string, number>();
  for (let attempt = 0; attempt < 6; attempt++) {
    circles = dots.map((d) => ({ id: d.id, x: d.x, dot: d.dot * scale, r: Math.max(d.dot * scale, HIT_RADIUS) }));
    ys = swarm(circles);
    if (2 * extent(circles, ys) + HIT_RADIUS <= maxHeight) break;
    scale *= 0.8;
  }
  const height = Math.max(minHeight, Math.ceil(2 * extent(circles, ys) + HIT_RADIUS));
  return { circles, ys, height, scale };
}
