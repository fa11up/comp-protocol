#!/usr/bin/env python3
"""Offline nonzero-rate check of actual vault source with one scratch-only constant change.

Run from any directory with `python3 test/check_stability_fee.py`. This is supplemental:
`forge test` exercises the shipped zero rate and explicitly skips the nonzero cases.
No source/configuration outside test/scratch is written, and the variant is removed on exit.
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def main():
    scratch = ROOT / "test" / "scratch"
    scratch.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="stability-rate-1000-", dir=scratch) as temporary:
        variant = Path(temporary)
        shutil.copytree(ROOT / "src", variant / "src")
        (variant / "test" / "helpers").mkdir(parents=True)
        for relative in ("test/StabilityFee.t.sol", "test/helpers/TestSwarmFeed.sol", "foundry.toml", "remappings.txt"):
            shutil.copyfile(ROOT / relative, variant / relative)
        # Dependencies are the repository's committed libraries; the variant needs no network.
        (variant / "lib").symlink_to(ROOT / "lib", target_is_directory=True)
        config = variant / "src" / "DeploymentConfig.sol"
        original = config.read_text()
        old = "STABILITY_FEE_BPS = 0;"
        replacement = "STABILITY_FEE_BPS = 1_000;"
        if original.count(old) != 1:
            raise RuntimeError("Expected exactly one pinned zero stability rate")
        config.write_text(original.replace(old, replacement))
        for source in (ROOT / "src").rglob("*.sol"):
            relative = source.relative_to(ROOT)
            expected = source.read_bytes()
            if relative == Path("src/DeploymentConfig.sol"):
                expected = expected.replace(old.encode(), replacement.encode())
            if (variant / relative).read_bytes() != expected:
                raise RuntimeError(f"Unexpected source variant: {relative}")
        env = os.environ.copy()
        env.update(
            FOUNDRY_TEST="test",
            FOUNDRY_SRC="src",
            FOUNDRY_OUT=str(variant / "artifacts"),
            FOUNDRY_CACHE_PATH=str(variant / "cache"),
        )
        print("Scratch source variant: only STABILITY_FEE_BPS changes from 0 to 1,000", flush=True)
        subprocess.run(
            ["forge", "test", "--offline", "--root", str(variant),
             "--match-contract", "^NonzeroStabilityFeeTest$", "-vv"],
            cwd=variant,
            env=env,
            check=True,
        )


if __name__ == "__main__":
    main()
