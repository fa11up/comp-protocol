#!/usr/bin/env python3
"""Source verification for every contract of a mainnet deployment, from the deployment record alone.

    deploy/mainnet/verify.py --rpc <url> [--submit] [--vault-salt 0x..]

Without --submit it is a dry run: it rebuilds each contract's constructor arguments and PROVES them before
anything is sent to an explorer:
  * a contract the deploy script placed by CREATE2 (relay, factories, feeds, OracleAsker, and the vault when its
    secret salt is given) must land at its recorded address from salt + compiled creation code + those arguments;
  * a contract another constructor created (Parameters, Treasury, imdUSD, the USD and sIMD price feeds, the work
    oracle) is created again on a LOCAL fork from the same arguments, by the same creator, and its runtime code
    must equal the deployed one byte for byte (immutables come from the arguments, so a wrong one shows).
With --submit it then verifies each on Etherscan (ETHERSCAN_API_KEY) and Sourcify; Blockscout imports from both.
A contract already verified counts as done. Nothing here signs or sends a transaction to mainnet.

Arguments come from the chain where the chain holds them (feed maxAge and deviation cap, the asker's pinned
body hashes, the work oracle's maxAge) and from src/DeploymentConfig.sol otherwise, never from memory.
"""
import argparse, json, os, re, subprocess, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
REC = os.path.join(ROOT, "deploy/mainnet/out/deployment.json")
CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
ZERO = "0x" + "0" * 40


def sh(*args, check=True):
    r = subprocess.run(args, cwd=ROOT, capture_output=True, text=True, stdin=subprocess.DEVNULL,
                       env={**os.environ, "FOUNDRY_DISABLE_NIGHTLY_WARNING": "1"})
    if check and r.returncode != 0:
        raise SystemExit(f"verify: {' '.join(args[:3])}… failed: {(r.stderr or r.stdout).strip()[-400:]}")
    return r


def out(*args):
    return sh(*args).stdout.strip().splitlines()[-1].strip()


def call(rpc, addr, sig, *a):
    return out("cast", "call", addr, sig, *a, "--rpc-url", rpc).split(" ")[0]


def code(rpc, addr):
    return out("cast", "code", addr, "--rpc-url", rpc).lower()


def masked(rpc, addr):
    """Runtime code with the contract's own EIP-712 domain separator zeroed: a SwarmFeed keeps it as an immutable
    and it includes address(this), so two copies differ there and only there. Every other byte must match."""
    c = code(rpc, addr)
    r = sh("cast", "call", addr, "DOMAIN_SEPARATOR()(bytes32)", "--rpc-url", rpc, check=False)
    if r.returncode == 0 and r.stdout.strip().startswith("0x"):
        c = c.replace(r.stdout.strip().lower()[2:], "0" * 64)
    return c


def creation(name):
    return out("forge", "inspect", name, "bytecode").lower()


def encode(sig, *a):
    return out("cast", "abi-encode", sig, *a).lower()


def create2(salt, initcode):
    return out("cast", "compute-address", "--salt", salt, "--init-code", initcode, CREATE2_FACTORY).split()[-1].lower()


def config_const(name):
    src = open(os.path.join(ROOT, "src/DeploymentConfig.sol")).read()
    m = re.search(rf"\b{name}\s*=\s*(0x[0-9a-fA-F]{{40}})", src)
    if not m:
        raise SystemExit(f"verify: {name} not found in src/DeploymentConfig.sol")
    return m.group(1)


def salt(name):
    return out("cast", "keccak", f"infer-protocol/mainnet/v1/{name}")


def plan(rpc, rec, vault_salt):
    """[(name, address, args, proof)] where proof is ('create2', salt) or ('creator', address)."""
    lc = lambda a: a.lower()
    price, nhi, spot, asker, vault = (lc(rec[k]) for k in ("priceFeed", "nhiFeed", "spotFeed", "oracleAsker", "vault"))
    feed_args = {f: encode("f(uint256,uint256)", call(rpc, f, "maxAge()(uint256)"), call(rpc, f, "maxDeviationBps()(uint256)"))
                 for f in (price, nhi, spot)}
    # feeds(feed) = (bodyHash, tracksPool, keepAlive, ...): the asker's own record of what it was built with
    full = [sh("cast", "call", asker, "feeds(address)(bytes32,bool,bool,uint64,uint64,uint64,bool,bytes32)", f,
               "--rpc-url", rpc).stdout.split() for f in (price, nhi, spot)]
    hashes = [r[0] for r in full]
    tracks = [r[1] for r in full]
    alive = [r[2] for r in full]
    imd = call(rpc, asker, "payToken()(address)")
    asker_args = encode("f(address,address[],bytes32[],bool[],bool[])", imd, f"[{price},{nhi},{spot}]",
                        f"[{','.join(hashes)}]", f"[{','.join(tracks)}]", f"[{','.join(alive)}]")
    gem = lc(call(rpc, vault, "gem()(address)"))
    vault_args = encode("f(address,address,address,address,address,address)", gem, ZERO,
                        config_const("WORK_ORACLE_SENTINEL"), price, nhi, spot)
    stable, params, treasury, usd, coll, work = (lc(call(rpc, vault, f"{fn}()(address)")) for fn in
                                                 ("stablecoin", "parameters", "treasury", "usdPriceFeed", "collateralPriceFeed", "oracle"))
    work_factory = create2(salt("WorkOracleFactory"), creation("WorkOracleFactory"))
    treasury_factory = create2(salt("TreasuryFactory"), creation("TreasuryFactory"))
    items = [
        ("SwarmRelay", lc(rec["relay"]), "", ("create2", salt("SwarmRelay"))),
        ("WorkOracleFactory", work_factory, "", ("create2", salt("WorkOracleFactory"))),
        ("PriceFeed", price, feed_args[price], ("create2", salt("PriceFeed"))),
        ("NhiFeed", nhi, feed_args[nhi], ("create2", salt("NhiFeed"))),
        ("SpotFeed", spot, feed_args[spot], ("create2", salt("SpotFeed"))),
        ("OracleAsker", asker, asker_args, ("create2", salt("OracleAsker"))),
        ("TreasuryFactory", treasury_factory, "", ("create2", salt("TreasuryFactory"))),
        ("ParameterizedVault", vault, vault_args, ("create2", vault_salt) if vault_salt else ("none", None)),
        ("ImdUSD", stable, encode("f(address)", vault), ("creator", vault)),
        ("Parameters", params, encode("f(address)", vault), ("creator", vault)),
        ("Treasury", treasury, encode("f(address)", vault), ("creator", treasury_factory)),
        ("UsdPriceFeed", usd, encode("f(address)", price), ("creator", vault)),
        ("SwarmWorkOracle", work, encode("f(address,uint256)", vault, call(rpc, work, "maxAge()(uint256)")), ("creator", work_factory)),
    ]
    if coll != usd:  # sIMD collateral: the vault built a SharePriceFeed over the USD feed
        items.append(("SharePriceFeed", coll, encode("f(address,address)", gem, usd), ("creator", vault)))
    return items


