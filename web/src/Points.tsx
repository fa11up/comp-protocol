import { useEffect, useRef, useState } from "react";
import { decodeEventLog, getAddress } from "viem";
import {
  computePoints,
  display,
  displayNumber,
  shareBps,
  type PointEvent,
  type PointsResult,
} from "../../points/engine.ts";
import { history } from "./history";
import { ours } from "./names";
import { pointsConfig, type Runtime } from "./config";
import type { Snapshot } from "./state";
import { message } from "./math";
import { Info, Row } from "./actions";
import { Ticker } from "./motion";
import { useEns, displayName, ensName } from "./ens";

const TRANSFER =
  "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const SECONDS_PER_BLOCK = 12;
const topicAddress = (t: string) => getAddress(`0x${t.slice(-40)}`);

/** Reads imdUSD transfers and vault liquidations, then runs the shared engine at the snapshot block. */
export async function loadPoints(
  r: Runtime,
  s: Snapshot,
): Promise<PointsResult> {
  const token = s.targets.stablecoin;
  const vault = s.targets.ParameterizedVault;
  const [tokenHistory, vaultHistory] = await Promise.all([
    history(r, token, s.block),
    history(r, vault, s.block),
  ]);
  const events: PointEvent[] = [];
  for (const log of tokenHistory.logs) {
    if (log.topics[0] !== TRANSFER || log.topics.length !== 3) continue;
    events.push({
      kind: "transfer",
      from: topicAddress(log.topics[1]!),
      to: topicAddress(log.topics[2]!),
      value: BigInt(log.data),
      block: Number(log.blockNumber),
      logIndex: log.logIndex,
    });
  }
  for (const log of vaultHistory.logs) {
    let decoded;
    try {
      decoded = decodeEventLog({
        abi: vault.abi,
        data: log.data,
        topics: log.topics,
      });
    } catch {
      continue; // events this ABI does not describe carry no points
    }
    if (!decoded.eventName || ours(decoded.eventName) !== "Bite") continue;
    // Same order under both interfaces: owner, liquidator, debt repaid, collateral seized.
    const [, liquidator, debtRepaid] = Object.values(decoded.args as object);
    events.push({
      kind: "bite",
      liquidator: String(liquidator),
      debtRepaid: BigInt(debtRepaid as bigint),
      block: Number(log.blockNumber),
      logIndex: log.logIndex,
    });
  }
  const head = Number(s.block);
  const endBlock =
    pointsConfig.endBlock === undefined
      ? head
      : Math.min(pointsConfig.endBlock, head);
  return computePoints(events, {
    startBlock: pointsConfig.startBlock ?? Number(tokenHistory.from),
    endBlock,
    blocksPerDay: pointsConfig.blocksPerDay,
    lpBps: pointsConfig.lpBps,
    liquidationCreditDays: pointsConfig.liquidationCreditDays,
    excluded: [
      vault.address,
      s.targets.treasury.address,
      pointsConfig.poolManagers[r.config.chainId] ?? "",
      ...pointsConfig.excluded,
    ].filter(Boolean),
  });
}

type Loaded = {
  data?: PointsResult;
  error?: string;
  loading: boolean;
  at?: number;
};

export function usePoints(r: Runtime, s?: Snapshot) {
  const [state, setState] = useState<Loaded>({ loading: true });
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    if (!s) return;
    let live = true;
    setState((old) => ({ ...old, loading: true }));
    loadPoints(r, s).then(
      (data) => live && setState({ data, loading: false, at: Date.now() }),
      (e) => live && setState({ error: message(e), loading: false }),
    );
    return () => {
      live = false;
    };
  }, [r, s, attempt]);
  return { ...state, retry: () => setAttempt((n) => n + 1) };
}

/** A figure that keeps counting between blocks, from the points at the snapshot and the rate since. */
function useLive(base: bigint, perBlock: bigint, since: number | undefined) {
  const [now, setNow] = useState(() => Date.now());
  const reduced = useRef(
    typeof matchMedia === "function" &&
      matchMedia("(prefers-reduced-motion: reduce)").matches,
  );
  useEffect(() => {
    if (perBlock === 0n) return;
    const id = setInterval(
      () => setNow(Date.now()),
      reduced.current ? 12_000 : 1_000,
    );
    return () => clearInterval(id);
  }, [perBlock]);
  const blocks =
    since === undefined
      ? 0
      : Math.max(0, (now - since) / 1000 / SECONDS_PER_BLOCK);
  return (
    displayNumber(base, pointsConfig.blocksPerDay) +
    displayNumber(perBlock, pointsConfig.blocksPerDay) * blocks
  );
}

// Rounded DOWN, like every exact figure the engine displays, so the counter never shows a point the
// leaderboard rows have not earned.
const fmtPoints = (n: number) =>
  (Math.floor(n * 100) / 100).toLocaleString("en-US", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  });
const perDay = (perBlock: bigint) =>
  display(
    perBlock * BigInt(pointsConfig.blocksPerDay),
    pointsConfig.blocksPerDay,
  );

