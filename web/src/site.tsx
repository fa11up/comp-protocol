import type { ReactNode } from "react";
import { ThemeToggle } from "./theme";
import { Vibe } from "./vibe";
import { IMDUSD_VIBES } from "./vibe-imdusd";

// The site is three static pages (/, /terminal/, /docs/), so any host serves it with no routing
// rules. Each page names the site root relative to itself in <meta name="app-root">; every shared
// link and data file is resolved from there.
export function appRoot(): URL {
  const meta = document.querySelector<HTMLMetaElement>('meta[name="app-root"]');
  return new URL(meta?.content || "./", document.baseURI);
}
export const href = (path = "") => new URL(path, appRoot()).href;
/**
 * Whether this build serves the terminal. `vite build --mode public` makes the public site that goes on
 * imdusd.com: the homepage and docs only, with every terminal link replaced, so nothing links to a page
 * that is not served.
 */
export const TERMINAL = import.meta.env.MODE !== "public";
export const WHITEPAPER = "https://whitepaper.imdusd.com";
export const INFER_SITE = "https://infer.imdusd.com";

/** A header chip naming a network and its state ("Mainnet · live", "Robinhood · staging"), the state
 * pulsing. Shared with infer.imdusd.com. */
export function NetworkChip({
  network,
  state,
}: {
  network: string;
  state: "live" | "staging";
}) {
  return (
    <span className="chip">
      {network} · <span className={`chip-pulse chip-${state}`}>{state}</span>
    </span>
  );
}

type Page = "home" | "terminal" | "docs";
/** One header for every page: brand and navigation on the left; the network chip, theme, background and a
 * page-specific end on the right. */
export function SiteHeader({
  page,
  network,
  children,
}: {
  page: Page;
  network?: string;
  children?: ReactNode;
}) {
  const link = (to: Page, path: string, text: string) => (
    <a href={href(path)} aria-current={page === to ? "page" : undefined}>
      {text}
    </a>
  );
  return (
    <header className="topbar">
      <div className="brand">
        <a className="wordmark" href={href()} aria-label="imdUSD home">
          imd<b>USD</b>
        </a>
        <nav className="site-nav" aria-label="Site">
          {TERMINAL && link("terminal", "terminal/", "Terminal")}
          {link("docs", "docs/", "Docs")}
          <a href={INFER_SITE} target="_blank" rel="noreferrer">
            INFER ↗
          </a>
          <a href={WHITEPAPER} target="_blank" rel="noreferrer">
            Whitepaper ↗
          </a>
        </nav>
      </div>
      <div className="wallet-bar">
        {TERMINAL ? (
          <span className="chip">{`${network ?? "Sepolia"} · testnet`}</span>
        ) : (
          <span className="chips">
            <NetworkChip network="Mainnet" state="live" />
            <NetworkChip network="Robinhood" state="staging" />
          </span>
        )}
        <ThemeToggle />
        <Vibe suite={IMDUSD_VIBES} />
        {children}
      </div>
    </header>
  );
}
