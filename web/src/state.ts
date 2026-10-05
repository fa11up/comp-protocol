import { parseAbi, zeroAddress, type Address } from "viem";
import { activeInterface, onChain } from "./names";
import { setUnit } from "./unit";
import type { Runtime, Target } from "./config";
// Dynamic implementation-derived ABIs are loaded only after manifest verification.
export const read = async (
  r: Runtime,
  t: Target,
  fn: string,
  args: readonly unknown[] = [],
  blockNumber?: bigint,
): Promise<any> =>
  r.client.readContract({ ...t, functionName: onChain(fn), args, blockNumber });
// Reads newer than the pinned ABIs. They are called through inline fragments rather than by
// editing public/abi (which the manifest verifies against the deployment's source commit), and a
// deployment that predates them reads as "unavailable" in its own field, never as a failed snapshot.
const optionalAbi = parseAbi([
  "function backingPerUnit() view returns (uint256)",
  "function backingPerComp() view returns (uint256)",
  "function expectedQuestionHash(uint64 fromBlock, uint64 toBlock) pure returns (bytes32)",
  "function lastToBlock() view returns (uint64)",
]);
export type Question =
  | { kind: "pinned"; fingerprint: `0x${string}`; lastToBlock?: bigint }
  | { kind: "unpinned" }
  | { kind: "unavailable" };
