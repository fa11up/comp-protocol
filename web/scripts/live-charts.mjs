// Read-only live browser smoke check; no injected wallet or transaction signing.
import { createServer } from "node:http";
import { readFile, writeFile } from "node:fs/promises";
import { resolve, extname } from "node:path";
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("../../", import.meta.url));
const server = createServer(async (req, res) => {
  try {
    const pathname = new URL(req.url, "http://localhost").pathname;
    if (!pathname.startsWith("/preview/")) throw Error("path");
    const path = resolve(root, "dist", pathname.slice(9) || "index.html");
    if (!path.startsWith(resolve(root, "dist") + "/")) throw Error("path");
    res.setHeader(
      "Content-Type",
      {
        ".html": "text/html",
        ".js": "text/javascript",
        ".json": "application/json",
        ".css": "text/css",
        ".svg": "image/svg+xml",
      }[extname(path)] || "application/octet-stream",
    );
    res.end(await readFile(path));
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const browser = await chromium.launch({
  headless: true,
  args: ["--no-sandbox"],
});
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
const failures = [],
  statuses = [],
  calls = [];
page.on("response", async (response) => {
  try {
    const req = response.request();
    const body = req.postDataJSON();
    if (body?.method === "eth_getCode" || body?.method === "eth_getLogs") {
      const value = await response.json();
      calls.push({
        method: body.method,
        params: body.params,
        result:
          typeof value.result === "string"
            ? { codeBytes: (value.result.length - 2) / 2 }
            : Array.isArray(value.result)
              ? { logCount: value.result.length }
              : value.result,
        error: value.error,
      });
    }
  } catch {}
});
page.on("requestfailed", (r) =>
  failures.push({ url: r.url(), error: r.failure()?.errorText }),
);
page.on("response", (r) => {
  if (r.status() >= 400) statuses.push({ url: r.url(), status: r.status() });
});
try {
  await page.goto(`http://127.0.0.1:${server.address().port}/preview/`);
  await page
    .waitForFunction(
      () =>
        document
          .querySelector(".pane-loans")
          ?.textContent.includes("Could not read loan book") ||
        document.querySelector(".loan-mark"),
      undefined,
      { timeout: 60000 },
    )
    .catch((e) => console.log(e.message));
  await page.screenshot({
    path: resolve(root, "docs/frontend/live-charts.png"),
  });
  const evidence = {
    date: new Date().toISOString(),
    mode: "Live public network browser reads; no wallet installed, no signing or broadcast",
    browser: await browser.version(),
    status: await page
      .locator(".statusbar")
      .textContent()
      .catch(() => null),
    notice: await page
      .locator(".global-notice")
      .textContent({ timeout: 100 })
      .catch(() => null),
    book: await page
      .locator(".pane-loans")
      .textContent()
      .catch(() => null),
    oracle: await page
      .locator(".pane-oracle")
      .textContent()
      .catch(() => null),
    failures,
    statuses,
    calls,
  };
  await writeFile(
    resolve(root, "docs/frontend/live-charts.json"),
    JSON.stringify(evidence, null, 2) + "\n",
  );
  console.log(JSON.stringify(evidence, null, 2));
} finally {
  await browser.close();
  await new Promise((r) => server.close(r));
}
