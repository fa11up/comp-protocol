// Renders layers.html in Playwright's Chromium and writes every "name<TAB>base64" line of #out to
// marketing/explainer/layers/<name>.png (geometry.json is written as JSON). Same harness as
// marketing/the-note/render.mjs. Run: node marketing/explainer/render.mjs [page.html] [outdir]
import { chromium } from "../../web/node_modules/playwright/index.mjs";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const here = import.meta.dirname;
const page = process.argv[2] ?? "layers.html";
const out = resolve(here, process.argv[3] ?? "layers");
mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ args: ["--allow-file-access-from-files"] });
const p = await browser.newPage();
p.on("pageerror", (e) => { console.error("page error:", e.message); process.exitCode = 1; });
await p.goto("file://" + resolve(here, page));
await p.waitForSelector("#out", { state: "attached", timeout: 600000 });
const text = await p.$eval("#out", (e) => e.textContent);
for (const line of text.split("\n")) {
  const [name, b64] = line.split("\t");
  if (!b64) continue;
  const file = name.endsWith(".json") ? name : name + ".png";
  writeFileSync(resolve(out, file), Buffer.from(b64, "base64"));
  console.log("wrote", file);
}
await browser.close();
