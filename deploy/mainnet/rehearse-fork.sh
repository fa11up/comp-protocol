#!/usr/bin/env bash
# Full rehearsal of the mainnet deployment on a local anvil fork of mainnet, and of the keeper against it.
#
#   deploy/mainnet/rehearse-fork.sh                      deploy + verify only
#   KEEPER_DIR=../imd-keeper deploy/mainnet/rehearse-fork.sh   + bark, bite and a Treasury-paid ask
#   BASE_FEE_WEI=1000000000 ...                              when mainnet gas would trip the deploy's ceiling
#
# It never touches this working tree: the repo is copied to a temp directory, plan.py converges the
# copy's DeploymentConfig with a throwaway operator, and the stand-ins it needs on a fork are put there
# with anvil cheats — a mock Intake at the INTAKE placeholder (the real one is the swarm developer's to
# deploy), a fixed ETH/USD over Chainlink (the clock is warped past its last round), and feed values
# written to storage (the attester's key is not ours). Keys are anvil's public test keys.
# FORK_URL must serve archive state for the fork block (eth.drpc.org did on 2026-10-05; publicnode
# refuses archive reads).
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
SRC=$(cd "$(dirname "$0")/../.." && pwd)
FORK_URL=${FORK_URL:-https://eth.drpc.org}
R=$(mktemp -d)/rehearse; K=${KEEPER_DIR:-}; [ -n "$K" ] && K=$(cd "$K" && pwd)
rsync -a --exclude web/node_modules --exclude /cache --exclude /broadcast --exclude /out "$SRC/" "$R/"
RPC=http://127.0.0.1:${PORT:-8546}
K0=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # deployer + keeper (acct 0)
A0=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
KB=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a   # borrower (acct 2)
AB=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
IMD=0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7; PM=0x000000000004444c5dc75cB358380D2e3dE08A90
CL=0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
c() { cast "$@" --rpc-url $RPC 2>/dev/null | tail -1 | awk '{print $1}'; }
c1() { cast "$@" --rpc-url $RPC 2>/dev/null | grep -v Warning | sed -n 1p | awk '{print $1}'; }

say() { echo; echo "=== $*"; }
say "fork + deploy"
# ANVIL_ARGS passes extra flags to anvil. BASE_FEE_WEI pins the fork's base fee by mining one block at it
# (anvil's own --base-fee does not take on a fork): use it when mainnet's base fee at the fork block would
# trip the deploy's gas ceiling. A rehearsal is about the deployment, not the price of gas that minute;
# the real deploy still waits for a cheaper block.
anvil --fork-url "$FORK_URL" --port ${PORT:-8546} --silent ${ANVIL_ARGS:-} > "$R/../anvil.log" 2>&1 &
ANVIL=$!; trap 'kill $ANVIL 2>/dev/null' EXIT
for i in $(seq 1 60); do cast chain-id --rpc-url $RPC >/dev/null 2>&1 && break; sleep 1; done
if [ -n "${BASE_FEE_WEI:-}" ]; then cast rpc anvil_setNextBlockBaseFeePerGas $(cast to-hex $BASE_FEE_WEI) --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null; fi
cd $R
python3 deploy/mainnet/plan.py --write --operator 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --intake 0x0000000000000000000000000000000000000F06
cast rpc anvil_setCode 0x0000000000000000000000000000000000000F06 "$(forge inspect MockIntake deployedBytecode | tail -1)" --rpc-url $RPC >/dev/null
# The deploy script now verifies the Intake sells oracle.request for IMD at or under ASK_MAX_PRICE, so the mock is priced BEFORE the deploy.
cast send 0x0000000000000000000000000000000000000F06 "setPrice(bytes32,address,uint256)" 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000 $IMD 500000000000000000 --private-key $K0 --rpc-url $RPC >/dev/null
ETHUSD=$(cast call $CL "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $RPC 2>/dev/null | sed -n 2p | awk '{print $1}')
echo "live ETH/USD answer $ETHUSD"
rm -rf deploy/mainnet/out/*.json
FOUNDRY_PROFILE=deploy OPERATOR=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 forge script script/DeployMainnet.s.sol --rpc-url $RPC --broadcast --slow --private-key $K0 2>&1 | grep -E "deployed|skipped|Deployed|Error|FAIL" 
D=$R/deploy/mainnet/out/deployment.json
j() { python3 -c "import json;print(json.load(open('$D'))['$1'])"; }
VAULT=$(j vault); PRICE=$(j priceFeed); NHI=$(j nhiFeed); SPOT=$(j spotFeed); STABLE=$(j stablecoin); ASKER=$(j oracleAsker)
cast rpc anvil_setCode $CL "$(forge inspect FixedEthUsd deployedBytecode | tail -1)" --rpc-url $RPC >/dev/null
cast rpc anvil_setStorageAt $CL 0x0 $(cast to-uint256 $ETHUSD) --rpc-url $RPC >/dev/null

seed() {  # feed value — slot 2 value, slot 3 = hasValue<<64 | updatedAt
  local ts; ts=$(cast block latest -f timestamp --rpc-url $RPC 2>/dev/null)
  cast rpc anvil_setStorageAt $1 0x2 $(cast to-uint256 $2) --rpc-url $RPC >/dev/null
  cast rpc anvil_setStorageAt $1 0x3 $(cast to-uint256 $(python3 -c "print((1<<64)+$ts)")) --rpc-url $RPC >/dev/null
}
POOLP=$(c call $ASKER "poolPrice()(uint256)")
say "seed feeds at the pool price $POOLP (storage writes: the attester's key is not ours)"
seed $PRICE $POOLP; seed $SPOT $POOLP; seed $NHI 900000000000000000
echo "stale? price $(c call $PRICE 'isStale()(bool)') nhi $(c call $NHI 'isStale()(bool)') spot $(c call $SPOT 'isStale()(bool)')"
# Runbook 7.1: the first values must sit on the pool before deposits open (DeployMainnet.verifySeeded).
FOUNDRY_PROFILE=deploy forge script script/DeployMainnet.s.sol --sig "verifySeeded()" --rpc-url $RPC 2>&1 | grep -E "Seeded and verified|seeded:|Error" | sed 's/^/  /'

say "borrower: 10,000 IMD from the PoolManager, lockIMD (wraps to sIMD), draw at ~175%"
cast rpc anvil_impersonateAccount $PM --rpc-url $RPC >/dev/null
cast rpc anvil_setBalance $PM 0x56BC75E2D63100000 --rpc-url $RPC >/dev/null
cast send $IMD "transfer(address,uint256)" $AB 10000000000000000000000 --from $PM --unlocked --rpc-url $RPC >/dev/null
cast send $IMD "approve(address,uint256)" $VAULT 10000000000000000000000 --private-key $KB --rpc-url $RPC >/dev/null
cast send $VAULT "lockIMD(uint256)" 10000000000000000000000 --private-key $KB --rpc-url $RPC >/dev/null
COLLP=$(c1 call $(j collateralPriceFeed) "latestValue()(uint256,uint64)")
COLL=$(c1 call $VAULT "positions(address)(uint256,uint256)" $AB)
DRAW=$(python3 -c "print($COLL*$COLLP//10**18*100//175)")
cast send $VAULT "draw(uint256)" $DRAW --private-key $KB --rpc-url $RPC >/dev/null
echo "collateral $COLL raw sIMD at $COLLP  drew $DRAW  CR $(c call $VAULT 'collateralRatio(address)(uint256)' $AB)%"
cast send $STABLE "transfer(address,uint256)" $A0 $(python3 -c "print($DRAW//2)") --private-key $KB --rpc-url $RPC >/dev/null
echo "keeper imdUSD inventory $(c call $STABLE 'balanceOf(address)(uint256)' $A0)"

if [ -z "$K" ]; then say "deploy verified; set KEEPER_DIR to rehearse the keeper"; exit 0; fi
cd $K
[ -f config.js ] && cp config.js config.js.before-rehearsal
# The keeper's own-IMD ledger is per UTC day: a second rehearsal the same day would start over budget,
# and a rehearsal must not leave its spending in a real keeper's ledger. Set aside, restored at the end.
[ -f state/spend.json ] && mv state/spend.json state/spend.json.before-rehearsal
cat > config.js <<EOF
export default {
  API_BASE: "https://api.imd.fun",
  DEPLOYMENT: "$D",
  MAINNET_RPC_URL: "$RPC", VAULT_RPC_URL: "$RPC",
  INDEXER: "rpc",
  POOL: { poolManager: "0x000000000004444c5dc75cb358380d2e3de08a90", poolId: "0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3", invert: false },
  MAX_GAS_GWEI: 1000, MIN_ETH: 0.02, ASK_PAID_IMD_PER_DAY: 50, KEEPER_ORACLE_FALLBACK: true,
  INTERVALS: { watchSeconds: 60, relaySeconds: 120, positionsSeconds: 300 },
};
EOF
export KEEPER_MNEMONIC="test test test test test test test test test test test junk"
say "keeper: report on a healthy book"
node positions.mjs | sed 's/^/  /'
say "keeper: watcher (asker mode)"
node watch.mjs | sed 's/^/  /' || true

say "IMD falls 5%: CR under mat"
DOWN=$(python3 -c "print($POOLP*95//100)"); seed $PRICE $DOWN; seed $SPOT $DOWN
echo "CR now $(c call $VAULT 'collateralRatio(address)(uint256)' $AB)%"
say "keeper --execute: expect a bark"
node positions.mjs --execute | sed 's/^/  /'
say "six hours pass (the lull at NHI 0.9); feeds re-dated"
cast rpc evm_increaseTime 21700 --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null
seed $PRICE $DOWN; seed $SPOT $DOWN; seed $NHI 900000000000000000
GEM0=$(c call $(j gem) "balanceOf(address)(uint256)" $A0)
say "keeper --execute: expect a bite"
node positions.mjs --execute | sed 's/^/  /'
GEM1=$(c call $(j gem) "balanceOf(address)(uint256)" $A0)
echo; echo "keeper sIMD received: $(( GEM1 - GEM0 )) raw   position now $(c call $VAULT 'positions(address)(uint256,uint256)' $AB)"
say "IMD falls ~11% below the feeds: the Treasury pays (fundOracle, arm, then ask 5 blocks later); a rise would not"
cast send 0x0000000000000000000000000000000000000F06 "setPrice(bytes32,address,uint256)" 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000 $IMD 500000000000000000 --private-key $K0 --rpc-url $RPC >/dev/null
HIGH=$(python3 -c "print($POOLP*112//100)"); seed $PRICE $HIGH; seed $SPOT $HIGH
node watch.mjs --execute | sed 's/^/  /' || true
for i in 1 2 3 4 5; do cast rpc evm_mine --rpc-url $RPC >/dev/null; done
say "five blocks later"
node watch.mjs --execute | sed 's/^/  /' || true
echo "asker IMD after: $(c call $IMD 'balanceOf(address)(uint256)' $ASKER)   intake IMD: $(c call $IMD 'balanceOf(address)(uint256)' 0x0000000000000000000000000000000000000F06)"

say "IMD rises 15% above the feeds: nobody pays for a rise, not the Treasury and not the keeper"
cast send $IMD "transfer(address,uint256)" $A0 50000000000000000000 --from $PM --unlocked --rpc-url $RPC >/dev/null
cast rpc evm_increaseTime 7300 --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null   # earlier asks time out
LOW=$(python3 -c "print($POOLP*100//115)"); seed $PRICE $LOW; seed $SPOT $LOW; seed $NHI 900000000000000000
K_IMD0=$(c call $IMD 'balanceOf(address)(uint256)' $A0)
node watch.mjs --execute | sed 's/^/  /' || true
K_IMD1=$(c call $IMD 'balanceOf(address)(uint256)' $A0)
echo "keeper IMD spent on the rise: $(python3 -c "print(($K_IMD0-$K_IMD1)/1e18)") (expect 0.0)"

say "IMD falls ~11% and an update costs more than the Treasury's daily budget: the keeper buys price + spot itself"
cast send 0x0000000000000000000000000000000000000F06 "setPrice(bytes32,address,uint256)" 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000 $IMD 20000000000000000000 --private-key $K0 --rpc-url $RPC >/dev/null
seed $PRICE $HIGH; seed $SPOT $HIGH; seed $NHI 900000000000000000
node watch.mjs --execute | sed 's/^/  /' || true
for i in 1 2 3 4 5; do cast rpc evm_mine --rpc-url $RPC >/dev/null; done
K_IMD2=$(c call $IMD 'balanceOf(address)(uint256)' $A0)
node watch.mjs --execute | sed 's/^/  /' || true
K_IMD3=$(c call $IMD 'balanceOf(address)(uint256)' $A0)
echo "keeper IMD spent as the Treasury's fallback: $(python3 -c "print(($K_IMD2-$K_IMD3)/1e18)") (expect 40.0: price + spot at 20 each)"

say "the feeds have been silent ten hours: their allowance has widened to 60% (WIDE_ALLOWANCE_BPS) and the Treasury refreshes them, no arming (keeper pays gas)"
cast send 0x0000000000000000000000000000000000000F06 "setPrice(bytes32,address,uint256)" 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000 $IMD 500000000000000000 --private-key $K0 --rpc-url $RPC >/dev/null
cast rpc evm_increaseTime 36100 --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null
echo "price feed epoch (anchor, openedAt, allowanceBps): $(cast call $PRICE 'epoch()(uint256,uint64,uint256)' --rpc-url $RPC | tr '\n' ' ')  (expect allowance 6000)"
I_IMD0=$(c call $IMD 'balanceOf(address)(uint256)' 0x0000000000000000000000000000000000000F06)
K_IMD4=$(c call $IMD 'balanceOf(address)(uint256)' $A0)
node watch.mjs --execute | sed 's/^/  /' || true
I_IMD1=$(c call $IMD 'balanceOf(address)(uint256)' 0x0000000000000000000000000000000000000F06)
K_IMD5=$(c call $IMD 'balanceOf(address)(uint256)' $A0)
echo "intake IMD received for the wide-open refresh: $(python3 -c "print(($I_IMD1-$I_IMD0)/1e18)") (expect 1.0: price + spot, paid by the Treasury's asker)   keeper IMD spent: $(python3 -c "print(($K_IMD4-$K_IMD5)/1e18)") (expect 0.0)"

say "the refreshes are delivered (re-dated by storage write: the mock Intake does not deliver); two hours on, past ASK_TIMEOUT, nobody is paid again (review of cc4103f)"
POOLNOW=$(c call $ASKER "poolPrice()(uint256)")
seed $PRICE $POOLNOW; seed $SPOT $POOLNOW; seed $NHI 900000000000000000   # at the market, so no fall and no keep-alive is due
echo "price feed wideOpen after delivery: $(cast call $ASKER 'wideOpen(address)(bool)' $PRICE --rpc-url $RPC)  (expect false: fresh)"
cast rpc evm_increaseTime 7300 --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null
echo "two hours on, price feed wideOpen: $(cast call $ASKER 'wideOpen(address)(bool)' $PRICE --rpc-url $RPC)  (expect false: stale, but its allowance is 40%)"
node watch.mjs --execute | sed 's/^/  /' || true
I_IMD2=$(c call $IMD 'balanceOf(address)(uint256)' 0x0000000000000000000000000000000000000F06)
K_IMD6=$(c call $IMD 'balanceOf(address)(uint256)' $A0)
echo "intake IMD received on the second pass: $(python3 -c "print(($I_IMD2-$I_IMD1)/1e18)") (expect 0.0)   keeper IMD spent: $(python3 -c "print(($K_IMD5-$K_IMD6)/1e18)") (expect 0.0)"

[ -f config.js.before-rehearsal ] && mv config.js.before-rehearsal config.js || rm -f config.js
[ -f state/spend.json.before-rehearsal ] && mv state/spend.json.before-rehearsal state/spend.json || rm -f state/spend.json
