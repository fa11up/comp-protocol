// Renders build.html in Playwright's Chromium and writes each "name<TAB>base64" line of #out to
// marketing/kit/plates/<name>.png. Same output as run.sh, without needing google-chrome.
// Run: node marketing/the-note/render.mjs [build.html]
import { chromium } from "../../web/node_modules/playwright/index.mjs";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const here = import.meta.dirname;
const page = process.argv[2] ?? "build.html";
const out = resolve(here, "../kit/plates");
mkdirSync(out, { recursive: true });
const browser = await chromium.launch({ args: ["--allow-file-access-from-files"] });
const p = await browser.newPage();
await p.goto("file://" + resolve(here, page));
await p.waitForSelector("#out", { state: "attached", timeout: 600000 });
const text = await p.$eval("#out", (e) => e.textContent);
for (const line of text.split("\n")) {
  const [name, b64] = line.split("\t");
  if (!b64) continue;
  writeFileSync(resolve(out, name + ".png"), Buffer.from(b64, "base64"));
  console.log("wrote", name);
}
await browser.close();