export type Snapshot = {
  block: bigint;
  timestamp: bigint;
  loadedAt: number;
  targets: Record<string, Target>;
  v: Record<string, any>;
  feeds: Record<
    string,
    { value: bigint; updated: bigint; stale: boolean; maxAge: bigint }
  >;
  work: Record<string, any>;
  questions: Record<string, Question>;
  errors: string[];
  verified: boolean;
};
export async function snapshot(
  r: Runtime,
  account?: Address,
): Promise<Snapshot> {
  if ((await r.client.getChainId()) !== r.config.chainId)
    throw Error(
      "Public RPC chain ID does not match the deployment. Transactions disabled.",
    );
  const block = await r.client.getBlock();
  const bn = block.number;
  const targets = { ...r.targets };
  await Promise.all(
    Object.entries(targets).map(async ([n, t]) => {
      const code = await r.client.getCode({
        address: t.address,
        blockNumber: bn,
      });
      if (!code || code === "0x")
        throw Error(`No deployed code for ${n}. Transactions disabled.`);
    }),
  );
  const vault = targets.ParameterizedVault;
  if (!vault) throw Error("The handoff is missing ParameterizedVault.");
  await Promise.all(
    Object.entries({
      imdToken: "MockIMD",
      stablecoin: "ImdUSD",
      parameters: "Parameters",
      treasury: "Treasury",
      usdPriceFeed: "UsdPriceFeed",
      oracle: "SwarmWorkOracle",
    }).map(async ([fn, abiName]) => {
      const a = (await read(r, vault, fn, [], bn)) as Address;
      if (a === zeroAddress) throw Error(`Missing linked contract: ${fn}`);
      targets[fn] = { address: a, abi: r.abis[abiName] };
      const code = await r.client.getCode({ address: a, blockNumber: bn });
      if (!code || code === "0x") throw Error(`No code for linked ${fn}`);
    }),
  );
  await Promise.all(
    [
      ["priceFeed", "PriceFeed"],
      ["nhiFeed", "NhiFeed"],
      ["spotFeed", "SpotFeed"],
    ].map(async ([getter, name]) => {
      if (
        (await read(r, vault, getter, [], bn)).toLowerCase() !==
        targets[name].address.toLowerCase()
      )
        throw Error(`Vault ${getter} differs from the handoff.`);
    }),
  );
  await Promise.all(
    ["stablecoin", "parameters", "treasury", "oracle"].map(async (name) => {
      if (
        (await read(r, targets[name], "vault", [], bn)).toLowerCase() !==
        vault.address.toLowerCase()
      )
        throw Error(`Linked ${name} belongs to a different vault.`);
    }),
  );
  const errors: string[] = [];
  const v: Record<string, any> = {};
  const feeds: Snapshot["feeds"] = {};
  const jobs: string[] = [
    "mat",
    "redemptionCeilingCR",
    "gap",
    "redemptionReserve",
    "REDEMPTION_FEE_FLOOR_BPS",
    "REDEMPTION_FEE_CAP_BPS",
    "totalDebt",
    "backedDebt",
    "totalBadDebt",
    "totalEarned",
    "totalNonPrincipalRedeemed",
    "earnLine",
    "earnMat",
    "reserveValue",
    "securedCollateral",
    "line",
    "duty",
    "skew",
    "lull",
    "tail",
  ];
  const safe = async (key: string, fn: () => Promise<any>) => {
    try {
      v[key] = await fn();
    } catch {
      errors.push(key);
    }
  };
  await Promise.all([
    ...jobs.map((fn) => safe(fn, () => read(r, vault, fn, [], bn))),
    safe("fee", () => read(r, vault, "redemptionFeeBps", [0n], bn)),
    safe("supply", () => read(r, targets.stablecoin, "totalSupply", [], bn)),
    safe("imdDeployer", () => read(r, targets.imdToken, "deployer", [], bn)),
    safe("imdDecimals", () => read(r, targets.imdToken, "decimals", [], bn)),
    safe("compDecimals", () => read(r, targets.stablecoin, "decimals", [], bn)),
    ...[
      "governor",
      "TIMELOCK",
      "pendingChange",
      "current",
      "wage",
      "pendingGap",
      "pendingEarnMat",
      "pendingReserveAsset",
      "pendingSet",
      "pending",
    ].map((fn) => safe(fn, () => read(r, targets.parameters, fn, [], bn))),
    safe("reserveAssets", () =>
      read(r, targets.treasury, "reserveAssets", [], bn),
    ),
    safe("withdrawer", () => read(r, targets.treasury, "withdrawer", [], bn)),
    ...Object.entries({
      PriceFeed: "PriceFeed",
      NhiFeed: "NhiFeed",
      SpotFeed: "SpotFeed",
      USD: "usdPriceFeed",
    }).map(async ([key, n]) => {
      try {
        const [data, stale, maxAge] = await Promise.all([
          read(r, targets[n], "latestValue", [], bn),
          read(r, targets[n], "isStale", [], bn),
          read(r, targets[n], "maxAge", [], bn),
        ]);
        feeds[key] = { value: data[0], updated: data[1], stale, maxAge };
      } catch {
        errors.push(key);
      }
    }),
    ...(account
      ? [
          ...[
            "positions",
            "debtOf",
            "stabilityFeeOf",
            "collateralRatio",
            "badDebtOf",
          ].map((fn) => safe(fn, () => read(r, vault, fn, [account], bn))),
          safe("imdBalance", () =>
            read(r, targets.imdToken, "balanceOf", [account], bn),
          ),
          safe("compBalance", () =>
            read(r, targets.stablecoin, "balanceOf", [account], bn),
          ),
          safe("allowance", () =>
            read(
              r,
              targets.imdToken,
              "allowance",
              [account, vault.address],
              bn,
            ),
          ),
          safe("rights", () =>
            read(r, targets.oracle, "mintingRights", [account], bn),
          ),
        ]
      : []),
  ]);
  const optional = (
    address: Address,
    functionName: string,
    args: readonly unknown[] = [],
  ) =>
    r.client.readContract({
      address,
      abi: optionalAbi,
      functionName: onChain(functionName) as never,
      args: args as never,
      blockNumber: bn,
    }) as Promise<any>;
  try {
    v.backingPerUnit = await optional(vault.address, "backingPerUnit");
  } catch {
    v.backingPerUnit = undefined;
  }
  try {
    setUnit(await read(r, targets.stablecoin, "symbol", [], bn));
  } catch {
    /* Label only: the default unit stands. */
  }
  const questions: Record<string, Question> = {};
  await Promise.all(
    ["PriceFeed", "NhiFeed", "SpotFeed"].map(async (n) => {
      try {
        // A feed that pins no question returns zero for every window.
        const hash = (await optional(
          targets[n].address,
          "expectedQuestionHash",
          [0n, 0n],
        )) as `0x${string}`;
        if (/^0x0+$/.test(hash)) questions[n] = { kind: "unpinned" };
        else {
          let last: bigint | undefined;
          try {
            last = BigInt(await optional(targets[n].address, "lastToBlock"));
          } catch {
            last = undefined;
          }
          questions[n] = {
            kind: "pinned",
            fingerprint: hash,
            lastToBlock: last,
          };
        }
      } catch {
        // Feeds built before question binding have no such view: they accept any question.
        questions[n] = { kind: "unavailable" };
      }
    }),
  );
  const work: Record<string, any> = { mode: "unknown" };
  // Three work oracles exist. The single-agent one ("attested") predates the rename and survives only
  // on legacy deployments. The swarm-wide one ("swarm") credits any agent from the swarm's daily tally
  // and is what deploys from now on. A test faucet ("faucet") grants credits by hand.
  try {
    if (activeInterface() !== "legacy")
      throw Error("single-agent oracle is legacy only");
    const keys = [
      "attestedTasks",
      "creditedTasks",
      "earnedRights",
      "consumedRights",
      "wage",
      "CLAIMANT",
      "AGENT_ID",
      "latestValue",
      "isStale",
      "maxAge",
    ];
    const values = await Promise.all(
      keys.map((k) => read(r, targets.oracle, k, [], bn)),
    );
    keys.forEach((k, i) => (work[k] = values[i]));
    work.mode = "attested";
  } catch {
    try {
      const keys = ["wage", "latestValue", "isStale", "maxAge"];
      const values = await Promise.all(
        keys.map((k) => read(r, targets.oracle, k, [], bn)),
      );
      keys.forEach((k, i) => (work[k] = values[i]));
      if (account) {
        [work.creditedRights, work.consumedRights] = await Promise.all([
          read(r, targets.oracle, "creditedRights", [account], bn),
          read(r, targets.oracle, "consumedRights", [account], bn),
        ]);
      }
      work.mode = "swarm";
    } catch {
      try {
        const t = {
          address: targets.oracle.address,
          abi: r.abis.MockWorkOracle,
        };
        work.deployer = await read(r, t, "deployer", [], bn);
        targets.oracle = t;
        work.mode = "faucet";
      } catch {
        work.mode = "unknown";
      }
    }
  }
  if (v.imdDecimals !== 18 || v.compDecimals !== 18)
    throw Error(
      "Unexpected token decimals for this deployment. Transactions disabled.",
    );
  return {
    block: bn,
    timestamp: block.timestamp,
    loadedAt: Date.now(),
    targets,
    v,
    feeds,
    work,
    questions,
    errors,
    verified: true,
  };
}
export function feedsReady(s: Snapshot | undefined) {
  if (!s) return false;
  for (const key of ["PriceFeed", "NhiFeed", "SpotFeed", "USD"]) {
    const f = s.feeds[key];
    if (!f || f.stale || !f.updated || f.value <= 0n) return false;
  }
  const a = s.feeds.PriceFeed.value,
    b = s.feeds.SpotFeed.value;
  const d = a > b ? a - b : b - a;
  return s.v.skew !== undefined && d <= (a * s.v.skew) / 10000n;
}
