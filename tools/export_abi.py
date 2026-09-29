#!/usr/bin/env python3
"""Export compiled ABI arrays. Requires Python 3 and the project's pinned Solidity compiler."""

import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if committed ABI exports differ")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    subprocess.run(["forge", "build"], cwd=root, check=True)
    names = ("LaunchToken", "MockIMD", "CompToken", "IWorkOracle", "MockWorkOracle", "CDPVault")
    for name in names:
        artifact = json.loads((root / "out" / f"{name}.sol" / f"{name}.json").read_text())
        rendered = json.dumps(artifact["abi"], indent=2) + "\n"
        destination = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not destination.exists() or destination.read_text() != rendered:
                raise SystemExit(f"Stale or missing ABI: {destination.relative_to(root)}")
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(rendered)
        print(f"{'Checked' if args.check else 'Exported'} {destination.relative_to(root)}")


if __name__ == "__main__":
    main()
