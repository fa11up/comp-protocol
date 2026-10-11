#!/usr/bin/env python3
"""The governance Safe's first transaction: list sIMD as a Treasury reserve asset, as a Safe Transaction Builder file.

    deploy/mainnet/safe-tx.py reserve --haircut-bps 5000 --rpc <url>           write the file
    deploy/mainnet/safe-tx.py reserve --haircut-bps 5000 --rpc <fork> --fork   and prove it end to end on a fork

It reads Parameters, the collateral (sIMD) and the vault's own collateral price feed from the deployment record,
encodes `Parameters.proposeReserveAsset(sIMD, collateralPriceFeed, haircutBps)` and asks the Treasury's own
`validateReserveAsset` first, so a listing the register would refuse never reaches the Safe. The file goes to
deploy/mainnet/out/safe/; load it at app.safe.global -> Apps -> Transaction Builder -> drag and drop, review, and
collect two of the three signatures.

The change waits 48 hours (Governed.TIMELOCK), then ANYONE applies it:
    cast send <Parameters> "applyPending()" ...
Only one change can be pending at a time: while this one waits, no other parameter can be proposed. A haircut is
changed later the same way (propose the same asset again with the new figure).

--fork impersonates the Safe on a local fork, proposes, warps past the delay, applies, and checks the Treasury now
lists sIMD at the haircut with that price feed. It never runs against a non-local RPC.
"""
import argparse, json, os, re, subprocess, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
REC = os.path.join(ROOT, "deploy/mainnet/out/deployment.json")
OUT = os.path.join(ROOT, "deploy/mainnet/out/safe")


def sh(*a, check=True):
    r = subprocess.run(a, cwd=ROOT, capture_output=True, text=True, stdin=subprocess.DEVNULL,
                       env={**os.environ, "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1"})
    if check and r.returncode != 0:
        raise SystemExit(f"safe-tx: {' '.join(a[:3])}… failed: {(r.stderr or r.stdout).strip()[-300:]}")
    return r.stdout.strip()


def operator():
    src = open(os.path.join(ROOT, "src/DeploymentConfig.sol")).read()
    return re.search(r"APPROVED_OPERATOR\s*=\s*(0x[0-9a-fA-F]{40})", src).group(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("what", choices=["reserve"])
    ap.add_argument("--haircut-bps", type=int, required=True)
    ap.add_argument("--rpc", required=True)
    ap.add_argument("--fork", action="store_true")
    o = ap.parse_args()
    if not 0 < o.haircut_bps <= 10_000:
        raise SystemExit("safe-tx: --haircut-bps is the share that counts, 1..10000 (5000 = 50%)")
    local = bool(re.match(r"^https?://(127\.0\.0\.1|localhost)(:|/|$)", o.rpc))
    if o.fork and not local:
        raise SystemExit("safe-tx: --fork takes a local fork only")

    rec = json.load(open(REC))
    params, gem, feed, treasury = (rec[k] for k in ("parameters", "gem", "collateralPriceFeed", "treasury"))
    safe = operator()
    # The Treasury's own rules, asked before anything is written: a refusal here would refuse at proposal too.
    sh("cast", "call", treasury, "validateReserveAsset(address,address,uint256)", gem, feed, str(o.haircut_bps), "--rpc-url", o.rpc)
    data = sh("cast", "calldata", "proposeReserveAsset(address,address,uint256)", gem, feed, str(o.haircut_bps))
    pct = o.haircut_bps / 100
    batch = {
        "version": "1.0",
        "chainId": str(rec["chainId"]),
        "createdAt": int(time.time() * 1000),
        "meta": {
            "name": f"List sIMD as a reserve asset at {pct:g}%",
            "description": (
                f"Parameters.proposeReserveAsset(sIMD {gem}, collateralPriceFeed {feed}, haircutBps {o.haircut_bps}). "
                f"Queues the listing for 48 hours; then anyone calls Parameters.applyPending(). "
                f"sIMD then counts at {pct:g}% of its value in the Treasury's reserve."
            ),
            "txBuilderVersion": "1.18.0",
            "createdFromSafeAddress": safe,
            "createdFromOwnerAddress": "",
        },
        "transactions": [{"to": params, "value": "0", "data": data, "contractMethod": None, "contractInputsValues": None}],
    }
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, f"reserve-simd-{o.haircut_bps}.json")
    json.dump(batch, open(path, "w"), indent=2)
    print(f"safe-tx: wrote {os.path.relpath(path, ROOT)}")
    print(f"  Safe        {safe}")
    print(f"  to          Parameters {params}")
    print(f"  call        proposeReserveAsset({gem}, {feed}, {o.haircut_bps})")
    print(f"  data        {data[:42]}…")
    print(f"  then, 48 h after it executes, anyone: cast send {params} 'applyPending()'")

    if not o.fork:
        return
    print("safe-tx: proving it on the fork")
    rpc = ["--rpc-url", o.rpc]
    sh("cast", "rpc", "anvil_impersonateAccount", safe, *rpc)
    sh("cast", "rpc", "anvil_setBalance", safe, "0x56BC75E2D63100000", *rpc)
    sh("cast", "send", "--unlocked", "--from", safe, params, data, *rpc)
    sh("cast", "rpc", "anvil_stopImpersonatingAccount", safe, *rpc)
    eta = int(sh("cast", "call", params, "pendingEta()(uint256)", *rpc).split()[0])
    now = int(sh("cast", "block", "latest", "-f", "timestamp", *rpc))
    print(f"  proposed: applies in {(eta - now) / 3600:.1f} h")
    r = subprocess.run(["cast", "send", "--unlocked", "--from", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", params,
                        "applyPending()", *rpc], cwd=ROOT, capture_output=True, text=True)
    assert r.returncode != 0, "applying before the delay must refuse"
    print("  applying before the delay: refused")
    sh("cast", "rpc", "evm_increaseTime", str(eta - now + 1), *rpc)
    sh("cast", "rpc", "evm_mine", *rpc)
    # Anyone applies: a stranger (anvil's test account 1), not the Safe.
    sh("cast", "send", "--unlocked", "--from", "0x70997970C51812dc3A010C7d01b50e0d17dc79C8", params, "applyPending()", *rpc)
    listed = sh("cast", "call", treasury, "reserveAsset(address)((address,uint256,uint8))", gem, *rpc)
    print(f"  applied by a stranger; Treasury.reserveAsset(sIMD) = {listed}")
    f, h, _ = listed.strip("()").split(", ")
    assert f.lower() == feed.lower() and int(h.split()[0]) == o.haircut_bps, listed
    print(f"safe-tx: proven: sIMD listed with the vault's collateral price feed at {o.haircut_bps} bps")


if __name__ == "__main__":
    main()
