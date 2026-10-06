import { test } from "node:test";
import assert from "node:assert/strict";
import { swarm, extent } from "../src/swarm.ts";

// A seeded book of 200 loans clustered near the minimum ratio, the case that drew a staircase before.
function book(n, seed = 7) {
  let x = seed;
  const rand = () => ((x = (x * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
  return Array.from({ length: n }, (_, i) => ({
    id: `0x${i.toString(16).padStart(40, "0")}`,
    x: 120 + rand() * rand() * 500, // most near the left, a long tail to the right
    r: 12 + rand() * 10,
  }));
}

test("no two circles overlap, and none leaves its ratio", () => {
  const circles = book(200);
  const ys = swarm(circles);
  for (let i = 0; i < circles.length; i++)
    for (let j = i + 1; j < circles.length; j++) {
      const a = circles[i], b = circles[j];
      const d = Math.hypot(a.x - b.x, ys.get(a.id) - ys.get(b.id));
      assert.ok(d >= a.r + b.r + 2 - 1e-6, `${a.id} and ${b.id} overlap`);
    }
  assert.equal(ys.size, 200);
});

test("deterministic, and the biggest debt sits on the centre line", () => {
  const circles = book(50);
  assert.deepEqual([...swarm(circles)], [...swarm([...circles].reverse())]);
  const biggest = circles.reduce((m, c) => (c.r > m.r ? c : m));
  assert.equal(swarm(circles).get(biggest.id), 0);
});

test("spread-out loans stay on one line; a cluster stacks around it", () => {
  const apart = [0, 100, 200, 300].map((x, i) => ({ id: String(i), x, r: 12 }));
  assert.equal(extent(apart, swarm(apart)), 12, "no stacking needed");
  const together = [0, 1, 2, 3, 4].map((x, i) => ({ id: String(i), x, r: 12 }));
  const ys = swarm(together);
  assert.ok(extent(together, ys) > 12, "a cluster grows up and down");
  assert.ok([...ys.values()].some((y) => y > 0) && [...ys.values()].some((y) => y < 0), "both sides used");
});
