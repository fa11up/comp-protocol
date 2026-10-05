import { useEffect, useState } from "react";
import { formatUnits } from "viem";
import { loadConfig, type Runtime } from "./config";
import { snapshot, feedsReady, type Snapshot } from "./state";
import { SiteHeader, href, WHITEPAPER } from "./site";
import { AddressLink } from "./actions";
import { MarketCap, compact } from "./MarketCap";
import { age, fmt, ratio, WAD } from "./math";

// The landing page reads the same contracts the terminal does, without a wallet, so its figures
// are the protocol's own and never a number written into the page.
function useLive() {
  const [r, setR] = useState<Runtime>();
  const [s, setS] = useState<Snapshot>();
  const [error, setError] = useState("");
  useEffect(() => {
    let active = true;
    let timer: ReturnType<typeof setInterval> | undefined;
    loadConfig()
      .then((runtime) => {
        if (!active) return;
        setR(runtime);
        const read = () =>
          snapshot(runtime)
            .then((next) => {
              if (active) {
                setS(next);
                setError("");
              }
            })
            .catch(() => active && setError("unavailable"));
        void read();
        timer = setInterval(() => {
          if (document.visibilityState === "visible") void read();
        }, 30000);
      })
      .catch(() => active && setError("unavailable"));
    return () => {
      active = false;
      if (timer) clearInterval(timer);
    };
  }, []);
  return { r, s, error };
}

const usd = (v?: bigint) =>
  v === undefined ? "—" : `$${compact.format(Number(formatUnits(v, 18)))}`;

function LivePanel({ s, error }: { s?: Snapshot; error: string }) {
  const [now, setNow] = useState(BigInt(Math.floor(Date.now() / 1000)));
  useEffect(() => {
    const t = setInterval(
      () => setNow(BigInt(Math.floor(Date.now() / 1000))),
      1000,
    );
    return () => clearInterval(t);
  }, []);
  const v = s?.v ?? {};
  const price = s?.feeds.USD;
  const lines: [string, string, string?][] = s
    ? [
        [
          "Backing per imdUSD",
          v.backingPerComp === undefined
            ? "not reported"
            : `$${fmt(v.backingPerComp < WAD ? v.backingPerComp : WAD)}`,
        ],
        ["Reserves", usd(v.reserveValue)],
        [
          "IMD / USD",
          price
            ? `$${fmt(price.value, 18, 2)} · ${price.stale ? "stale" : age(price.updated, now)}`
            : "—",
          price?.stale ? "danger" : undefined,
        ],
        ["Minimum collateral ratio", ratio(v.minCR)],
        [
          "Price actions",
          feedsReady(s) ? "open" : "paused",
          feedsReady(s) ? "healthy" : "danger",
        ],
      ]
    : [];
  return (
    <section className="live-panel" aria-labelledby="live-heading">
      <div className="live-head">
        <h2 id="live-heading">
          Live · {s ? `block ${s.block}` : "reading the chain"}
        </h2>
        <span
          className="live-dot"
          data-state={s ? "live" : error ? "down" : "wait"}
          aria-hidden="true"
        />
      </div>
      {s ? (
        <>
          <dl className="live-lines">
            {lines.map(([k, val, tone]) => (
              <div key={k}>
                <dt>{k}</dt>
                <dd className={tone ? `${tone}-text` : undefined}>{val}</dd>
              </div>
            ))}
          </dl>
          <p className="live-cap">
            <MarketCap supply={v.supply} />
          </p>
        </>
      ) : (
        <p className="live-wait" role="status">
          {error
            ? "Live figures are unavailable right now. The terminal shows which read failed."
            : "Reading the contracts…"}
        </p>
      )}
    </section>
  );
}

