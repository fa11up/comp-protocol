// The disconnect box draws itself once per document: a soft page switch must show it already drawn.
// Serves the INFER build, connects a stand-in browser wallet (remembered, so it returns without a prompt),
// then moves Trade -> Claim -> Tokenomics -> Trade and counts the box's running draw animations each time.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve, extname } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const dir = resolve(fileURLToPath(new URL(".", import.meta.url)), "../../dist-infer");
const headers = await readFile(resolve(dir, "_headers"), "utf8");
const csp = headers.match(/Content-Security-Policy: (.*)/)[1];
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png", ".json": "application/json", ".woff2": "font/woff2" };
const server = createServer(async (req, res) => {
  const u = new URL(req.url, "http://x");
  let p = u.pathname.endsWith("/") ? u.pathname + "index.html" : u.pathname;
  let body, status = 200;
  try { body = await readFile(resolve(dir, "." + p)); }
  catch { try { body = await readFile(resolve(dir, "." + p + "/index.html")); p += "/index.html"; } catch { body = await readFile(resolve(dir, "404.html")); status = 404; p = "/404.html"; } }
  res.writeHead(status, { "content-type": types[extname(p)] ?? "application/octet-stream", "content-security-policy": csp });
  res.end(body);
}).listen(4391, "127.0.0.1");

let failed = 0;
const ok = (c, m) => { console.log(c ? "ok:" : "FAIL:", m); if (!c) failed++; };
const b = await chromium.launch();
const ctx = await b.newContext({ viewport: { width: 1280, height: 800 } });
await ctx.addInitScript(() => {
  localStorage.setItem("infer-wallet", "injected");
  const account = "0x000000000000000000000000000000000000c0de";
  window.ethereum = {
    request: async ({ method }) => {
      if (method === "eth_accounts" || method === "eth_requestAccounts") return [account];
      if (method === "eth_chainId") return "0x1";
      if (method === "net_version") return "1";
      throw Object.assign(new Error("not in this stand-in"), { code: 4200 });
    },
    on() {}, removeListener() {},
  };
});
const p = await ctx.newPage();
const state = () => p.evaluate(() => {
  const s = document.querySelector(".disconnect-slot");
  if (!s) return { cls: null, running: 0 };
  const running = s.getAnimations({ subtree: true }).filter((a) => a.playState === "running").length;
  return { cls: s.className, running };
});
await p.goto("http://127.0.0.1:4391/", { waitUntil: "networkidle" });
await p.waitForSelector(".disconnect-slot", { timeout: 10000 });
const first = await p.evaluate(() => document.querySelector(".disconnect-slot").className);
ok(first.includes("is-in"), `first load draws the box (${first})`);
await p.waitForTimeout(1200); // let the first drawing finish
const doc = await p.evaluate(() => (window.__doc = Math.random()));
for (const [name, path] of [["Claim", "/claim/"], ["Tokenomics", "/tokenomics/"], ["Trade", "/"]]) {
  await p.locator("header a", { hasText: new RegExp(`^\\s*${name}\\s*$`) }).first().click();
  await p.waitForURL((u) => u.pathname === path, { timeout: 5000 });
  await p.waitForSelector(".disconnect-slot", { timeout: 5000 });
  await p.waitForTimeout(60);
  const s = await state();
  const same = await p.evaluate((d) => window.__doc === d, doc);
  ok(same, `${name}: switched without a page load`);
  ok(s.cls.includes("is-shown") && s.running === 0, `${name}: the box is shown already drawn, nothing redrawing (${s.cls}, ${s.running} running)`);
}
await b.close();
server.close();
if (failed) { console.log(`${failed} failed`); process.exit(1); }
console.log("all passed");
