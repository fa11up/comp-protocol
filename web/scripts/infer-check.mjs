// Fails the INFER build if the export is not the page it should be: present, mainnet-only, no testnet
// anywhere, and headed by a Content-Security-Policy that admits exactly the configured origins.
import { readFile, readdir, stat } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
const here = dirname(fileURLToPath(import.meta.url));
const dir = resolve(here, "../../dist-infer");
const files = [];
async function walk(d, prefix = "") {
  for (const n of await readdir(d)) {
    const s = await stat(`${d}/${n}`);
    if (s.isDirectory()) await walk(`${d}/${n}`, `${prefix}${n}/`);
    else files.push(`${prefix}${n}`);
  }
}
await walk(dir);
const fail = (m) => {
  console.error(`infer-check: ${m}`);
  process.exit(1);
};
for (const need of [
  "index.html",
  "claim/index.html",
  "tokenomics/index.html",
  "404.html",
  "sitemap.xml",
  "_headers",
  "manifest.webmanifest",
  "robots.txt",
])
  if (!files.includes(need)) fail(`missing ${need}`);
for (const f of files)
  if (f === "imd-deployment.json" || f.startsWith("abi/"))
    fail(`${f} ships the testnet deployment`);
for (const f of files.filter((f) => /\.(html|js|css|webmanifest)$/.test(f))) {
  const text = await readFile(`${dir}/${f}`, "utf8");
  const leak = text.match(/sepolia|testnet/i);
  if (leak) fail(`${f} mentions "${leak[0]}"`);
}
const launchFiles = await readdir(resolve(here, "../src/infer"));
const launch = JSON.parse(
  await readFile(
    resolve(
      here,
      "../src/infer",
      launchFiles.includes("launch.json")
        ? "launch.json"
        : "launch.example.json",
    ),
    "utf8",
  ),
);
if (launch.chainId !== 1)
  fail(`launch.json names chain ${launch.chainId}; the page is mainnet only`);
const headers = await readFile(`${dir}/_headers`, "utf8");
const csp = headers.match(/Content-Security-Policy: (.*)/)?.[1] ?? "";
if (!/'sha256-[A-Za-z0-9+/=]+'/.test(csp))
  fail("the Content-Security-Policy has no hash for the theme bootstrap");
const connect = csp.match(/connect-src ([^;]*)/)?.[1] ?? "";
for (const url of [...launch.rpc, ...launch.claims.origins]) {
  if (!connect.includes(new URL(url).origin))
    fail(`connect-src lacks ${new URL(url).origin}`);
}
if (/["'(]\.{1,2}\//.test(await readFile(`${dir}/404.html`, "utf8")))
  fail("404.html has a relative URL");
const html = await readFile(`${dir}/index.html`, "utf8");
if (!/<link rel="canonical" href="https:\/\/infer\.imdusd\.com\/"/.test(html))
  fail("index.html has no canonical URL");
console.log(
  `infer-check: ${files.length} files; mainnet only; CSP admits ${connect.trim()}.`,
);
