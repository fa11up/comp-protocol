import type { ReactNode } from "react";
import { ThemeToggle } from "./theme";

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
export const WHITEPAPER = "https://infer.miyagod.eth.limo";

type Page = "home" | "terminal" | "docs";
/** One header for every page: brand, network chip, navigation, theme, and a page-specific end. */
export function SiteHeader({
  page,
  network = "Sepolia",
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
        <span className="chip">{network} · testnet</span>
        <nav className="site-nav" aria-label="Site">
          {TERMINAL && link("terminal", "terminal/", "Terminal")}
          {link("docs", "docs/", "Docs")}
          <a href={WHITEPAPER} target="_blank" rel="noreferrer">
            Whitepaper ↗
          </a>
        </nav>
      </div>
      <div className="wallet-bar">
        <ThemeToggle />
        {children}
      </div>
    </header>
  );
}
