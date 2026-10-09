#!/usr/bin/env bash
# The mainnet deploy, run by hand, with the deployer's key kept on a RAM disk that is ejected at the end.
#
#   deploy/mainnet/launch.sh ramdisk    make the RAM disk and a key file template on it (nothing touches the SSD)
#   deploy/mainnet/launch.sh status     who signs, who governs, what is deployed so far (never prints the key)
#   deploy/mainnet/launch.sh stage1     relay, factories, the three feeds, the oracle asker (runbook 6)
#   deploy/mainnet/launch.sh check      verifySeeded: the first values against the pool and an outside reference (runbook 7.2)
#   deploy/mainnet/launch.sh vault      stage two, through MEV Blocker's full-privacy RPC, with a fresh secret salt
#   deploy/mainnet/launch.sh wipe       eject the RAM disk: the key, the salt and the file are gone
#
# The key file is /Volumes/INFERLAUNCH/launch.env. Edit it with `nano` (TextEdit keeps versions; never paste the key
# into a shell prompt, where it would land in history). Every broadcast is simulated first and waits for you to type SEND.
#
# Rehearsal (runbook rehearsal 2): FORK=1 with MAINNET_RPC_URL pointing at a local anvil fork. Fork mode refuses any
# RPC that is not local, and real mode refuses a local one, so a rehearsal cannot reach mainnet by a typo.
#
# The key reaches forge and cast as --private-key: foundry reads it from no environment variable. It is visible
# to processes of the same user while a command runs, which on a single-user laptop is no wider than the file itself.
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
cd "$(dirname "$0")/../.."

VOL=INFERLAUNCH; RD=/Volumes/$VOL; ENVF=$RD/launch.env
DEPLOYER=${EXPECTED_DEPLOYER:-0x5167D014a056E43883e1BBEa5530c3c0dC993281}   # miyagod.eth
PRIVATE_RPC=https://rpc.mevblocker.io/fullprivacy
SCRIPT=script/DeployMainnet.s.sol
REC=deploy/mainnet/out/deployment.json

die() { echo "launch: $*" >&2; exit 1; }
lc() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

