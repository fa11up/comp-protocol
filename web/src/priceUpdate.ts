// What a price update would do, in plain words. Pure, so it is unit-tested apart from the page.
//
// The vault prices IMD from attested feeds that live one hour and are bought on demand, so most of the
// time the price is either stale (and price actions are paused) or behind the market. This turns the
// feeds, the live pool price and the viewer's position into the few sentences a user needs before
// paying for an update.

const WAD = 10n ** 18n;

export type FeedReading = { value: bigint; updated: bigint; stale: boolean; maxAge: bigint };

export type UpdateInput = {
  now: bigint;
  /** Primary IMD/ETH feed (wei ETH per 1e18 IMD). */
  price?: FeedReading;
  spot?: FeedReading;
  nhi?: FeedReading;
  /** The vault's IMD/USD price at the feed (1e18 = $1). */
  usd?: FeedReading;
  /** Live market from IMD's pool: wei ETH per 1e18 IMD, and the same in USD (1e18 = $1). */
  market?: { imdEth: bigint; imdUsd: bigint };
  /** The feeds' deviation cap, and how much wider it is once stale (absent: a stale feed is unbounded). */
  capBps?: bigint;
  staleMultiple?: bigint;
  /** The viewer's position: ratio in percent, debt, and the most it may owe at today's price. */
  position?: { cr: bigint; debt: bigint; maxDebt: bigint };
  mat?: bigint;
  /** One update's price, in IMD wei. */
  cost?: bigint;
  unit: string;
};

export type UpdateAdvice = {
  /** Feeds worth buying now, in the order to buy them. */
  needed: ("PriceFeed" | "SpotFeed" | "NhiFeed")[];
  /** Market price relative to the vault's, 1e18 = equal. */
  ratio?: bigint;
  /** Plain sentences, most important first. */
  lines: string[];
  /** True when an update would put the viewer's position below the minimum ratio. */
  warning: boolean;
};

const DEAD_BAND_BPS = 50n; // closer than 0.5% is "in line with the market"

export function pct(bps: bigint) {
  const whole = bps / 100n;
  const frac = (bps % 100n) / 10n;
  return `${whole}${frac ? `.${frac}` : ""}%`;
}

export function dollars(wad: bigint) {
  const cents = (wad + 5n * 10n ** 15n) / 10n ** 16n;
  const s = (cents / 100n).toLocaleString("en-US");
  return `$${s}.${(cents % 100n).toString().padStart(2, "0")}`;
}

function minutes(seconds: bigint) {
  const m = seconds / 60n;
  return m >= 60n ? `${m / 60n} hour${m / 60n === 1n ? "" : "s"}` : `${m} minute${m === 1n ? "" : "s"}`;
}

/** How many updates it takes to carry the vault's price to `ratio` (1e18 = no move). */
export function stepsTo(ratio: bigint, capBps: bigint, firstBps: bigint | undefined): number | undefined {
  if (capBps <= 0n) return undefined;
  const up = ratio >= WAD;
  let at = WAD;
  for (let n = 1; n <= 20; n++) {
    const bps = n === 1 && firstBps !== undefined ? firstBps : capBps;
    at = up ? (at * (10000n + bps)) / 10000n : (at * (10000n - (bps > 10000n ? 10000n : bps))) / 10000n;
    if (up ? at >= ratio : at <= ratio) return n;
  }
  return undefined;
}

