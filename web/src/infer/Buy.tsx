// /buy/: the page an X player card shows inside a post (480 × 560), and a page of its own anywhere else.
// The masthead carries INFER's price in USD and its market cap, live from the launch pool; the body is
// the site's engraved background, and the button opens the trade pane. Before launch every figure is a
// dash and the button says so. Inside a frame each link opens a new tab rather than navigating X's
// iframe; the Worker (worker/infer.js) lets x.com frame this one route and no other.
import { useEffect, useState } from "react";
import { LIVE } from "./config";
import { useInferMarket, usdCompact, usdPrice } from "./price";
import { Fig, Mark } from "./ui";

export function Buy() {
  const m = useInferMarket();
  const [framed, setFramed] = useState(false);
  useEffect(() => {
    try {
      setFramed(window.self !== window.top);
    } catch {
      setFramed(true);
    }
  }, []);
  const out = framed
    ? { target: "_blank", rel: "noopener noreferrer" }
    : { rel: "noopener" };
  return (
    <div className="infer infer-buy">
      <header className="infer-buy-top">
        <a className="infer-mark" href="../" aria-label="INFER home" {...out}>
          <Mark />
          INFER
        </a>
        <p className="infer-buy-price" aria-live="polite">
          <span className="sr-only">Price </span>
          <strong>
            <Fig v={m ? usdPrice(m.priceUsd) : null} />
          </strong>
          <span className="infer-buy-cap">
            {" · MC "}
            <Fig v={m ? usdCompact(m.marketCapUsd) : null} />
          </span>
        </p>
      </header>
      <main className="infer-buy-main">
        <p className="infer-kicker">
          Inference-Backed Endogenous Financial Reserve
        </p>
        <h1>INFER</h1>
        <p className="infer-buy-lede">
          The token of the imdUSD protocol, the dollar borrowed against staked
          IMD.
        </p>
        {LIVE ? (
          <a className="infer-buy-go" href="../" {...out}>
            Buy $INFER ↗
          </a>
        ) : (
          <a className="infer-buy-go" href="../tokenomics/" {...out}>
            Opens at launch · Tokenomics ↗
          </a>
        )}
      </main>
      <footer className="infer-buy-foot">infer.imdusd.com</footer>
    </div>
  );
}
