#!/usr/bin/env python3
"""Offline vault regression checks; all generated files and parameter variants stay in test/scratch."""

import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[2]
SCRATCH = ROOT / "test" / "scratch" / "vault-checks"


def check(root, artifacts, *selection):
    env = os.environ.copy()
    env.update(
        FOUNDRY_TEST="script/checks",
        FOUNDRY_OUT=str(artifacts / "out"),
        FOUNDRY_CACHE_PATH=str(artifacts / "cache"),
    )
    subprocess.run(
        ["forge", "test", "--offline", "--root", str(root),
         "--match-path", "script/checks/CDPVault*.t.sol", *selection],
        cwd=root, env=env, check=True,
    )


def variant(name, old, new):
    root = SCRATCH / name
    for directory in ("src", "script"):
        shutil.copytree(ROOT / directory, root / directory, dirs_exist_ok=True)
    for filename in ("foundry.toml", "remappings.txt"):
        shutil.copyfile(ROOT / filename, root / filename)
    if not (root / "lib").exists():
        (root / "lib").symlink_to(ROOT / "lib", target_is_directory=True)
    config = root / "src" / "DeploymentConfig.sol"
    text = config.read_text()
    if text.count(old) != 1:
        raise RuntimeError(f"Expected pinned setting not found: {old}")
    config.write_text(text.replace(old, new))
    return root


def main():
    SCRATCH.mkdir(parents=True, exist_ok=True)
    print("Checking the shipped configuration", flush=True)
    check(ROOT, SCRATCH / "default")
    print("Checking a scratch-only 10% annual stability fee", flush=True)
    fee = variant("fee-1000", "STABILITY_FEE_BPS = 0;", "STABILITY_FEE_BPS = 1_000;")
    check(fee, fee / "artifacts", "--match-contract", "CDPVaultIncrementTest",
          "--match-test", "(fee|Fee|borrowCheckpoint)")
    print("Checking identical borrower loss with the marker share disabled in scratch", flush=True)
    marker = variant("marker-zero", "MARKER_SHARE_BPS = 1_000;", "MARKER_SHARE_BPS = 0;")
    check(marker, marker / "artifacts", "--match-contract", "CDPVaultIncrementTest",
          "--match-test", "(marker|Marker|[Ss]hare|[Bb]onus)")


if __name__ == "__main__":
    main()
