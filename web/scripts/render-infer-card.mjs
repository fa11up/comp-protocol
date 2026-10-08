// Renders src/infer/buy-card.png, the still an X player card shows before play: the built /buy/ page at
// the player's 480 × 560, at 2× and in the light theme, with the live price and market cap hidden so the
// still never shows a figure that has since moved. Run after `npm run build:infer` (from a tree without
// launch.json, like every INFER build that ships), then rebuild so the new still is emitted.
import { chromium } from "../node_modules/playwright/index.mjs";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, resolve } from "node:path";

const dist = resolve(import.meta.dirname, "../../dist-infer");
const out = resolve(import.meta.dirname, "../src/infer/buy-card.png");
const TYPES = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".woff2": "font/woff2",
  ".webmanifest": "application/manifest+json",
};
const server = createServer(async (req, res) => {
  let path = decodeURIComponent(new URL(req.url, "http://x").pathname);
  if (path.endsWith("/")) path += "index.html";
  try {
    const body = await readFile(resolve(dist, `.${path}`));
    res.writeHead(200, { "content-type": TYPES[extname(path)] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404).end();
  }
}).listen(0);
const port = server.address().port;

const browser = await chromium.launch({ args: ["--no-sandbox", "--use-angle=swiftshader"] });
const page = await browser.newPage({
  viewport: { width: 480, height: 560 },
  deviceScaleFactor: 2,
  colorScheme: "light",
});
// No RPC is reachable from here, and none is wanted: the still carries no figure.
await page.route(/^https:\/\/(?!127\.0\.0\.1)/, (r) => r.abort());
await page.goto(`http://127.0.0.1:${port}/buy/`, { waitUntil: "networkidle" });
await page.addStyleTag({ content: ".infer-buy-price { visibility: hidden; }" });
await page.waitForTimeout(1500); // a few frames of the background
await page.screenshot({ path: out });
await browser.close();
server.close();
console.log(`render-infer-card: wrote ${out}`);
