#!/usr/bin/env bash
# Relay the attested price into launch 688's PriceFeed, then seed SpotFeed and NhiFeed from it.
#
# ONE command, two transactions plus two more inside the forge script. Everything is dry-run and
# read back, so a failure stops before the next step rather than leaving the stack half-seeded.
#
#   ./oracle/relay-and-seed-688.sh --mnemonic-path ~/w0.txt
#   ./oracle/relay-and-seed-688.sh --account w0        # if W0 is a foundry keystore
#
# WHY W0: relaying is permissionless (SwarmRelay.relay has no caller check, so any funded address
# works), but `report` is gated on `isReporter` and ONLY W0 holds that on all three feeds —
# miyagod.eth does not. So the seeding half needs W0 regardless.
#
# TESTNET ONLY for the seeding half: it uses the reporter fallback, the mainnet hole this protocol
# is deleting. See script/SeedLaunch688.s.sol.
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

RPC="${SEPOLIA_RPC_URL:-https://ethereum-sepolia-rpc.publicnode.com}"
W0=0x1d0074aB2ba9dA4cCbc67cFC0026E570D0E93951
FEED=0x5bbFA44200AcE481388B0B69355F7Bd1FeAb0462
RELAY=0xe36FFc2688Bf5974f2187AC9086492e372926D40
ATT="$(dirname "$0")/attestation-e2c85027.json"

[ $# -ge 1 ] || { echo "usage: $0 --mnemonic-path <file> | --account <name>"; exit 1; }
SIGNER_ARGS=("$@")

SIG='relay(address,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)'
TUP=$(python3 -c "
import json,sys
m=json.load(open('$ATT'))['message']
t={'bool':0,'address':1,'bytes32':2,'uint256':3}[m['answerType']]
print(f\"({m['requestId']},{m['chainId']},{m['questionHash']},{t},{m['answer']},{m['figure']},\"
      f\"{m['fromBlock']},{m['toBlock']},{m['blockHash']},{m['panelJobId']},{m['panelSize']},\"
      f\"{m['quorum']},{m['agreed']},{m['issuedAt']},{m['expiresAt']})\")")
ATTSIG=$(python3 -c "import json;print(json.load(open('$ATT'))['signature'])")
FIGURE=$(python3 -c "import json;print(json.load(open('$ATT'))['message']['figure'])")

echo "== 0. state before"
BEFORE=$(cast call "$FEED" "latestValue()(uint256,uint256)" --rpc-url "$RPC" | head -1)
echo "   PriceFeed value: $BEFORE"
if [ "$BEFORE" != "0" ]; then
  echo "   PriceFeed already holds a value. If that is this attestation, skip to step 2."
fi

echo "== 1. dry run the relay"
cast call "$RELAY" "$SIG" "$FEED" "$TUP" "$ATTSIG" --from "$W0" --rpc-url "$RPC" >/dev/null
echo "   OK — would succeed"

echo "== 2. relay (transaction)"
cast send "$RELAY" "$SIG" "$FEED" "$TUP" "$ATTSIG" \
  --rpc-url "$RPC" "${SIGNER_ARGS[@]}" | grep -E 'transactionHash|status'

echo "== 3. read the feed back off chain"
GOT=$(cast call "$FEED" "latestValue()(uint256,uint256)" --rpc-url "$RPC" | head -1)
echo "   PriceFeed value: $GOT"
echo "   attested figure: $FIGURE"
[ "$GOT" = "$FIGURE" ] || { echo "   MISMATCH — stopping before the seed"; exit 1; }
cast call "$FEED" "usedRequests(bytes32)(bool)" \
  "$(python3 -c "import json;print(json.load(open('$ATT'))['message']['requestId'])")" \
  --rpc-url "$RPC" | sed 's/^/   replay protection engaged: /'

echo "== 4. seed SpotFeed and NhiFeed from the attested price"
forge script script/SeedLaunch688.s.sol --rpc-url "$RPC" --broadcast "${SIGNER_ARGS[@]}" \
  | grep -E 'PriceFeed value|SpotFeed value|NhiFeed value|divergence|minCR|SEEDED'

echo
echo "DONE. The vault can price. Verify independently:"
echo "  cast call 0x850B0d7a6dD95bE3e842c0ef14EEFE0008f2c68F 'minCR()(uint256)' --rpc-url $RPC"
