// Rasterizes web/public/icon.svg into the two maskable PNG icons the install manifest names.
import { chromium } from "../node_modules/playwright/index.mjs";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
const pub = resolve(import.meta.dirname, "../public");
const svg = await readFile(`${pub}/icon.svg`, "utf8");
const browser = await chromium.launch({ args: ["--no-sandbox"] });
for (const size of [192, 512]) {
  const page = await browser.newPage({ viewport: { width: size, height: size } });
  await page.setContent(`<body style="margin:0"><img width="${size}" height="${size}" src="data:image/svg+xml,${encodeURIComponent(svg)}"></body>`);
  await page.locator("img").screenshot({ path: `${pub}/icon-${size}.png` });
  await page.close();
}
await browser.close();
