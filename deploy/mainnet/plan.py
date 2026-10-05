#!/usr/bin/env python3
"""Converge src/DeploymentConfig.sol on the mainnet CREATE2 plan.

    python3 deploy/mainnet/plan.py                       report only; exit 1 while anything must change
    python3 deploy/mainnet/plan.py --write \\
        --operator 0x<cold governance> --intake 0x<the swarm's Intake>

`--write` sets APPROVED_OPERATOR and FEE_RECIPIENT to the cold governance address and INTAKE to the
Intake the swarm's developer deployed, then repeatedly runs `DeployMainnet.check()` and writes the
addresses it plans (ATTESTATION_RELAYER, WORK_ORACLE_FACTORY, ORACLE_ASKER, TREASURY_FACTORY,
CHAINLINK_ETH_USD) until a pass changes nothing. Each pass settles one dependency layer, so it
converges in at most five. Nothing is broadcast and nothing is committed: review the diff, run the
suites, commit, and that commit is what the scoped pre-deploy review and the broadcast both use.

This rewrites constants that the test suite's Sepolia fork tests depend on, so do it on a release
branch, never on main.
"""
import argparse, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "src" / "DeploymentConfig.sol"
ADDR = re.compile(r"^0x[0-9a-fA-F]{40}$")


def checksum(addr):
    out = subprocess.run(["cast", "to-check-sum-address", addr], capture_output=True, text=True, check=True)
    return out.stdout.strip().splitlines()[-1]


def set_constant(text, name, addr):
    pattern = re.compile(rf"^(address constant {name} = )0x[0-9a-fA-F]{{40}};", re.M)
    if not pattern.search(text):
        sys.exit(f"{name} not found in DeploymentConfig.sol")
    return pattern.sub(lambda m: m.group(1) + checksum(addr) + ";", text, count=1)


def check():
    out = subprocess.run(
        ["forge", "script", "script/DeployMainnet.s.sol", "--sig", "check()"],
        cwd=ROOT, capture_output=True, text=True,
    )
    if out.returncode:
        sys.exit(out.stdout[-3000:] + out.stderr[-3000:])
    rows = re.findall(r"CONFIG (\w+) (0x[0-9a-fA-F]{40}) (ok|CHANGE)", out.stdout)
    if len(rows) != 5:
        sys.exit("unexpected check() output:\n" + out.stdout[-3000:])
    plan = re.findall(r"^\s+(\w+)\s+(0x[0-9a-fA-F]{40})$", out.stdout, re.M)
    return rows, plan


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--operator")
    ap.add_argument("--intake")
    a = ap.parse_args()

    if a.write:
        if not (a.operator and ADDR.match(a.operator) and a.intake and ADDR.match(a.intake)):
            sys.exit("--write needs --operator and --intake, each a 0x address")
        text = CONFIG.read_text()
        for name in ("APPROVED_OPERATOR", "FEE_RECIPIENT"):
            text = set_constant(text, name, a.operator)
        text = set_constant(text, "INTAKE", a.intake)
        CONFIG.write_text(text)

    for n in range(1, 7):
        rows, plan = check()
        pending = [(name, addr) for name, addr, state in rows if state == "CHANGE"]
        print(f"pass {n}: " + ("converged" if not pending else ", ".join(name for name, _ in pending)))
        if not pending:
            for name, addr in plan:
                print(f"  {name:<19} {addr}")
            return 0
        if not a.write:
            for name, addr in pending:
                print(f"  {name} must be {addr}")
            return 1
        text = CONFIG.read_text()
        for name, addr in pending:
            text = set_constant(text, name, addr)
        CONFIG.write_text(text)
    sys.exit("did not converge in six passes: something in the dependency graph is cyclic")


if __name__ == "__main__":
    sys.exit(main())
