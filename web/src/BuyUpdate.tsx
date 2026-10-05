import { keccak256, parseAbi, type Address } from "viem";
import type { Runtime } from "./config";
import type { Snapshot } from "./state";
import { Action, Info, type Actions } from "./actions";
import { exact, fmt } from "./math";

// Buying a price update with the viewer's own IMD, through the protocol's OracleAsker. The asker pays
// IdentityMD's on-chain Intake and delivers the answer through SwarmRelay; the feed checks it like any
// other attestation. Nothing here spends protocol money. Until the Intake is live on mainnet the
// deployment names no asker, and the control explains that instead.
export const askerAbi = parseAbi([
  "function price() view returns (uint256)",
  "function payToken() view returns (address)",
  "function feeds(address) view returns (bytes32 bodyHash, bool tracksPool, bool keepAlive, uint64 lastAsk, uint64 armedAt, uint64 inFlightAt, bytes32 inFlight)",
  "function askPaid(address feed, bytes body, uint256 maxPrice) returns (bytes32)",
]);
const erc20 = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address, address) view returns (uint256)",
  "function approve(address, uint256) returns (bool)",
]);

export type AskerState = {
  price: bigint;
  payToken: Address;
  /** Feeds whose configured request body matches the hash the asker pins. */
  ready: Record<string, boolean>;
  /** A request already on its way for this feed. */
  inFlight: Record<string, boolean>;
  balance?: bigint;
  allowance?: bigint;
};

export async function readAsker(
  r: Runtime,
  feeds: Record<string, Address>,
  account: Address | undefined,
  blockNumber: bigint,
): Promise<AskerState | undefined> {
  const cfg = r.config.oracleAsker;
  if (!cfg) return undefined;
  const at = { address: cfg.address, abi: askerAbi } as const;
  const [price, payToken] = await Promise.all([
    r.client.readContract({ ...at, functionName: "price", blockNumber }),
    r.client.readContract({ ...at, functionName: "payToken", blockNumber }),
  ]);
  const ready: Record<string, boolean> = {};
  const inFlight: Record<string, boolean> = {};
  await Promise.all(
    Object.entries(feeds).map(async ([name, feed]) => {
      const body = cfg.requests?.[name];
      if (!body) return;
      const f = await r.client.readContract({
        ...at,
        functionName: "feeds",
        args: [feed],
        blockNumber,
      });
      ready[name] = f[0] === keccak256(body);
      inFlight[name] = !/^0x0+$/.test(f[6]);
    }),
  );
  const state: AskerState = { price, payToken, ready, inFlight };
  if (account)
    [state.balance, state.allowance] = await Promise.all([
      r.client.readContract({
        address: payToken,
        abi: erc20,
        functionName: "balanceOf",
        args: [account],
        blockNumber,
      }),
      r.client.readContract({
        address: payToken,
        abi: erc20,
        functionName: "allowance",
        args: [account, cfg.address],
        blockNumber,
      }),
    ]);
  return state;
}

export function BuyUpdate({
  r,
  s,
  feed,
  actions,
}: {
  r: Runtime;
  s?: Snapshot;
  feed: string;
  actions: Actions;
}) {
  const cfg = r.config.oracleAsker;
  const id = `buy-update-${feed}`;
  if (cfg && s?.asker === "unreadable")
    return (
      <div className="buy-update">
        <button type="button" disabled>
          Buy update
        </button>
        <Info
          label="Buy update"
          text="The request contract did not answer. Refresh to try again."
        />
      </div>
    );
  const a = s?.asker === "unreadable" ? undefined : s?.asker;
  if (!cfg || !a)
    return (
      <div className="buy-update">
        <button type="button" disabled>
          Buy update
        </button>
        <Info
          label="Buy update"
          text="Buying an update from here opens when IdentityMD's on-chain request contract is live. Until then, anyone can buy one from the oracle service and relay it."
        />
      </div>
    );
  const body = cfg.requests?.[feed];
  const short =
    a.allowance === undefined || a.allowance < a.price ? true : false;
  const blocked = !body
    ? "This deployment lists no request for this feed."
    : !a.ready[feed]
      ? "The configured request does not match the question this feed pins. Nothing will be sent."
      : a.inFlight[feed]
        ? "An update for this feed is already on its way."
        : a.price === 0n
          ? "The request contract is not selling updates right now."
          : a.balance !== undefined && a.balance < a.price
            ? `An update costs ${fmt(a.price)} IMD; this wallet holds ${fmt(a.balance)}.`
            : "";
  return (
    <div className="buy-update">
      <Action
        id={id}
        label={short && !blocked ? "Approve IMD for an update" : "Buy update"}
        actions={actions}
        disabled={!!blocked}
        reason={blocked}
        request={() => {
          if (blocked) throw Error(blocked);
          if (short)
            return {
              target: { address: a.payToken, abi: erc20 },
              fn: "approve",
              args: [cfg.address, a.price],
              summary: `Approve exactly ${exact(a.price)} IMD for one ${feed} update. The purchase is a separate transaction.`,
            };
          return {
            target: { address: cfg.address, abi: askerAbi },
            fn: "askPaid",
            args: [s!.targets[feed].address, body, a.price],
            summary: `Pay ${exact(a.price)} IMD from this wallet for a fresh ${feed} answer. It arrives once a swarm panel answers, usually within minutes.`,
          };
        }}
      />
      <Info
        label="Buy update"
        text={`Pays ${fmt(a.price)} IMD from your wallet for a fresh answer from a swarm panel, usually within minutes. No protocol funds are spent.`}
      />
    </div>
  );
}
