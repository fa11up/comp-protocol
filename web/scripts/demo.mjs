// Opens the built terminal in a real browser window against the test fixture: a mocked RPC,
// Blockscout and wallet, so every pane shows populated, wired-up data. Nothing touches a chain.
//   npm run build && npm run demo
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve, extname } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";
import {
  fixture,
  rpc,
  sent,
  installWallet,
  config,
  blockscout,
} from "../tests/fixture.mjs";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const types = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".webmanifest": "application/manifest+json",
};
const server = createServer(async (req, res) => {
  try {
    const pathname = new URL(req.url, "http://localhost").pathname;
    const suffix = decodeURIComponent(pathname.slice(1)) || "index.html";
    const path = resolve(root, "dist", suffix);
    if (!path.startsWith(resolve(root, "dist") + "/")) throw Error("path");
    res.setHeader(
      "Content-Type",
      types[extname(path)] || "application/octet-stream",
    );
    res.end(await readFile(path));
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const url = `http://127.0.0.1:${server.address().port}/`;

// The fixture as it would read once everything is live: attested work, backing just under par
// (so the redemption cap binds), question-pinned feeds and a pending governance change.
const s = Object.assign(fixture(), {
  mode: "attested",
  backing: (94n * 10n ** 18n) / 100n,
  pinned: true,
  reserve: 250n * 10n ** 18n,
  allowance: 10n ** 30n,
  pendingEta: BigInt(Math.floor(Date.now() / 1000)) + 7n * 3600n,
});

const browser = await chromium.launch({ headless: false });
const context = await browser.newContext({ viewport: null });
await context.route(/^https:\/\//, async (route) => {
  const request = route.request();
  if (request.url().startsWith("https://eth-sepolia.blockscout.com/api/v2/")) {
    await route.fulfill({
      json: blockscout(s, request.url()),
      headers: { "access-control-allow-origin": "*" },
    });
    return;
  }
  if (!config.network.rpcUrls.some((u) => request.url().startsWith(u))) {
    await route.abort();
    return;
  }
  const body = request.postDataJSON();
  await route.fulfill({
    json: Array.isArray(body) ? body.map((b) => rpc(s, b)) : rpc(s, body),
    headers: { "access-control-allow-origin": "*" },
  });
});
const page = await context.newPage();
await page.exposeFunction("__sendFixture", (tx) => sent(s, tx));
await installWallet(page, { chain: `0x${config.chainId.toString(16)}` });
await page.goto(url);
await page.getByRole("button", { name: "Connect wallet", exact: true }).click();
console.log(
  `Demo terminal open at ${url} (fixture data; close the window to stop).`,
);
browser.on("disconnected", () => {
  server.close();
  process.exit(0);
});
