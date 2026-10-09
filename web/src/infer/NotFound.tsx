// The INFER site's not-found page: served at any unknown path, so every link is absolute.
import { Shell, at, useSiteWallet } from "./ui";

export function NotFound() {
  const w = useSiteWallet();
  const to = at(-1);
  return (
    <Shell page="app" depth={-1} wallet={w} className="infer-page">
      <main className="infer-claim">
        <p className="infer-kicker">404</p>
        <h1>Page not found</h1>
        <p className="infer-lede">
          There is nothing at this address. Trade, claim and the tokenomics are
          where the site lives.
        </p>
        <nav className="infer-notfound-nav" aria-label="Where to go instead">
          <a href={to("")}>Trade</a>
          <a href={to("claim/")}>Claim</a>
          <a href={to("tokenomics/")}>Tokenomics</a>
        </nav>
      </main>
    </Shell>
  );
}