export function adviseUpdate(i: UpdateInput): UpdateAdvice {
  const lines: string[] = [];
  const needed: UpdateAdvice["needed"] = [];
  let warning = false;
  const stale = (f?: FeedReading) => !f || f.stale || !f.updated;
  const pricesStale = stale(i.price) || stale(i.spot);
  if (pricesStale || stale(i.nhi)) {
    const life = i.price?.maxAge ? minutes(i.price.maxAge) : "an hour";
    lines.push(
      `Borrowing, withdrawing against debt, liquidating and redeeming are paused because the vault's price is out of date. An update reopens them for ${life}.`,
    );
  }

  let ratio: bigint | undefined;
  if (i.market && i.price?.value) {
    ratio = (i.market.imdEth * WAD) / i.price.value;
    const diffBps = ratio >= WAD ? ((ratio - WAD) * 10000n) / WAD : ((WAD - ratio) * 10000n) / WAD;
    const moved = diffBps >= DEAD_BAND_BPS;
    if (!moved) {
      lines.push("The vault's price is in line with the market (within 0.5%).");
    } else if (ratio > WAD) {
      lines.push(
        `IMD trades ${pct(diffBps)} above the vault's price. After an update, collateral counts for ${pct(diffBps)} more.`,
      );
    } else {
      lines.push(
        `IMD trades ${pct(diffBps)} below the vault's price. An update lowers what collateral counts for by ${pct(diffBps)}.`,
      );
    }
    if (moved && i.position && i.position.debt > 0n) {
      const after = (i.position.cr * ratio) / WAD;
      let sentence = `Your collateral ratio would go from ${i.position.cr}% to ${after}%`;
      if (ratio > WAD) {
        const room = (i.position.maxDebt * ratio) / WAD - i.position.debt;
        const now = i.position.maxDebt > i.position.debt ? i.position.maxDebt - i.position.debt : 0n;
        sentence += `, and you could borrow up to ${fmtWad(room)} ${i.unit} (${fmtWad(now)} today).`;
      } else sentence += ".";
      lines.push(sentence);
      if (i.mat !== undefined && after < i.mat && ratio < WAD) {
        warning = true;
        lines.push(
          `That is below the ${i.mat}% minimum: once the price updates, your position can be marked for liquidation. Add collateral or repay first.`,
        );
      }
    }
    if (moved && ratio < WAD)
      lines.push("The protocol's Treasury pays for this kind of update itself once the gap passes 5%.");
    if (moved && i.capBps !== undefined) {
      const first = pricesStale ? (i.staleMultiple !== undefined ? i.capBps * i.staleMultiple : undefined) : i.capBps;
      const steps = first === undefined && pricesStale ? 1 : stepsTo(ratio, i.capBps, first);
      if (steps !== undefined && steps > 1)
        lines.push(
          `The move is larger than one update can carry (each may move the price at most ${pct(first ?? i.capBps)}${first !== i.capBps ? `, then ${pct(i.capBps)}` : ""}), so it takes ${steps} updates.`,
        );
    }
    if (moved || pricesStale) needed.push("PriceFeed", "SpotFeed");
  } else {
    lines.push("The live market price could not be read, so the gap to the market is unknown.");
    if (pricesStale) needed.push("PriceFeed", "SpotFeed");
  }
  if (stale(i.nhi)) needed.push("NhiFeed");

  if (needed.length && i.cost !== undefined) {
    const each = `${fmtWad(i.cost)} IMD`;
    const usd = i.market ? ` (about ${dollars((i.cost * i.market.imdUsd) / WAD)})` : "";
    const both = needed.includes("PriceFeed")
      ? " Updating the price takes two purchases, the price and the spot check, because the vault refuses to act while they disagree by more than 5%."
      : "";
    lines.push(
      `Each update costs ${each}${usd} from your wallet and arrives within minutes, once a swarm panel answers. No protocol money is spent.${both}`,
    );
  }
  return { needed, ratio, lines, warning };
}

/** A wad to at most four decimals, trailing zeros trimmed. */
export function fmtWad(v: bigint) {
  const neg = v < 0n;
  const a = neg ? -v : v;
  const whole = (a / WAD).toLocaleString("en-US");
  const frac = ((a % WAD) / 10n ** 14n).toString().padStart(4, "0").replace(/0+$/, "");
  return `${neg ? "-" : ""}${whole}${frac ? `.${frac}` : ""}`;
}
