#!/usr/bin/env node
// The three Intake bodies OracleAsker pins, checked before anything is computed from them:
//
//   node deploy/mainnet/check-bodies.mjs
//
//  - each template's question document yields EXACTLY the QUESTION_PREFIX its feed pins (the same
//    derivation as oracle/question-prefix.mjs), so the asker buys questions the feeds accept;
//  - each uses a RELATIVE window ({"hours": N}): a literal block window can be answered once, then
//    every repeat is refused as not advancing (adversarial review 2026-10-05, finding 2);
//  - none carries guards (a pinned hash would freeze a stale price band forever);
//  - each names its consumer as {chainId: 1, verifyingContract: "{{FEED}}"}, filled in by DeployMainnet.
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

const root = new URL("../../", import.meta.url).pathname;
const FEEDS = { price: "PriceFeed", nhi: "NhiFeed", spot: "SpotFeed" };
const tmp = mkdtempSync(join(tmpdir(), "bodies-"));
let bad = 0;
for (const [name, contract] of Object.entries(FEEDS)) {
  const body = JSON.parse(readFileSync(join(root, `deploy/mainnet/bodies/${name}.template.json`), "utf8"));
  const problems = [];
  if (!body.window || typeof body.window.hours !== "number" || "fromBlock" in body.window) problems.push("window is not relative {hours: N}");
  if ("guards" in body) problems.push("carries guards");
  if (body.consumer?.chainId !== 1 || body.consumer?.verifyingContract !== "{{FEED}}") problems.push("consumer is not {chainId: 1, verifyingContract: {{FEED}}}");
  const payload = join(tmp, `${name}.json`);
  writeFileSync(payload, JSON.stringify({ input: body }));
  const out = execFileSync("node", [join(root, "oracle/question-prefix.mjs"), payload], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  const derived = out.match(/QUESTION_PREFIX = hex"([0-9a-f]+)"/)?.[1];
  const pinned = readFileSync(join(root, `src/${contract}.sol`), "utf8").match(/QUESTION_PREFIX = hex"([0-9a-f]+)"/)?.[1];
  if (!derived || derived !== pinned) problems.push(`question prefix differs from ${contract}.QUESTION_PREFIX`);
  console.log(`${name.padEnd(5)} ${problems.length ? `FAIL: ${problems.join("; ")}` : `ok (window ${body.window.hours}h, panel ${body.panelSize}/${body.quorum})`}`);
  bad += problems.length;
}
rmSync(tmp, { recursive: true });
process.exitCode = bad ? 1 : 0;
