// /buy/: the page an X player card shows inside a post (480 × 560), and a page of its own anywhere else.
// The masthead carries INFER's price in USD and its market cap, live from the launch pool; the body is
// the site's engraved background with two buttons: Tokenomics, and Buy $INFER, which drops the home
// page's trade pane (App.tsx `Trade`, compact, no staking) in under the masthead, so a trade never
// leaves the card. Connecting offers every browser wallet and WalletConnect, the way into a phone wallet
// from the X app, which has no extensions (ui.tsx WalletChooser).
// Before launch every figure is a dash and the pane says trading opens at launch. Inside a frame each
// link opens a new tab rather than navigating X's iframe; the Worker (worker/infer.js) lets x.com frame
// this one route and no other.
import { useEffect, useRef, useState } from "react";
import { Trade } from "./App";
import { LIVE } from "./config";
import { useInferMarket, usdCompact, usdPrice } from "./price";
import { Fig, Mark, WalletChooser, short, useWallet } from "./ui";

export function Buy() {
  const m = useInferMarket();
  const w = useWallet();
  const sheet = useRef<HTMLDialogElement>(null);
  const [framed, setFramed] = useState(false);
  const [tick, setTick] = useState(0);
  const refresh = () => setTick((t) => t + 1);
  useEffect(() => {
    try {
      setFramed(window.self !== window.top);
    } catch {
      setFramed(true);
    }
  }, []);
  // The trade pane's balances and quote follow the chain at its block time, as on the home page.
  useEffect(() => {
    if (!LIVE) return;
    const t = setInterval(refresh, 12_000);
    return () => clearInterval(t);
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
        <p className="infer-buy-price">
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
        <div className="infer-buy-actions">
          <a className="infer-buy-alt" href="../tokenomics/" {...out}>
            Tokenomics ↗
          </a>
          <button
            type="button"
            className="infer-buy-go"
            aria-haspopup="dialog"
            onClick={() => sheet.current?.showModal()}
          >
            Buy $INFER
          </button>
        </div>
      </main>
      <footer className="infer-buy-foot">infer.imdusd.com</footer>

      {/* A modal dialog: Escape and the close button dismiss it, focus stays inside while it is open
          and returns to the button after, and a click on the backdrop closes it too. */}
      <dialog
        ref={sheet}
        className="infer-buy-sheet"
        aria-label="Buy INFER"
        onClick={(e) => e.target === e.currentTarget && sheet.current?.close()}
      >
        {w.account && (
          <div className="infer-buy-sheet-bar">
            <span title={w.account}>{short(w.account)}</span>
            {w.walletLink && (
              <a href={w.walletLink} target="_blank" rel="noopener noreferrer">
                Open wallet ↗
              </a>
            )}
            <button type="button" onClick={() => void w.disconnect()}>
              Disconnect
            </button>
          </div>
        )}
        {w.error && !w.choosing && (
          <p className="infer-buy-sheet-error" role="alert">
            {w.error.text}
          </p>
        )}
        <Trade w={w} tick={tick} refresh={refresh} compact />
      </dialog>
      <WalletChooser wallet={w} />
    </div>
  );
}
