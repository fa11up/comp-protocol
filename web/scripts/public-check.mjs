// Fails the public build if the export would serve or link to the terminal. imdusd.com serves the
// homepage and docs only; a link to a page that is not served is a broken site.
import { readFile, readdir, stat } from "node:fs/promises";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
const dir = resolve(dirname(fileURLToPath(import.meta.url)), "../../dist-public");
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
  console.error(`public-check: ${m}`);
  process.exit(1);
};
for (const need of ["index.html", "docs/index.html", "_headers", "_redirects", "manifest.webmanifest"])
  if (!files.includes(need)) fail(`missing ${need}`);
if (files.some((f) => f.startsWith("terminal/"))) fail("the terminal was built into the public site");
// The public site connects to no chain: no deployment file, no ABIs.
for (const f of files)
  if (f === "imd-deployment.json" || f.startsWith("abi/")) fail(`${f} ships a chain deployment`);
for (const f of files.filter((f) => /\.(html|js|css|webmanifest)$/.test(f))) {
  const text = await readFile(`${dir}/${f}`, "utf8");
  // A link to the terminal, in any of the forms the site writes one.
  if (/["'`(]\.{0,2}\/?terminal\//.test(text)) fail(`${f} still links to the terminal`);
  // Nothing about the testnet, and no way to reach a chain: no explorer, no RPC endpoint.
  const leak = text.match(/sepolia|testnet|blockscout|etherscan|publicnode|infura|alchemy|eth_call|eth_getLogs/i);
  if (leak) fail(`${f} mentions "${leak[0]}"`);
}
// The favicon is drawn twice: public/favicon.svg (follows the OS theme) and theme.tsx (follows the
// in-page toggle). Both must be the same mark.
const mark = (await readFile(`${dir}/favicon.svg`, "utf8")).match(/<path d="([^"]+)"/)?.[1];
const bundle = (await Promise.all(files.filter((f) => f.endsWith(".js")).map((f) => readFile(`${dir}/${f}`, "utf8")))).join("");
if (!mark || !bundle.includes(mark)) fail("favicon.svg and the theme toggle's favicon are different marks");
const manifest = JSON.parse(await readFile(`${dir}/manifest.webmanifest`, "utf8"));
if (manifest.start_url !== "./") fail(`manifest start_url is ${manifest.start_url}`);
console.log(`public-check: ${files.length} files; homepage and docs only; no terminal links, no testnet, no chain connection.`);