ramdisk() {
  [ -d "$RD" ] && die "$RD is already mounted. Run 'wipe' first if it is left over from an earlier run."
  local dev; dev=$(hdiutil attach -nomount ram://65536 | awk '{print $1}')   # 32 MB
  diskutil erasevolume HFS+ "$VOL" "$dev" >/dev/null
  touch "$RD/.metadata_never_index"                 # no Spotlight index of the key
  tmutil addexclusion "$RD" >/dev/null 2>&1 || true     # no Time Machine copy
  ( umask 077; cat > "$ENVF" <<'EOT'
# Fill in, save, and leave the editor. This file lives in memory only and is gone at `launch.sh wipe`.
PRIVATE_KEY=
# the cold governance address: must equal APPROVED_OPERATOR in src/DeploymentConfig.sol, and must not be the deployer
OPERATOR=
# your own RPC for reads and stage one (Chainstack etc.). Stage two always goes through MEV Blocker's full-privacy RPC.
MAINNET_RPC_URL=
# filled in at `check` time: IMD's price in wei of ETH per 1e18 IMD from a source the pool cannot be held against,
# and the network health index from api.imd.fun/swarm, 1e18-scaled
REFERENCE_IMD_ETH_WEI=
REFERENCE_NHI=
EOT
  )
  echo "RAM disk ready: $RD ($dev). Now:  nano $ENVF"
}

load() {
  [ -f "$ENVF" ] || die "no $ENVF. Run 'ramdisk' first."
  hdiutil info | grep -q "$RD" || die "$RD is not a disk image mount. The key file must live on the RAM disk."
  set -a; . "$ENVF"; set +a
  [[ "${PRIVATE_KEY:-}" =~ ^(0x)?[0-9a-fA-F]{64}$ ]] || die "PRIVATE_KEY is missing or not 32 bytes of hex."
  [[ "$PRIVATE_KEY" == 0x* ]] || PRIVATE_KEY=0x$PRIVATE_KEY
  SIGNER=$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null | tail -1)
  [ "$(lc "$SIGNER")" = "$(lc "$DEPLOYER")" ] || die "the key signs as $SIGNER, not the deployer $DEPLOYER."
  [ -n "${OPERATOR:-}" ] || die "OPERATOR is empty."
  [ "$(lc "$OPERATOR")" != "$(lc "$SIGNER")" ] || die "OPERATOR is the deployer. Governance must be a different (cold) address."
  local src; src=$(grep -oE 'APPROVED_OPERATOR = 0x[0-9a-fA-F]{40}' src/DeploymentConfig.sol | awk '{print $3}')
  [ "$(lc "$src")" = "$(lc "$OPERATOR")" ] || die "OPERATOR $OPERATOR differs from APPROVED_OPERATOR $src in source. Run plan.py on the release branch first."
  [ -n "${MAINNET_RPC_URL:-}" ] || die "MAINNET_RPC_URL is empty."
  local local_rpc=0; [[ "$MAINNET_RPC_URL" =~ ^https?://(127\.0\.0\.1|localhost)(:|/|$) ]] && local_rpc=1
  if [ "${FORK:-0}" = 1 ]; then
    [ $local_rpc = 1 ] || die "FORK=1 but MAINNET_RPC_URL is not local. A rehearsal must not reach mainnet."
    VAULT_RPC=$MAINNET_RPC_URL; MODE="REHEARSAL (local fork)"
  else
    [ $local_rpc = 0 ] || die "MAINNET_RPC_URL is local. Set FORK=1 for a rehearsal."
    VAULT_RPC=$PRIVATE_RPC; MODE="MAINNET"
  fi
  [ "$(cast chain-id --rpc-url "$MAINNET_RPC_URL" 2>/dev/null)" = 1 ] || die "the RPC is not chain 1."
  export OPERATOR FOUNDRY_PROFILE=deploy
}

confirm() {
  echo; echo "[$MODE] $1"; read -r -p "Type SEND to broadcast, anything else to stop: " a
  [ "$a" = SEND ] || die "stopped, nothing sent."
}

basefee() {
  local wei; wei=$(cast base-fee --rpc-url "$MAINNET_RPC_URL" 2>/dev/null | tail -1)
  echo "base fee: $(python3 -c "print(f'{$wei/1e9:.3f}')") gwei (the script refuses above ~1.7)"
}

refs() {
  [ -n "${REFERENCE_IMD_ETH_WEI:-}" ] || read -r -p "REFERENCE_IMD_ETH_WEI (wei of ETH per 1e18 IMD): " REFERENCE_IMD_ETH_WEI
  [ -n "${REFERENCE_NHI:-}" ] || read -r -p "REFERENCE_NHI (1e18-scaled): " REFERENCE_NHI
  export REFERENCE_IMD_ETH_WEI REFERENCE_NHI
}

case "${1:-}" in
  ramdisk) ramdisk ;;
  status)
    load
    echo "mode      $MODE"; echo "deployer  $SIGNER  ($(cast balance "$SIGNER" --ether --rpc-url "$MAINNET_RPC_URL") ETH)"
    echo "operator  $OPERATOR"; echo "commit    $(git rev-parse --short HEAD)$(git diff --quiet -- src script || echo ' + UNCOMMITTED src/script changes')"
    basefee; [ -f "$REC" ] && python3 -m json.tool "$REC" | head -40 || echo "no deployment record yet"
    ;;
  stage1)
    load; basefee
    echo "simulating stage one..."
    forge script $SCRIPT --rpc-url "$MAINNET_RPC_URL" --private-key "$PRIVATE_KEY" 2>&1 | grep -vE 'Warning|^$' | tail -25
    confirm "Stage one from $SIGNER."
    forge script $SCRIPT --rpc-url "$MAINNET_RPC_URL" --private-key "$PRIVATE_KEY" --broadcast --slow --priority-gas-price 100000000
    echo; echo "Next: seed the three feeds (buy + relay), then: launch.sh check"
    ;;
  check)
    load; refs
    forge script $SCRIPT --sig "verifySeeded()" --rpc-url "$MAINNET_RPC_URL"
    echo; echo "Passed. Next: launch.sh vault"
    ;;
  vault)
    load; refs; basefee
    if [ -z "${VAULT_SALT:-}" ]; then
      VAULT_SALT=0x$(openssl rand -hex 32)
      echo "VAULT_SALT=$VAULT_SALT" >> "$ENVF"          # kept on the RAM disk only, so a stopped run resumes with the same salt
      echo "fresh vault salt written to the RAM disk (not shown)"
    fi
    export VAULT_SALT
    forge script $SCRIPT --sig "verifySeeded()" --rpc-url "$MAINNET_RPC_URL" >/dev/null || die "verifySeeded refuses. Do not deploy the vault."
    echo "verifySeeded passes. Stage two goes through $VAULT_RPC (simulation included)."
    confirm "Stage two (the vault) from $SIGNER."
    forge script $SCRIPT --sig "runVault()" --rpc-url "$VAULT_RPC" --private-key "$PRIVATE_KEY" --broadcast --slow --priority-gas-price 100000000
    echo; echo "Next: Claude reads everything back; you send 5 IMD to the OracleAsker; then launch.sh wipe"
    ;;
  wipe)
    [ -d "$RD" ] || { echo "no RAM disk mounted: nothing to wipe"; exit 0; }
    diskutil eject force "$RD" >/dev/null && echo "ejected $RD: the key file is gone" || die "eject failed; close anything using $RD and run wipe again"
    ;;
  *) sed -n 2,9p "$0"; exit 1 ;;
esac