def prove(rpc, items, fork):
    ok = True
    for name, addr, args, (kind, ref) in items:
        args_hex = args[2:] if args.startswith("0x") else args
        initcode = creation(name) + args_hex
        if kind == "create2":
            got = create2(ref, initcode)
            good = got == addr
            how = f"CREATE2 address {'matches' if good else 'is ' + got}"
        elif kind == "creator":
            if not fork:
                print(f"  -    {name:<19} {addr}  (runtime proof needs a local fork; skipped)")
                continue
            # Create it again from the claimed arguments, as its real creator, and compare the runtime code.
            sh("cast", "rpc", "anvil_impersonateAccount", ref, "--rpc-url", rpc)
            sh("cast", "rpc", "anvil_setBalance", ref, "0x56BC75E2D63100000", "--rpc-url", rpc)
            r = sh("cast", "send", "--unlocked", "--from", ref, "--rpc-url", rpc, "--json", "--create", initcode, check=False)
            sh("cast", "rpc", "anvil_stopImpersonatingAccount", ref, "--rpc-url", rpc)
            if r.returncode != 0:
                good, how = False, f"re-creation reverted: {(r.stderr or r.stdout).strip()[-160:]}"
            else:
                again = json.loads(r.stdout)["contractAddress"]
                good = masked(rpc, again) == masked(rpc, addr)
                how = f"runtime code {'identical' if good else 'DIFFERS'} when re-created from these arguments"
        else:
            good, how = True, "no secret salt given: arguments from the record, address not re-derived"
        ok &= good
        print(f"  {'ok ' if good else 'BAD'}  {name:<19} {addr}  {how}")
    return ok


def submit(items, key):
    failed = []
    for name, addr, args, _ in items:
        base = ["forge", "verify-contract", addr, f"src/{name}.sol:{name}", "--chain", "1", "--watch"]
        if args:
            base += ["--constructor-args", args]
        for verifier, extra in (("etherscan", ["--etherscan-api-key", key]), ("sourcify", ["--verifier", "sourcify"])):
            r = sh(*base, *extra, check=False)
            text = (r.stdout + r.stderr).lower()
            done = r.returncode == 0 or "already verified" in text or "is already verified" in text
            print(f"  {'ok ' if done else 'ERR'}  {verifier:<9} {name:<19} {addr}"
                  + ("" if done else f"  {text.strip().splitlines()[-1][:160] if text.strip() else ''}"))
            if not done:
                failed.append((verifier, name))
    return failed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rpc", required=True)
    ap.add_argument("--submit", action="store_true")
    ap.add_argument("--vault-salt", default=os.environ.get("VAULT_SALT"))
    o = ap.parse_args()
    rec = json.load(open(REC))
    if not rec.get("vault"):
        raise SystemExit("verify: the record has no vault yet; run it after stage two")
    fork = bool(re.match(r"^https?://(127\.0\.0\.1|localhost)(:|/|$)", o.rpc))
    print(f"verify: {len(rec)} record fields; proving constructor arguments ({'local fork' if fork else 'mainnet, read only'})")
    items = plan(o.rpc, rec, o.vault_salt)
    if not prove(o.rpc, items, fork):
        raise SystemExit("verify: an argument did not prove out; nothing submitted")
    if not o.submit:
        print("verify: dry run passed; --submit sends them to Etherscan and Sourcify")
        return
    if fork:
        raise SystemExit("verify: --submit refuses a local fork (explorers cannot see it)")
    key = os.environ.get("ETHERSCAN_API_KEY")
    if not key:
        raise SystemExit("verify: ETHERSCAN_API_KEY is not set (deploy/mainnet/.etherscan.local or launch.env)")
    failed = submit(items, key)
    if failed:
        raise SystemExit(f"verify: {len(failed)} submission(s) failed; rerun 'launch.sh verify' (verified ones are skipped)")
    print(f"verify: all {len(items)} contracts verified on Etherscan and Sourcify")


if __name__ == "__main__":
    main()