export function Points({
  r,
  account,
  points,
}: {
  r: Runtime;
  account?: string;
  points: ReturnType<typeof usePoints>;
}) {
  const data = points.data;
  const mine = account
    ? data?.accounts.find((a) => a.owner === account.toLowerCase())
    : undefined;
  const rank = mine && data ? data.accounts.indexOf(mine) + 1 : undefined;
  const top = data?.accounts.slice(0, 10) ?? [];
  useEns(top.map((a) => a.owner));
  const liveMine = useLive(
    mine?.points ?? 0n,
    mine?.ratePerBlock ?? 0n,
    points.at,
  );
  const liveTotal = useLive(
    data?.total ?? 0n,
    data?.totalRatePerBlock ?? 0n,
    points.at,
  );
  const testnet = r.config.chainId !== 1;

  if (points.error)
    return (
      <div className="desk-col">
        <p className="notice" role="alert">
          Could not read the points history: {points.error}. This is not the
          same as nobody holding imdUSD.{" "}
          <button type="button" onClick={points.retry}>
            Retry
          </button>
        </p>
      </div>
    );

  return (
    <>
      <div className="desk-col">
        {testnet && (
          <p className="notice" role="note">
            Preview on {r.config.network.name}. Testnet balances cost nothing to
            fake, so these points do not count. The season runs on mainnet.
          </p>
        )}
        <div className="hero-stat">
          <span>
            {account ? "Your points" : "Season total"}
            <Info
              label="Points"
              text="1 point = 1 imdUSD held for 1 day. Liquidity in the imdUSD/USDC pool earns more. The counter runs between blocks at your current holdings and settles each refresh."
            />
          </span>
          <strong aria-live="off">
            {points.loading && !data
              ? "Reading…"
              : fmtPoints(account ? liveMine : liveTotal)}
          </strong>
          <small>
            {account
              ? mine
                ? `+${perDay(mine.ratePerBlock)}/day · ${(shareBps(mine.points, data!.total) / 100).toFixed(2)}% · #${rank} of ${data!.accounts.length}`
                : "Hold imdUSD to start earning"
              : data
                ? `${data.accounts.length} earning · +${perDay(data.totalRatePerBlock)}/day`
                : ""}
          </small>
        </div>
        <Row label="Holding" info="imdUSD in a wallet, per imdUSD per day.">
          1 point / day
        </Row>
        <Row
          label="Liquidity"
          info="imdUSD provided to the imdUSD/USDC pool. Boosted, because the launch needs liquidity."
        >
          {pointsConfig.lpLive
            ? `${pointsConfig.lpBps / 10_000}× / day`
            : `${pointsConfig.lpBps / 10_000}× once the pool is live`}
        </Row>
        <Row
          label="Liquidations"
          info="Each imdUSD of debt a liquidator repays earns this many days of holding."
        >
          {`${pointsConfig.liquidationCreditDays} days per imdUSD`}
        </Row>
        <Row
          label="Season"
          info="From the stablecoin's deployment to the swarm's mainnet launch and the token launch that follows."
        >
          {data
            ? pointsConfig.endBlock === undefined
              ? `Block ${data.startBlock.toLocaleString("en-US")} → live`
              : `Blocks ${data.startBlock.toLocaleString("en-US")} → ${pointsConfig.endBlock.toLocaleString("en-US")}`
            : "—"}
        </Row>
        {account && mine && (
          <Row label="You hold" info="Earning at the holding rate right now.">
            {`${display(mine.held * BigInt(pointsConfig.blocksPerDay), pointsConfig.blocksPerDay)} imdUSD`}
          </Row>
        )}
      </div>
      <div className="desk-col points-board">
        <div className="loan-columns points-columns" aria-hidden="true">
          <span>Top 10 holders</span>
          <span>Points</span>
          <span>Share</span>
          <span>Per day</span>
        </div>
        {data && !top.length ? (
          <p className="muted">
            No imdUSD is held yet. Points start with the first mint.
          </p>
        ) : (
          <ol className="loan-feed points-feed" aria-label="Points leaderboard">
            {top.map((a, i) => (
              <li
                key={a.owner}
                className={
                  a.owner === account?.toLowerCase()
                    ? "selected-loan"
                    : undefined
                }
              >
                <span className="loan-who">
                  <b className={ensName(a.owner) ? "ens-name" : undefined}>
                    {i + 1}. {displayName(a.owner)}
                  </b>
                  <span className="loan-address" title={a.owner}>
                    {a.owner}
                  </span>
                </span>
                <span>
                  <Ticker text={display(a.points, pointsConfig.blocksPerDay)} />
                </span>
                <span>
                  {(shareBps(a.points, data!.total) / 100).toFixed(2)}%
                </span>
                <span>+{perDay(a.ratePerBlock)}</span>
              </li>
            ))}
          </ol>
        )}
      </div>
    </>
  );
}
