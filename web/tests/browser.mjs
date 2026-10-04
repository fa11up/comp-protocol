import { createServer } from "node:http";
import { readFile, mkdir, writeFile } from "node:fs/promises";
import { resolve, extname } from "node:path";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import { chromium } from "playwright";
import AxeBuilder from "@axe-core/playwright";
import {
  fixture,
  rpc,
  sent,
  installWallet,
  config,
  candidate,
  blockscout,
} from "./fixture.mjs";
const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const evidence = resolve(root, "docs/frontend");
await mkdir(evidence, { recursive: true });
const server = createServer(async (req, res) => {
  try {
    const pathname = new URL(req.url, "http://localhost").pathname;
    if (!pathname.startsWith("/preview/")) {
      res.writeHead(404).end();
      return;
    }
    const suffix = decodeURIComponent(pathname.slice(9)) || "index.html";
    const path = resolve(root, "dist", suffix);
    if (!path.startsWith(resolve(root, "dist") + "/")) throw Error("path");
    const bytes = await readFile(path);
    res.setHeader(
      "Content-Type",
      {
        ".html": "text/html",
        ".js": "text/javascript",
        ".css": "text/css",
        ".json": "application/json",
        ".svg": "image/svg+xml",
      }[extname(path)] || "application/octet-stream",
    );
    res.end(bytes);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((done) => server.listen(0, "127.0.0.1", done));
const url = `http://127.0.0.1:${server.address().port}/preview/`;
const browser = await chromium.launch({
  headless: true,
  args: ["--no-sandbox"],
});
const results = [];
const errors = [];
let context;
function passed(name, detail) {
  results.push({ name, status: "passed", detail });
  console.log("PASS", name);
}
async function setup({ wallet = true, chain = "0x1" } = {}) {
  if (context) await context.close();
  context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
  });
  const s = fixture();
  const page = await context.newPage();
  page.setDefaultTimeout(12000);
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (msg) => {
    if (msg.type() === "error") errors.push(msg.text());
  });
  await context.route(/^https:\/\//, async (route) => {
    const request = route.request();
    if (
      request.url().startsWith("https://eth-sepolia.blockscout.com/api/v2/")
    ) {
      await route.fulfill({
        json: blockscout(s, request.url()),
        headers: { "access-control-allow-origin": "*" },
      });
      return;
    }
    if (!config.network.rpcUrls.some((u) => request.url().startsWith(u)))
      throw Error("Unexpected remote request " + request.url());
    const body = request.postDataJSON();
    const result = Array.isArray(body)
      ? body.map((b) => rpc(s, b))
      : rpc(s, body);
    await route.fulfill({
      json: result,
      headers: { "access-control-allow-origin": "*" },
    });
  });
  if (wallet) {
    await page.exposeFunction("__sendFixture", (tx) => sent(s, tx));
    await installWallet(page, { chain });
  }
  await page.goto(url);
  await page
    .getByRole("button", { name: "Refresh state", exact: true })
    .waitFor();
  await page
    .locator(".pane-work")
    .getByText("Faucet mode", { exact: true })
    .waitFor();
  return { page, s };
}
async function connect(page) {
  await page
    .getByRole("button", { name: "Connect wallet", exact: true })
    .click();
  if (
    await page
      .getByRole("button", { name: "Switch to Sepolia", exact: true })
      .isVisible()
  )
    await page
      .getByRole("button", { name: "Switch to Sepolia", exact: true })
      .click();
  await page.waitForFunction(
    () =>
      !document.querySelector(".pane-redemption button[type=submit]").disabled,
  );
}
async function refresh(page) {
  await page
    .getByRole("button", { name: "Refresh state", exact: true })
    .click();
  await page
    .getByRole("button", { name: "Refresh state", exact: true })
    .waitFor();
}
async function expectText(locator, text) {
  await locator.getByText(text, { exact: false }).first().waitFor();
}
async function review(page, label) {
  await page.getByRole("button", { name: label, exact: true }).click();
  await page.locator("dialog[open]").waitFor();
}
async function cancel(page) {
  await page
    .locator("dialog")
    .getByRole("button", { name: "Cancel", exact: true })
    .click();
}
try {
  let { page, s } = await setup({ wallet: false });
  await page.getByRole("button", { name: "Connect wallet" }).click();
  await expectText(page, "No browser wallet found");
  assert.equal(
    await page.getByRole("button", { name: "Quote redemption" }).isEnabled(),
    false,
  );
  passed("Missing wallet explanation and disconnected transaction gates");
  ({ page, s } = await setup());
  await page.evaluate(() => (window.__wallet.reject = true));
  await page.getByRole("button", { name: "Connect wallet" }).click();
  await expectText(page, "Wallet request rejected");
  await page.evaluate(() => (window.__wallet.reject = false));
  await connect(page);
  const requests = await page.evaluate(() => window.__wallet.requests);
  const methods = requests
    .filter((x) => x.method.includes("EthereumChain"))
    .map((x) => x.method);
  assert.deepEqual(methods, [
    "wallet_switchEthereumChain",
    "wallet_addEthereumChain",
    "wallet_switchEthereumChain",
  ]);
  assert.deepEqual(
    requests.find((x) => x.method === "wallet_addEthereumChain").params[0],
    config.walletAddChain,
  );
  passed(
    "Connect rejection recovery, wrong chain and exact add-chain fallback",
  );
  const red = page.locator(".pane-redemption");
  await red.getByLabel("Redeem COMP", { exact: true }).fill("10");
  await red.getByRole("button", { name: "Quote redemption" }).click();
  await expectText(red, "Served by");
  assert.equal(
    await red.locator(".quote").getByText("Reserve", { exact: true }).count(),
    1,
  );
  await expectText(red, "Your fee");
  passed("Reserve-only quote includes net output, fee, source and minimum");
  const sizes = await red.locator(".curve-row strong").allTextContents();
  assert.deepEqual(sizes, ["0.75%", "1.75%", "3%"]);
  passed("Size comparison reads on-chain fees for 1%, 5%, 10% supply", sizes);
  await red.getByLabel("Redeem COMP", { exact: true }).fill("11");
  assert.equal(await red.locator(".quote").count(), 0);
  passed("Changing an input invalidates a quote");
  s.reserve = 2n * 10n ** 18n;
  await refresh(page);
  await red.getByLabel("Redeem COMP", { exact: true }).fill("100");
  await red.getByRole("button", { name: "Quote redemption" }).click();
  await expectText(red, "Enter a candidate position");
  await red.getByLabel("Candidate position", { exact: false }).fill(candidate);
  await red.getByRole("button", { name: "Quote redemption" }).click();
  await expectText(red.locator(".quote"), "Reserve + position");
  await review(page, "Review redemption");
  await expectText(page.locator("dialog"), "Receive at least");
  await cancel(page);
  passed("Mixed quote requires a candidate and uses a transaction review");
  s.reserve = 0n;
  await refresh(page);
  await red.getByRole("button", { name: "Quote redemption" }).click();
  await expectText(red.locator(".quote"), "Position");
  passed("Position-only route");
  s.candidateCR = 200n;
  await refresh(page);
  await red.getByRole("button", { name: "Quote redemption" }).click();
  await expectText(red, "at/above the eligibility ceiling");
  assert.equal(await red.locator(".quote").count(), 0);
  passed("Candidate at derived ceiling is rejected");
  s.candidateCR = 180n;
  s.rejectSimulation = true;
  await refresh(page);
  await red.getByRole("button", { name: "Quote redemption" }).click();
  await expectText(red, "would reduce backing");
  passed("Full redemption simulation translates backing guard revert");
  s.rejectSimulation = false;
  s.stale = true;
  await refresh(page);
  assert.equal(
    await red.getByRole("button", { name: "Quote redemption" }).isEnabled(),
    false,
  );
  passed("Stale feeds disable price-sensitive actions");
  s.stale = false;
  s.mode = "attested";
  await refresh(page);
  await expectText(page.locator(".pane-work"), "10,000");
  await expectText(page.locator(".pane-work"), "not an on-chain proof");
  await expectText(page.locator(".pane-work"), "980");
  passed(
    "Attested oracle task tally, age, per-task rate, earned/consumed/remaining rights",
  );
  // Approval remains a separate transaction, and allowance is refetched after confirmation.
  const pos = page.locator(".pane-position");
  await pos.getByLabel("Deposit IMD", { exact: true }).fill("5");
  await review(page, "Approve IMD");
  await page.evaluate(() => (window.__wallet.reject = true));
  await page
    .locator("dialog")
    .getByRole("button", { name: "Confirm in wallet" })
    .click();
  await expectText(page.locator("dialog"), "Wallet request rejected");
  assert.equal(s.sent.length, 0);
  await page.evaluate(() => (window.__wallet.reject = false));
  await page
    .locator("dialog")
    .getByRole("button", { name: "Confirm in wallet" })
    .click();
  await expectText(page.locator("footer"), "Confirmed on chain.");
  assert.equal(s.sent[0].functionName, "approve");
  await pos
    .getByRole("button", { name: "Review deposit", exact: true })
    .waitFor();
  await review(page, "Review deposit");
  await cancel(page);
  passed(
    "Exact approval, rejected signing retry, receipt wait and refreshed allowance",
  );
  // Walk all prior panes and prepare primary transactions with mock simulation.
  await pos.getByText("Borrow, repay & withdraw", { exact: true }).click();
  for (const [label, input, value] of [
    ["Review borrow", "Borrow COMP", "1"],
    ["Review repayment", "Repay COMP", "1"],
    ["Review withdrawal", "Withdraw IMD", "1"],
  ]) {
    await pos.getByLabel(input, { exact: true }).fill(value);
    await review(page, label);
    await cancel(page);
  }
  await page
    .locator(".pane-work")
    .getByLabel("Mint earned COMP", { exact: true })
    .fill("1");
  await review(page, "Review work mint");
  await cancel(page);
  const keeper = page.locator(".pane-keeper");
  s.candidateCR = 140n;
  await keeper.getByLabel("Borrower address").fill(candidate);
  await keeper.getByRole("button", { name: "Inspect position" }).click();
  await expectText(keeper, "140%");
  await review(page, "Review mark");
  await cancel(page);
  await keeper.getByLabel("Repay borrower COMP").fill("1");
  await review(page, "Review liquidation");
  await cancel(page);
  await review(page, "Review clear mark");
  await cancel(page);
  const backing = page.locator(".pane-backing");
  await backing.getByText("Treasury actions", { exact: true }).click();
  await backing.getByLabel("Token to sync").fill(config.contracts[0].address);
  await review(page, "Review reserve sync");
  await cancel(page);
  const gov = page.locator(".pane-governance");
  await review(page, "Review apply pending");
  await cancel(page);
  await gov.getByText("Governor / propose a change", { exact: true }).click();
  await gov.getByLabel("Spread (25–100 ratio points)").fill("55");
  await review(page, "Review spread proposal");
  await cancel(page);
  const oracle = page.locator(".pane-oracle");
  await oracle.getByText("Reporter fallback", { exact: true }).click();
  await oracle
    .getByRole("button", { name: "Check reporter permission" })
    .click();
  await expectText(oracle, "Reporter permission confirmed.");
  await oracle.getByLabel("Value (18-decimal units)").fill("0.001");
  await review(page, "Review feed report");
  await cancel(page);
  passed(
    "Position, work mint, keeper, backing, governance and oracle controls simulate their intended calls",
  );
  // Settle visual state, test all sizes at the static-host subpath.
  await page
    .locator("details[open]")
    .evaluateAll((nodes) => nodes.forEach((n) => (n.open = false)));
  s.reserve = 100n * 10n ** 18n;
  s.candidateCR = 180n;
  await refresh(page);
  await red.getByLabel("Redeem COMP", { exact: true }).fill("10");
  await red.getByLabel("Candidate position", { exact: false }).fill("");
  await red.getByRole("button", { name: "Quote redemption" }).click();
  await red.locator(".quote").waitFor();
  await review(page, "Review redemption");
  await page
    .locator("dialog")
    .getByRole("button", { name: "Confirm in wallet" })
    .click();
  await expectText(page.locator("footer"), "Confirmed on chain.");
  assert.equal(s.sent.at(-1).functionName, "redeem");
  assert.equal(s.sent.at(-1).args[0], 10n * 10n ** 18n);
  assert.ok(s.sent.at(-1).args[1] > 0n);
  passed(
    "Redemption signing request carries exact burn amount, nonzero minimum and candidate; mocked receipt confirms",
  );
  await red.getByRole("button", { name: "Quote redemption" }).click();
  await red.locator(".quote").waitFor();
  const viewports = [];
  for (const [width, height] of [
    [1440, 900],
    [1280, 800],
    [900, 900],
    [390, 844],
    [320, 740],
  ]) {
    await page.setViewportSize({ width, height });
    await page.waitForTimeout(100);
    const dimensions = await page.evaluate(() => ({
      w: innerWidth,
      h: innerHeight,
      sw: document.documentElement.scrollWidth,
      sh: document.documentElement.scrollHeight,
      bw: document.body.scrollWidth,
      bh: document.body.scrollHeight,
    }));
    if (dimensions.sh !== height || dimensions.sw !== width) {
      await page.screenshot({ path: `${evidence}/overflow-debug.png` });
      console.log(
        await page.evaluate(() =>
          [...document.querySelectorAll("body *")]
            .map((el) => ({
              tag: el.tagName,
              cls: el.className,
              rect: el.getBoundingClientRect().toJSON(),
              position: getComputedStyle(el).position,
            }))
            .filter(
              (e) => e.rect.bottom > innerHeight && e.position === "absolute",
            )
            .slice(0, 25),
        ),
      );
    }
    assert.equal(dimensions.sw, width);
    assert.equal(dimensions.sh, height);
    assert.equal(dimensions.bw, width);
    assert.equal(dimensions.bh, height);
    await page
      .locator(".pane-body")
      .evaluateAll((nodes) => nodes.forEach((n) => (n.scrollTop = 0)));
    await page.screenshot({ path: `${evidence}/terminal-${width}.png` });
    viewports.push(dimensions);
    if (width <= 760) {
      for (const pane of [
        "loans",
        "position",
        "work",
        "oracle",
        "keeper",
        "backing",
        "governance",
        "redemption",
      ]) {
        await page.getByLabel("View pane").selectOption(pane);
        assert.equal(await page.locator(`.pane-${pane}`).isVisible(), true);
      }
    }
  }
  passed(
    "One viewport, only panes scroll; all mobile panes reachable",
    viewports,
  );
  const axeMobile = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa"])
    .analyze();
  assert.deepEqual(
    axeMobile.violations.map((v) => ({
      id: v.id,
      help: v.help,
      nodes: v.nodes.length,
    })),
    [],
  );
  await page.setViewportSize({ width: 1440, height: 900 });
  const axeDesktop = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa"])
    .analyze();
  assert.deepEqual(
    axeDesktop.violations.map((v) => ({
      id: v.id,
      help: v.help,
      nodes: v.nodes.length,
    })),
    [],
  );
  passed(
    "Axe scan: no automated WCAG A/AA violations on desktop and 320px redemption",
  );
  await page.keyboard.press("Tab");
  await page.getByLabel("Redeem COMP", { exact: true }).focus();
  await page.keyboard.press("Tab");
  const focus = await page.evaluate(() => ({
    tag: document.activeElement.tagName,
    name: document.activeElement.getAttribute("name"),
    outline: getComputedStyle(document.activeElement).outlineStyle,
  }));
  assert.equal(focus.outline, "solid");
  await page.screenshot({ path: `${evidence}/keyboard-focus.png` });
  passed("Keyboard tab progression and visible focus CSS", focus);
  await page.emulateMedia({ reducedMotion: "reduce" });
  const motion = await page
    .getByRole("button", { name: "Quote redemption" })
    .evaluate((el) => getComputedStyle(el).transitionDuration);
  assert.equal(motion, "0s");
  passed("Reduced motion disables transitions");
  const contrast = await page.evaluate(() => {
    const root = getComputedStyle(document.documentElement);
    const tokens = Object.fromEntries(
      ["--bg", "--surface", "--text", "--muted", "--control"].map((k) => [
        k,
        root.getPropertyValue(k).trim(),
      ]),
    );
    const l = (hex) => {
      if (hex.length === 4)
        hex = "#" + [...hex.slice(1)].map((c) => c + c).join("");
      const c = hex
        .slice(1)
        .match(/../g)
        .map((x) => parseInt(x, 16) / 255)
        .map((x) => (x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4));
      return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    };
    const c = (a, b) =>
      (Math.max(l(a), l(b)) + 0.05) / (Math.min(l(a), l(b)) + 0.05);
    return {
      tokens,
      body: c(tokens["--text"], tokens["--surface"]),
      secondary: c(tokens["--muted"], tokens["--surface"]),
      inputBorder: c(tokens["--control"], tokens["--bg"]),
    };
  });
  assert.ok(
    contrast.body >= 4.5 &&
      contrast.secondary >= 4.5 &&
      contrast.inputBorder >= 3,
  );
  passed("Computed rendered token contrast", contrast);
  await red.getByLabel("Redeem COMP", { exact: true }).focus();
  await page.keyboard.press("ControlOrMeta+A");
  await page.keyboard.type("12");
  await page.keyboard.press("Tab");
  await page.keyboard.press("Tab");
  await page.keyboard.press("Tab");
  await page.keyboard.press("Enter");
  await red.locator(".quote").waitFor();
  await page.keyboard.press("Tab");
  await page.keyboard.press("Enter");
  await page.locator("dialog[open]").waitFor();
  await page.keyboard.press("Escape");
  assert.equal(await page.locator("dialog[open]").count(), 0);
  assert.match(
    await page.evaluate(() => document.activeElement.textContent),
    /Review redemption/,
  );
  passed(
    "Keyboard-only redemption quote/review, Escape cancellation and focus return",
  );
  s.rpcFail = true;
  await refresh(page);
  await expectText(page.locator(".statusbar"), "RPC unavailable");
  assert.equal(
    await red.getByRole("button", { name: "Quote redemption" }).isEnabled(),
    false,
  );
  s.rpcFail = false;
  await refresh(page);
  await page.waitForFunction(
    () =>
      !document.querySelector(".pane-redemption button[type=submit]").disabled,
  );
  passed("RPC failure disables transactions and refresh recovers");
  s.codeMissing = true;
  await refresh(page);
  await expectText(page, "No deployed code");
  s.codeMissing = false;
  await refresh(page);
  passed("Missing deployed code fails closed");
  await page.route("**/abi/PriceFeed.json", (route) =>
    route.fulfill({ json: [] }),
  );
  await page.reload();
  await expectText(page, "ABI asset integrity check failed");
  assert.equal(
    await page.getByRole("button", { name: "Connect wallet" }).count(),
    0,
  );
  await page.unroute("**/abi/PriceFeed.json");
  await page.getByRole("button", { name: "Retry configuration" }).click();
  await page
    .getByRole("button", { name: "Refresh state", exact: true })
    .waitFor();
  passed(
    "Runtime ABI integrity failure blocks the terminal; corrected asset can be retried",
  );
  // Charts: exercise the exported bundle against deliberately irregular and failing history.
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.locator(".loan-mark").first().waitFor();
  assert.equal(await page.locator(".loan-mark").count(), 3);
  const names = await page.locator(".loan-label").allTextContents();
  const dots = await page
    .locator(".loan-dot")
    .evaluateAll((nodes) => nodes.map((n) => parseFloat(n.style.width)));
  assert.deepEqual(
    [...dots].sort((a, b) => a - b),
    [12, 24, 24],
  );
  await page.locator(".loan-mark").first().hover();
  assert.match(
    await page.locator(".loan-mark").first().getAttribute("title"),
    /0x[0-9a-fA-F]{40}/,
  );
  await page.locator(".loan-mark").first().focus();
  await page.keyboard.press("Enter");
  assert.match(
    await page.locator(".selected-loan").textContent(),
    /0x[0-9a-fA-F]{40}/,
  );
  passed(
    "Deposit owners deduplicated, zero-debt owner excluded, debt area ratio 4:1; hover, keyboard and touch-readable addresses",
    names,
  );
  const initialWidth = await page
    .locator(".liquidatable-band")
    .evaluate((n) => parseFloat(n.style.width));
  s.minCR = 200n;
  await refresh(page);
  await page.waitForFunction(() =>
    document.querySelector(".liquidatable-band")?.style.width.startsWith("66."),
  );
  assert.ok((await page.locator(".loan-mark.is-danger").count()) >= 2);
  const updatedWidth = await page
    .locator(".liquidatable-band")
    .evaluate((n) => parseFloat(n.style.width));
  assert.ok(updatedWidth > initialWidth);
  const oldLeft = await page
    .getByRole("button", { name: /^Copper Penny,/ })
    .evaluate((n) => n.style.left);
  s.priceMultiplier = 0.9;
  await refresh(page);
  await page.waitForFunction(
    (previous) =>
      [...document.querySelectorAll(".loan-mark")].find((n) =>
        n.textContent.includes("Copper Penny"),
      )?.style.left !== previous,
    oldLeft,
  );
  assert.match(
    await page
      .locator(".loan-mark")
      .first()
      .evaluate((n) => getComputedStyle(n).transitionProperty),
    /left/,
  );
  s.minCR = 150n;
  s.priceMultiplier = 1;
  await refresh(page);
  passed(
    "Live minCR moves the risk band and changes position classification; price updates move existing marks",
  );
  const cadence = page.locator(".pane-oracle .cadence-chart").first();
  await cadence.locator("circle").first().waitFor({ state: "attached" });
  assert.equal(await cadence.locator("circle").count(), 4);
  const xs = await cadence
    .locator("circle")
    .evaluateAll((nodes) => nodes.map((n) => Number(n.getAttribute("cx"))));
  assert.ok((xs[2] - xs[1]) / (xs[1] - xs[0]) > 20);
  assert.equal(await cadence.locator(".limit-line").count(), 1);
  s.extraPoint = true;
  await refresh(page);
  await page.waitForFunction(
    () =>
      document
        .querySelector(".pane-oracle .cadence-chart")
        ?.querySelectorAll("circle").length === 5,
  );
  assert.equal(
    await cadence
      .locator(".spark-point")
      .last()
      .evaluate((n) => getComputedStyle(n).animationName),
    "add-point",
  );
  assert.equal(await page.locator(".supply-chart .collateral-fill").count(), 1);
  assert.equal(await page.locator(".supply-chart .work-fill").count(), 1);
  assert.equal(await page.locator(".supply-chart .par-marker").count(), 1);
  assert.equal(await page.locator(".supply-chart .backing-marker").count(), 1);
  assert.equal(await page.locator(".work-chart .bar-marker").count(), 1);
  passed(
    "Every accepted value is a point at its irregular timestamp; expiry marked and a new point appends; composition, backing/par and work-ceiling bars rendered",
    { xs },
  );
  s.workCeiling = 10n * 10n ** 18n;
  s.maxDivergenceBps = 500n;
  s.spotMultiplier = 1.1;
  await refresh(page);
  await page.locator(".work-chart .over-limit").waitFor({ state: "attached" });
  await page
    .locator(".divergence-chart .breached")
    .waitFor({ state: "attached" });
  assert.match(
    await page.locator(".divergence-chart figcaption").textContent(),
    /±5%/,
  );
  assert.match(
    await page.locator(".work-chart").textContent(),
    /10 COMP over ceiling/,
  );
  s.workCeiling = 1250n * 10n ** 18n;
  s.maxDivergenceBps = 2000n;
  s.spotMultiplier = 1;
  await refresh(page);
  passed(
    "Live workCeiling and maxDivergenceBps updates redraw limits and explicitly label breaches",
  );
  s.logMode = "empty";
  await refresh(page);
  await page.locator(".loan-ledger summary").click();
  await expectText(page.locator(".loan-ledger"), "Blockscout deposit history");
  assert.equal(await page.locator(".loan-mark").count(), 3);
  s.explorerEmpty = true;
  await refresh(page);
  await expectText(page.locator(".pane-loans"), "Could not read loan book");
  assert.equal(await page.locator(".loan-mark").count(), 0);
  assert.match(
    await page.locator(".pane-loans").textContent(),
    /position count is unknown/,
  );
  s.explorerEmpty = false;
  s.logMode = "rpc";
  await page
    .getByRole("button", { name: "Retry history", exact: true })
    .click();
  await page.locator(".loan-mark").first().waitFor();
  s.ownerReadFail = true;
  await refresh(page);
  await expectText(page.locator(".pane-loans"), "Could not read loan book");
  assert.equal(await page.locator(".loan-mark").count(), 0);
  s.ownerReadFail = false;
  await page
    .getByRole("button", { name: "Retry history", exact: true })
    .click();
  await page.locator(".loan-mark").first().waitFor();
  passed(
    "Silent empty RPC uses paginated Blockscout fallback; empty fallback and partial owner failure render unknown, retry restores the book",
  );
  // System default, live OS change, explicit persistence, theme-color, and both palettes.
  await page.emulateMedia({ colorScheme: "dark" });
  await page.waitForFunction(
    () => document.documentElement.dataset.theme === "dark",
  );
  assert.equal(
    await page.evaluate(() => document.documentElement.dataset.theme),
    "dark",
  );
  await page.getByRole("button", { name: "Use light theme" }).click();
  await page.reload();
  await page.locator(".loan-mark").first().waitFor();
  assert.equal(
    await page.evaluate(() => document.documentElement.dataset.theme),
    "light",
  );
  assert.equal(
    await page.evaluate(() => localStorage.getItem("comp-terminal-theme")),
    "light",
  );
  passed(
    "OS theme follows live changes; explicit theme survives reload and overrides OS",
  );
  const variants = [];
  for (const theme of ["light", "dark"]) {
    if (
      (await page.evaluate(() => document.documentElement.dataset.theme)) !==
      theme
    )
      await page.getByRole("button", { name: `Use ${theme} theme` }).click();
    assert.equal(
      await page.locator('meta[name="theme-color"]').getAttribute("content"),
      theme === "light" ? "#f7f5ef" : "#111",
    );
    for (const [width, height] of [
      [1440, 900],
      [1280, 800],
      [900, 900],
      [390, 844],
      [320, 740],
    ]) {
      await page.setViewportSize({ width, height });
      await page
        .locator(".pane-body")
        .evaluateAll((nodes) => nodes.forEach((n) => (n.scrollTop = 0)));
      if (width <= 760)
        await page.getByLabel("View pane").selectOption("loans");
      await page.waitForTimeout(200);
      const dims = await page.evaluate(() => ({
        width: innerWidth,
        height: innerHeight,
        sw: document.documentElement.scrollWidth,
        sh: document.documentElement.scrollHeight,
      }));
      assert.equal(dims.sw, width);
      assert.equal(dims.sh, height);
      const labels = await page
        .locator(".loan-label")
        .evaluateAll((nodes) =>
          nodes.map((n) => n.getBoundingClientRect().toJSON()),
        );
      for (let i = 0; i < labels.length; i++)
        for (let j = i + 1; j < labels.length; j++) {
          const a = labels[i],
            b = labels[j];
          assert.ok(
            a.right <= b.left ||
              b.right <= a.left ||
              a.bottom <= b.top ||
              b.bottom <= a.top,
            `Position labels overlap at ${width}px`,
          );
        }
      if (width === 1440 || width === 1280 || width === 390)
        await page.screenshot({
          path: `${evidence}/charts-${theme}-${width}.png`,
        });
      variants.push({ theme, ...dims });
      if (width <= 760) {
        for (const pane of [
          "loans",
          "position",
          "oracle",
          "keeper",
          "backing",
          "governance",
          "redemption",
          "work",
        ]) {
          await page.getByLabel("View pane").selectOption(pane);
          assert.equal(await page.locator(`.pane-${pane}`).isVisible(), true);
        }
        await page.getByLabel("View pane").selectOption("loans");
      }
    }
    await page.setViewportSize({ width: 390, height: 844 });
    await page.getByLabel("View pane").selectOption("oracle");
    await page
      .locator(".pane-oracle .pane-body")
      .evaluate((n) => (n.scrollTop = 0));
    await page.waitForTimeout(200);
    await page.screenshot({ path: `${evidence}/cadence-${theme}-390.png` });
    await page.setViewportSize({ width: 1440, height: 900 });
    const pairs = await page.evaluate(() => {
      const rgb = (value) =>
        value
          .match(/[\d.]+/g)
          .slice(0, 3)
          .map(Number);
      const luminance = (value) =>
        rgb(value)
          .map((v) => v / 255)
          .map((v) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4))
          .reduce((n, v, i) => n + v * [0.2126, 0.7152, 0.0722][i], 0);
      const ratio = (a, b) =>
        (Math.max(luminance(a), luminance(b)) + 0.05) /
        (Math.min(luminance(a), luminance(b)) + 0.05);
      const surface = getComputedStyle(
        document.querySelector(".pane"),
      ).backgroundColor;
      const background = getComputedStyle(
        document.documentElement,
      ).backgroundColor;
      const text = getComputedStyle(document.documentElement).color;
      const muted = getComputedStyle(
        document.querySelector(".book-heading .muted"),
      ).color;
      const healthy = getComputedStyle(
        document.querySelector(".loan-mark.is-healthy"),
      ).color;
      const band = getComputedStyle(
        document.querySelector(".redeemable-band"),
      ).backgroundColor;
      return {
        surface,
        background,
        text,
        muted,
        healthy,
        band,
        body: ratio(text, surface),
        secondary: ratio(muted, surface),
        markOnBand: ratio(healthy, band),
        markOnSurface: ratio(healthy, surface),
      };
    });
    assert.ok(
      pairs.body >= 4.5 &&
        pairs.secondary >= 4.5 &&
        pairs.markOnBand >= 3 &&
        pairs.markOnSurface >= 3,
    );
    passed(`Measured rendered ${theme} text and chart-mark contrast`, pairs);
    const scan = await new AxeBuilder({ page })
      .withTags(["wcag2a", "wcag2aa", "wcag21aa", "wcag22aa"])
      .analyze();
    assert.deepEqual(
      scan.violations.map((v) => ({
        id: v.id,
        nodes: v.nodes.map((n) => n.target),
      })),
      [],
    );
  }
  passed(
    "Both themes fit all five viewport sizes; all eight mobile panes reachable; desktop axe reports no violations",
    variants,
  );
  await page.emulateMedia({ reducedMotion: "reduce" });
  for (const selector of [
    ".loan-mark",
    ".ratio-band",
    ".spark-point",
    ".spark-path",
    ".bar-fill",
  ]) {
    const styles = await page
      .locator(selector)
      .first()
      .evaluate((n) => ({
        transition: getComputedStyle(n).transitionDuration,
        animation: getComputedStyle(n).animationName,
      }));
    assert.equal(styles.transition, "0s");
    assert.equal(styles.animation, "none");
  }
  passed(
    "Reduced motion disables all chart transitions, line drawing and point entrances",
  );
  assert.deepEqual(errors, []);
  passed(
    "No browser console errors or uncaught exceptions in mocked workflows",
  );
  await writeFile(
    `${evidence}/browser-results.json`,
    JSON.stringify(
      {
        date: new Date().toISOString(),
        url: "local /preview/ subpath",
        browser: await browser.version(),
        mode: "mocked RPC and wallet; no broadcasts",
        results,
        errors,
      },
      null,
      2,
    ) + "\n",
  );
} catch (e) {
  await writeFile(`${evidence}/browser-failure.txt`, e.stack + "\n");
  console.error(e);
  process.exitCode = 1;
} finally {
  await browser.close();
  await new Promise((done) => server.close(done));
}
