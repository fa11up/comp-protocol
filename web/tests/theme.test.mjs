import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
const css = await readFile(
  new URL("../src/style.css", import.meta.url),
  "utf8",
);
const blocks = [...css.matchAll(/:root[^{}]*\{([^}]+)\}/g)].map((m) => m[1]);
const colors = (block) =>
  Object.fromEntries(
    [...block.matchAll(/(--[a-z-]+):\s*(#[\da-f]+|transparent);/gi)].map(
      (m) => [m[1], m[2].toUpperCase()],
    ),
  );
const light = colors(blocks[0]),
  dark = colors(blocks[1]);
test("both themes define identical color roles and light uses exactly the seven approved hexes", () => {
  assert.deepEqual(Object.keys(light).sort(), Object.keys(dark).sort());
  assert.deepEqual(
    [...new Set(Object.values(light).filter((v) => v.startsWith("#")))].sort(),
    [
      "#F7F5EF",
      "#FFFDF8",
      "#16202E",
      "#5A6472",
      "#D8D3C7",
      "#2F5D50",
      "#8C2F2F",
    ].sort(),
  );
  assert.equal(dark["--bg"], "#111111");
  assert.equal(dark["--surface"], "#161616");
  assert.equal(dark["--text"], "#EEEEEE");
  assert.equal(dark["--muted"], "#A8A8A8");
  assert.equal(dark["--rule"], "#3A3A3A");
  assert.equal(dark["--raised"], "#202020");
});
test("component paint has no literal colors, gradients or missing custom properties", () => {
  const components = css.replace(/--[a-z-]+:\s*[^;]+;/g, "");
  assert.doesNotMatch(
    components,
    /#[\da-f]{3,8}\b|rgba?\(|hsla?\(|gradient\(|:\s*transparent/i,
  );
  const defined = new Set([...css.matchAll(/(--[a-z-]+):/g)].map((m) => m[1]));
  for (const [, token] of css.matchAll(/var\((--[a-z-]+)/g))
    assert.ok(defined.has(token), token);
});
