// /tokenomics: the supply, where it goes, how each bucket pays, and what INFER is.
import { LAUNCH, bucketAmount, compact, pct, whole } from "./config";
import { Fig, Line, SITE, Shell, WHITEPAPER, useWallet } from "./ui";

export function Tokenomics() {
  const w = useWallet();
  const seasonsTotal = LAUNCH.seasons.amounts.every((a) => a !== null)
    ? LAUNCH.seasons.amounts.reduce((s, a) => s + BigInt(a!), 0n)
    : null;
  const largest = Math.max(...LAUNCH.allocation.map((a) => a.bps ?? 0), 1);
  const largestSeason = LAUNCH.seasons.amounts.reduce(
    (m, a) => (a && BigInt(a) > m ? BigInt(a) : m),
    1n,
  );
  const share = (key: string) =>
    LAUNCH.allocation.find((a) => a.key === key)?.bps ?? null;
  return (
    <Shell page="tokenomics" depth={1} wallet={w} className="infer-page">
      <main className="infer-doc">
        <header className="infer-doc-head">
          <p className="infer-kicker">
            Inference-Backed Endogenous Financial Reserve
          </p>
          <h1>
            <Fig v={compact(LAUNCH.supply)} /> <span>INFER</span>
          </h1>
          <p className="infer-lede">
            Fixed supply, minted once by IdentityMD's launch factory, with no
            owner, no further minting and no tax. Every bucket is a contract
            whose share is a constant in its verified source, paid in the launch
            transaction by a permissionless split. INFER is the token of the
            imdUSD protocol: launched with permanent liquidity against{" "}
            {LAUNCH.pair}, claimed against genesis points for holding imdUSD,
            redeemable for the community's legacy tokens, and stakeable for a
            share of what the protocol earns.
          </p>
        </header>

        <section aria-labelledby="split-h">
          <h2 id="split-h">Where it goes</h2>
          <table className="infer-table infer-alloc">
            <thead>
              <tr>
                <th scope="col">Bucket</th>
                <th scope="col">Share</th>
                <th scope="col">INFER</th>
                <th scope="col">How it pays</th>
              </tr>
            </thead>
            <tbody>
              {LAUNCH.allocation.map((a) => (
                <tr key={a.key}>
                  <td data-label="Bucket">
                    <b>{a.label}</b>
                  </td>
                  <td data-label="Share" className="infer-barcell">
                    <span className="infer-bar" aria-hidden="true">
                      <span
                        style={{ width: `${((a.bps ?? 0) / largest) * 100}%` }}
                      />
                    </span>
                    <span className="infer-barvalue">
                      <Fig v={pct(a.bps)} />
                    </span>
                  </td>
                  <td data-label="INFER">
                    <Fig v={compact(bucketAmount(a.bps))} />
                  </td>
                  <td data-label="How it pays">{a.note}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="infer-fine">
            Shares are of the total supply; each bar is the bucket against the
            largest.
          </p>
        </section>

        <div className="infer-columns">
          <div className="infer-column">
            <section aria-labelledby="launch-h">
              <h2 id="launch-h">The launch</h2>
              <p>
                A custom-token launch on Ethereum mainnet by the IdentityMD
                swarm, which writes, reviews and deploys the contracts.
              </p>
              <p>
                The factory keeps a fixed share for the agents that build it,
                seeds the {LAUNCH.pair}
                /INFER pool on one side from the opening price upward and holds
                that liquidity for good, and sends the rest to the splitter that
                pays the buckets above. The opening market cap of{" "}
                <Fig
                  v={whole(LAUNCH.openingMarketCapImd, 0)}
                  unit={LAUNCH.pair}
                />{" "}
                is therefore also the pool's floor.
              </p>
              <p className="infer-fine">
                Read the protocol at{" "}
                <a href={`${SITE}/docs/`}>imdusd.com/docs</a> and the whitepaper
                at{" "}
                <a href={WHITEPAPER} target="_blank" rel="noreferrer">
                  whitepaper.imdusd.com
                </a>
                . Contract addresses are published here at launch.
              </p>
            </section>

            <section aria-labelledby="seasons-h">
              <h2 id="seasons-h">Seasons</h2>
              <p>
                {LAUNCH.seasons.count} seasons of {LAUNCH.seasons.weeks} weeks,
                front-loaded: each pot is about{" "}
                <Fig
                  v={LAUNCH.seasons.decay ? `${LAUNCH.seasons.decay}×` : null}
                />{" "}
                the one before, because the earliest depositors take the most
                risk. {LAUNCH.seasons.pointsRule} A season's root is set only
                after a swarm panel attests the published points file; a claim
                vests over the following season, so staying keeps earning while
                last season's claim pays out. Unclaimed INFER rolls into the
                next season; after the last, to the Treasury.
              </p>
              <table className="infer-table infer-seasons">
                <thead>
                  <tr>
                    <th scope="col">Season</th>
                    <th scope="col">INFER</th>
                  </tr>
                </thead>
                <tbody>
                  {LAUNCH.seasons.amounts.map((amt, i) => (
                    <tr key={i}>
                      <td data-label="Season">{i + 1}</td>
                      <td data-label="INFER" className="infer-barcell">
                        <span className="infer-bar" aria-hidden="true">
                          <span
                            style={{
                              width: `${amt ? Number((BigInt(amt) * 1000n) / largestSeason) / 10 : 0}%`,
                            }}
                          />
                        </span>
                        <span className="infer-barvalue">
                          <Fig v={compact(amt)} />
                        </span>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <dl className="infer-lines">
                <Line
                  k="All seasons"
                  v={
                    <Fig
                      v={
                        seasonsTotal === null
                          ? null
                          : compact(seasonsTotal.toString())
                      }
                      unit="INFER"
                    />
                  }
                  strong
                />
                <Line
                  k="Share of supply"
                  v={<Fig v={pct(share("seasons"))} />}
                />
              </dl>
            </section>
          </div>
          <div className="infer-column">
            <section aria-labelledby="treasury-h">
              <h2 id="treasury-h">Treasury, fees and staking</h2>
              <p>
                The Treasury reserve is spent only by governance, every change
                public for 48 hours first.
              </p>
              <p>
                It also receives <Fig v={pct(LAUNCH.fees.treasuryBps)} /> of the
                launch pool's trading fees, in {LAUNCH.pair} and INFER. That
                revenue funds the oracle and buys the INFER that is dripped into
                sINFER, the staking vault: no emission, only what the protocol
                earns. Staked INFER also earns a points multiplier in the
                seasons.
              </p>
              <dl className="infer-lines">
                <Line
                  k="Held in reserve"
                  v={<Fig v={pct(share("treasury"))} />}
                  strong
                />
                <Line k="Launch pool" v={<Fig v={pct(share("pool"))} />} />
                <Line k="Swarm" v={<Fig v={pct(share("swarm"))} />} />
              </dl>
            </section>

            <section aria-labelledby="legacy-h">
              <h2 id="legacy-h">Legacy redemptions</h2>
              <p>
                Holders of the community's earlier tokens burn them for INFER at
                rates fixed from the redeemable supply on launch day, so neither
                allocation can be over-claimed. MIYA redeems at any time; MXXN
                only inside its full-moon transfer windows. Both close after one
                year, and what is left goes to the Treasury.
              </p>
              <dl className="infer-lines">
                {LAUNCH.redemptions.map((r) => (
                  <Line
                    key={r.key}
                    k={
                      <>
                        {r.symbol}
                        <small>
                          {" "}
                          · <Fig v={compact(r.allocation)} unit="INFER" />
                        </small>
                      </>
                    }
                    v={
                      <Fig
                        v={r.rate ? whole(r.rate, 6) : null}
                        unit={`per ${r.symbol}`}
                      />
                    }
                    strong
                  />
                ))}
              </dl>
            </section>

            <section aria-labelledby="founder-h">
              <h2 id="founder-h">Founder</h2>
              <p>
                The team allocation is a stream, not a grant: linear to
                miyagod.eth over{" "}
                <Fig
                  v={
                    LAUNCH.founder.months === null
                      ? null
                      : String(LAUNCH.founder.months)
                  }
                  unit="months"
                />{" "}
                with a{" "}
                <Fig
                  v={
                    LAUNCH.founder.cliffDays === null
                      ? null
                      : String(LAUNCH.founder.cliffDays)
                  }
                />
                -day cliff, from a contract with no admin. Nothing moves on day
                one.
              </p>
              <dl className="infer-lines">
                <Line
                  k="Streamed"
                  v={<Fig v={compact(LAUNCH.founder.amount)} unit="INFER" />}
                  strong
                />
                <Line
                  k="Share of supply"
                  v={<Fig v={pct(share("founder"))} />}
                />
              </dl>
            </section>
          </div>
        </div>
      </main>
    </Shell>
  );
}
