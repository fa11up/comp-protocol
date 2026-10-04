import { readFile, writeFile, readdir, stat } from "node:fs/promises";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { keccak256, toBytes } from "viem";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const base = JSON.parse(await readFile(`${root}/web/deployment-source.json`));
export const canonical = (value) => JSON.stringify(sort(value));
function sort(v) {
  return Array.isArray(v)
    ? v.map(sort)
    : v && typeof v === "object"
      ? Object.fromEntries(
          Object.keys(v)
            .sort()
            .map((k) => [k, sort(v[k])]),
        )
      : v;
}
const allowed = [
  "version",
  "launchId",
  "chainId",
  "sourceCommit",
  "attestationHash",
  "contracts",
  "assets",
  "network",
  "walletAddChain",
  "poolKey",
];
if (Object.keys(base).some((k) => !allowed.includes(k)))
  throw Error("Unexpected deployment field");
const digest = (b) => createHash("sha256").update(b).digest("hex");
for (const c of base.contracts) {
  const raw = await readFile(`${root}/dist/${c.abiPath}`);
  const abi = JSON.parse(raw);
  if (
    !Array.isArray(abi) ||
    keccak256(toBytes(canonical(abi))).slice(2) !== c.abiHash
  )
    throw Error(`ABI hash mismatch: ${c.name}`);
  const pinned = execFileSync(
    "git",
    ["show", `${base.sourceCommit}:docs/abi/${c.name}.json`],
    { cwd: root },
  );
  if (!raw.equals(pinned))
    throw Error(`ABI differs from pinned source: ${c.name}`);
}
try {
  const handoff = JSON.parse(
    await readFile(`${root}/.imd/reads/deployment.json`),
  );
  for (const k of ["launchId", "chainId", "sourceCommit", "attestationHash"])
    if (handoff[k] !== base[k]) throw Error(`Handoff mismatch: ${k}`);
  if (
    canonical(
      handoff.contracts.map((c) => ({
        name: c.name,
        address: c.address,
        abiHash: c.abiHash,
      })),
    ) !== canonical(base.contracts.map(({ abiPath, ...c }) => c))
  )
    throw Error("Contract set mismatch");
  if (canonical(handoff.poolKey) !== canonical(base.poolKey))
    throw Error("Pool key mismatch");
  const network = JSON.parse(await readFile(`${root}/.imd/reads/network.json`));
  for (const k of ["network", "walletAddChain"])
    if (canonical(base[k]) !== canonical(network[k]))
      throw Error(`Network mismatch: ${k}`);
} catch (e) {
  if (e.code !== "ENOENT") throw e;
}
async function inventory(dir, prefix = "") {
  const files = [];
  for (const n of (await readdir(dir)).sort()) {
    if (!prefix && n === "imd-deployment.json") continue;
    const path = prefix + n;
    const s = await stat(`${dir}/${n}`);
    if (s.isDirectory())
      files.push(...(await inventory(`${dir}/${n}`, path + "/")));
    else {
      if (s.size > 8388608) throw Error("Asset too large");
      files.push({ path, sha256: digest(await readFile(`${dir}/${n}`)) });
    }
  }
  return files;
}
const assets = await inventory(`${root}/dist`);
if (assets.length > 128) throw Error("Too many assets");
const manifest = { ...base, assets };
if (process.argv.includes("--check")) {
  if (
    canonical(manifest) !==
    canonical(JSON.parse(await readFile(`${root}/dist/imd-deployment.json`)))
  )
    throw Error("Manifest inventory mismatch");
} else
  await writeFile(
    `${root}/dist/imd-deployment.json`,
    JSON.stringify(manifest, null, 2) + "\n",
  );
console.log(
  `Verified ${base.contracts.length} pinned ABI hashes; ${assets.length} export assets; exact handoff and network binding.`,
);