export function Landing() {
  const { r, s, error } = useLive();
  return (
    <div className="site">
      <SiteHeader page="home" network={r?.config.network.name}>
        <a className="button primary" href={href("terminal/")}>
          Open terminal
        </a>
      </SiteHeader>
      <main className="home">
        <section className="hero">
          <div className="hero-copy">
            <h1>
              A dollar the swarm <span>prices.</span>
            </h1>
            <p className="lede">
              imdUSD is a dollar-denominated stablecoin borrowed against IMD.
              Its price comes from panels of IdentityMD agents, signed and
              checked on chain against the exact question each feed pins.
            </p>
            <div className="hero-actions">
              <a className="button primary" href={href("terminal/")}>
                Open the terminal
              </a>
              <a className="button" href={href("docs/")}>
                Read the docs
              </a>
            </div>
          </div>
          <LivePanel s={s} error={error} />
        </section>

        <section className="mechanics" aria-labelledby="mechanics-heading">
          <h2 id="mechanics-heading">How it holds a dollar</h2>
          <div className="mechanics-grid">
            <article>
              <h3>Borrow</h3>
              <p>
                Deposit IMD and mint imdUSD against it. A position must stay at
                or above the minimum collateral ratio: 150% while the network is
                healthy, rising toward 200% as network health falls.
              </p>
              <p className="figure">
                150–200% <span>minimum ratio</span>
              </p>
            </article>
            <article>
              <h3>Redeem</h3>
              <p>
                Burn imdUSD for IMD at the lesser of $1 and the backing behind
                each imdUSD, less a fee that grows with the size of the
                redemption and stays in the protocol as backing.
              </p>
              <p className="figure">
                0.5–5% <span>redemption fee</span>
              </p>
            </article>
            <article>
              <h3>Price</h3>
              <p>
                Agent panels answer the IMD / ETH price over a block window; the
                swarm attester signs the agreed figure. Each feed accepts only
                answers to its own question, then the vault multiplies by
                Chainlink ETH / USD.
              </p>
              <p className="figure">
                2 feeds <span>primary and spot must agree</span>
              </p>
            </article>
            <article>
              <h3>Liquidate</h3>
              <p>
                Anyone can mark a position below the minimum ratio. Once its
                grace period passes, anyone can repay its debt; the position
                gives up collateral worth 110% of it, and the 10% bonus is
                shared with whoever marked it.
              </p>
              <p className="figure">
                0–6 h <span>grace, set by network health</span>
              </p>
            </article>
          </div>
        </section>

        <section className="contracts" aria-labelledby="contracts-heading">
          <h2 id="contracts-heading">On Sepolia</h2>
          <p className="note">
            The testnet deployment. The token is deployed there under its
            testnet name, COMP; contracts and parameters will change before
            mainnet.
          </p>
          <div className="contract-list">
            {r ? (
              r.config.contracts.map((c) => (
                <AddressLink
                  key={c.name}
                  value={c.address}
                  explorer={r.config.network.explorer}
                  label={c.name}
                />
              ))
            ) : (
              <p className="note">
                {error ? "Deployment unavailable." : "Loading…"}
              </p>
            )}
          </div>
        </section>
      </main>
      <footer className="site-footer">
        <span>imdUSD · built on IdentityMD</span>
        <nav aria-label="Footer">
          <a href={href("terminal/")}>Terminal</a>
          <a href={href("docs/")}>Docs</a>
          <a href={WHITEPAPER} target="_blank" rel="noreferrer">
            Whitepaper ↗
          </a>
        </nav>
      </footer>
    </div>
  );
}

export function Docs() {
  return (
    <div className="site">
      <SiteHeader page="docs">
        <a className="button primary" href={href("terminal/")}>
          Open terminal
        </a>
      </SiteHeader>
      <main className="docs-placeholder">
        <h1>Docs are being written</h1>
        <p className="lede">
          Guides for borrowing, redeeming, keeping and the oracle will live
          here. Until then, the whitepaper describes the design and the terminal
          shows every figure live.
        </p>
        <div className="hero-actions">
          <a
            className="button primary"
            href={WHITEPAPER}
            target="_blank"
            rel="noreferrer"
          >
            Read the whitepaper ↗
          </a>
          <a className="button" href={href("terminal/")}>
            Open the terminal
          </a>
        </div>
      </main>
    </div>
  );
}
