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
  "buy/index.html",
  "buy/card.png",
  "97/index.html",
  "97/card.png",
  "tokenomics/index.html",
  "404.html",
  "sitemap.xml",
  "_headers",
  "manifest.webmanifest",
  "robots.txt",
  "llms.txt",
])
  if (!files.includes(need)) fail(`missing ${need}`);
for (const f of files)
  if (f === "imd-deployment.json" || f.startsWith("abi/"))
    fail(`${f} ships the testnet deployment`);
// WalletConnect's library (its own lazily loaded chunk) names testnets in its chain tables; it is
// third-party code that renders no text, so it is the one file exempt from this check.
const ours = (f) => !/^assets\/walletconnect-[\w-]+\.js$/.test(f);
for (const f of files.filter(
  (f) => /\.(html|js|css|webmanifest|txt)$/.test(f) && ours(f),
)) {
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
// WalletConnect's relay is admitted exactly when a project is configured (vite.config.ts).
const wc = JSON.parse(
  await readFile(resolve(here, "../src/infer/walletconnect.json"), "utf8"),
);
if (wc.projectId && !connect.includes("wss://relay.walletconnect.org"))
  fail("a WalletConnect project is set but connect-src lacks its relay");
if (!wc.projectId && /walletconnect/.test(connect))
  fail("connect-src admits WalletConnect with no project configured");
if (/["'(]\.{1,2}\//.test(await readFile(`${dir}/404.html`, "utf8")))
  fail("404.html has a relative URL");
const html = await readFile(`${dir}/index.html`, "utf8");
if (!/<link rel="canonical" href="https:\/\/infer\.imdusd\.com\/"/.test(html))
  fail("index.html has no canonical URL");
// /buy/ is an X player card; its framing is the Worker's to grant, never _headers' (worker/infer.js).
if (
  !/frame-ancestors 'none'/.test(csp) ||
  !/X-Frame-Options: DENY/.test(headers)
)
  fail("_headers must forbid framing; the Worker opens /buy/ to X alone");
// A player card framed in a strict sandbox has the origin "null": its crossorigin assets need CORS.
if (!/\/assets\/\*\n(?:  .*\n)*  Access-Control-Allow-Origin: \*/.test(headers))
  fail("_headers must let /assets/* answer any origin, or a sandboxed player card loads blank");
const buy = await readFile(`${dir}/buy/index.html`, "utf8");
for (const [name, value] of [
  ["twitter:card", "player"],
  ["twitter:player", "https://infer.imdusd.com/buy/"],
  ["twitter:player:width", "480"],
  ["twitter:player:height", "560"],
  ["twitter:image", "https://infer.imdusd.com/buy/card.png"],
])
  if (!buy.includes(`<meta name="${name}" content="${value}" />`))
    fail(`buy/index.html lacks ${name} = ${value}`);
const film = await readFile(`${dir}/97/index.html`, "utf8");
for (const [name, value] of [
  ["twitter:card", "player"],
  ["twitter:player", "https://infer.imdusd.com/97/"],
  ["twitter:player:width", "480"],
  ["twitter:player:height", "480"],
  ["twitter:image", "https://infer.imdusd.com/97/card.png"],
])
  if (!film.includes(`<meta name="${name}" content="${value}" />`))
    fail(`97/index.html lacks ${name} = ${value}`);
if (!/<video[^>]+src="\/?(\.\.\/)?assets\/infer97-[^"]+\.mp4"/.test(film)) fail("97/index.html does not play the built film");
if (!/media-src 'self'/.test(csp)) fail("the Content-Security-Policy must let /97/ play its film");
console.log(
  `infer-check: ${files.length} files; mainnet only; CSP admits ${connect.trim()}.`,
);
