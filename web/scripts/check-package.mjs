// Measure a complete candidate Git snapshot without modifying repository .git/.
import { execFileSync } from "node:child_process";
import {
  readFile,
  writeFile,
  mkdir,
  mkdtemp,
  stat,
  rm,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("../../", import.meta.url));
const limit = 8388608;
const git = (args) =>
  execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
const changed = git(["diff", "--name-only"]).split("\n");
const forbidden = (p) =>
  /^(\.git\/|\.github\/|lib\/|foundry\.toml$|foundry\.lock$|remappings\.txt$|\.gitmodules$)/.test(
    p,
  ) ||
  /(^|\/)\.env($|\.)|(^|\/)package\.json$|(^|\/)(package-lock\.json|yarn\.lock|pnpm-lock\.yaml)$/.test(
    p,
  );
if (changed.some(forbidden)) throw Error("A protected path changed");
if (
  git(["ls-files", "--stage"])
    .split("\n")
    .some((l) => l.startsWith("160000"))
)
  throw Error("Submodule present");
const paths = [
  ...new Set(
    git(["ls-files", "-c", "-o", "--exclude-standard", "-z"]).split("\0"),
  ),
].filter((p) => p && !p.startsWith("test/scratch/") && !p.startsWith(".imd/"));
const files = [];
for (const p of paths) {
  try {
    if ((await stat(resolve(root, p))).isFile()) files.push(p);
  } catch (e) {
    if (e.code !== "ENOENT") throw e;
  }
}
if (
  files.some((p) =>
    /(^|\/)(node_modules|\.cache|\.vite|npm-cache)(\/|$)|\.(tgz|bundle)$/.test(
      p,
    ),
  )
)
  throw Error("Generated dependencies/cache/archive in submission");
const scratch = await mkdtemp(resolve(tmpdir(), "comp-package-"));
const bare = resolve(scratch, "objects-repository");
const args = [
  "--literal-pathspecs",
  `--git-dir=${bare}`,
  `--work-tree=${root}`,
];
const run = (more) =>
  execFileSync("git", [...args, ...more], {
    cwd: root,
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_CONFIG_NOSYSTEM: "1",
      GIT_CONFIG_GLOBAL: "/dev/null",
    },
  }).trim();
try {
  execFileSync("git", ["init", "--bare", "--quiet", bare]);
  async function bundle(paths) {
    await writeFile(resolve(scratch, "paths"), paths.join("\0") + "\0");
    run([
      "add",
      "--force",
      "--pathspec-from-file=" + resolve(scratch, "paths"),
      "--pathspec-file-nul",
    ]);
    const tree = run(["write-tree"]);
    const commit = run([
      "-c",
      "user.name=Package size check",
      "-c",
      "user.email=package@example.invalid",
      "commit-tree",
      tree,
      "-m",
      "Temporary complete delivery measurement",
    ]);
    run(["update-ref", "refs/heads/package", commit]);
    run([
      "bundle",
      "create",
      resolve(scratch, "delivery.bundle"),
      "refs/heads/package",
    ]);
    return (await stat(resolve(scratch, "delivery.bundle"))).size;
  }
  const before = await bundle(files);
  const bound = Math.ceil((before + 65536) / 1048576) * 1048576;
  if (bound > limit) throw Error("Insufficient bundle budget");
  const manifest = JSON.parse(
    await readFile(resolve(root, "dist/imd-deployment.json")),
  );
  const exportFiles = [
    ...manifest.assets.map((a) => `dist/${a.path}`),
    "dist/imd-deployment.json",
  ];
  const exportSizes = await Promise.all(
    exportFiles.map(async (p) => (await stat(resolve(root, p))).size),
  );
  const report = {
    checkedAt: new Date().toISOString(),
    limitBytes: limit,
    completeSnapshotBundleUpperBoundBytes: bound,
    scope:
      "Existing build configuration, dependencies, lockfile, .github, .env and repository .git unchanged; no submodules, generated dependencies, caches or archives submitted.",
    method:
      "git ls-files candidate tree, excluding assignment inputs and deleted scratch; isolated temporary bare repository; full snapshot bundle includes this report and has no prerequisite commits. Inclusive byte count is checked against this conservative bound after writing the report.",
    repositoryCommit:
      "Not created: assignment forbids repository .git writes. Temporary measurement objects are removed.",
    exportFiles: exportFiles.length,
    assetsExcludingManifest: manifest.assets.length,
    exportBytes: exportSizes.reduce((a, b) => a + b, 0),
    largestExportFileBytes: Math.max(...exportSizes),
  };
  const reportPath = "docs/frontend/packaging.json";
  await mkdir(resolve(root, "docs/frontend"), { recursive: true });
  await writeFile(
    resolve(root, reportPath),
    JSON.stringify(report, null, 2) + "\n",
  );
  if (!files.includes(reportPath)) files.push(reportPath);
  const inclusive = await bundle(files);
  if (inclusive > bound || inclusive > limit)
    throw Error("Complete inclusive bundle exceeds its recorded bound");
  console.log(
    JSON.stringify(
      { completeSnapshotBundleBytes: inclusive, ...report },
      null,
      2,
    ),
  );
} finally {
  await rm(scratch, { recursive: true, force: true });
}
