import favicon from "../../public/favicon.svg?raw";

// Shared pieces of the three INFER pages: the shell, the wallet, the transaction runner and figures.
import { useEffect, useRef, useState, type ReactNode } from "react";
import {
  formatUnits,
  getAddress,
  parseUnits,
  type Address,
  type Hex,
} from "viem";
export { parseAmount } from "./amount";
import { ThemeToggle } from "../theme";
import { Vibe } from "../vibe";
import { INFER_VIBES } from "./vibes";
import { StagingChip } from "../site";
import { LAUNCH, LIVE } from "./config";
import { ERC20, client, message } from "./chain";
import { NATIVE } from "./swap";

export const SITE = "https://imdusd.com";
export const WHITEPAPER = "https://whitepaper.imdusd.com";

/** Links between the three pages, from the page's own directory depth. */
/** A negative depth means absolute links from the site root (the not-found page is served at any path). */
export const at = (depth: number) => (page: "" | "claim/" | "tokenomics/") =>
  depth < 0 ? `/${page}` : `${"../".repeat(depth)}${page}`;

/** A figure, or a dash while it is pending: the dash is drawn, the word is read out. */
export function Fig({
  v,
  unit,
}: {
  v: string | null | undefined;
  unit?: string;
}) {
  if (v === null || v === undefined)
    return (
      <>
        <b className="figure-dash" aria-hidden="true">
          —
        </b>
        <span className="sr-only">Pending</span>
      </>
    );
  return (
    <>
      {v}
      {unit ? ` ${unit}` : ""}
    </>
  );
}

/** Whole tokens from wei, grouped, at most `places` decimals; "…" while loading. */
export const tokens = (
  v: bigint | undefined | null,
  places = 2,
  decimals = 18,
) => {
  if (v === undefined || v === null) return "…";
  const [int, frac = ""] = formatUnits(v, decimals).split(".");
  const grouped = int.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const f = frac.slice(0, places).replace(/0+$/, "");
  return f ? `${grouped}.${f}` : grouped;
};

export const short = (a: Address) => `${a.slice(0, 6)}…${a.slice(-4)}`;

/** A message with a serial, so the same words twice still count as a new error. */
export type Notice = { id: number; text: string };
let noticeSeq = 0;
export const notice = (text: string): Notice => ({ id: ++noticeSeq, text });

// ------------------------------------------------------------------ wallet

export type Wallet = {
  account: Address | null;
  chainId: number | null;
  error: Notice | null;
  busy: boolean;
  connect: () => Promise<void>;
  clearError: () => void;
};

export function useWallet(): Wallet {
  const [w, setW] = useState<{
    account: Address | null;
    chainId: number | null;
    error: Notice | null;
  }>({ account: null, chainId: null, error: null });
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    const p = window.ethereum;
    if (!p?.on) return;
    const onAccounts = (a: unknown) => {
      const list = a as Address[];
      setW((s) => ({ ...s, account: list[0] ? getAddress(list[0]) : null }));
    };
    const onChain = (c: unknown) => setW((s) => ({ ...s, chainId: Number(c) }));
    p.on("accountsChanged", onAccounts);
    p.on("chainChanged", onChain);
    return () => {
      p.removeListener?.("accountsChanged", onAccounts);
      p.removeListener?.("chainChanged", onChain);
    };
  }, []);
  async function connect() {
    setBusy(true);
    try {
      const p = window.ethereum;
      if (!p)
        throw Error(
          "No browser wallet found. Install an Ethereum wallet extension, then reload.",
        );
      const a = (await p.request({
        method: "eth_requestAccounts",
      })) as Address[];
      if (!a?.[0]) throw Error("The wallet authorised no account.");
      const c = Number(await p.request({ method: "eth_chainId" }));
      if (c !== LAUNCH.chainId) {
        await p.request({
          method: "wallet_switchEthereumChain",
          params: [{ chainId: `0x${LAUNCH.chainId.toString(16)}` }],
        });
      }
      setW({ account: getAddress(a[0]), chainId: LAUNCH.chainId, error: null });
    } catch (e) {
      setW((s) => ({ ...s, error: notice(message(e)) }));
    } finally {
      setBusy(false);
    }
  }
  const clearError = () => setW((s) => ({ ...s, error: null }));
  return { ...w, busy, connect, clearError };
}

// ------------------------------------------------------------------ transactions

export type Tx = {
  id: number;
  label: string;
  status: "idle" | "pending" | "mined" | "failed";
  detail?: string;
  hash?: Hex;
};

/**
 * Simulate, sign, wait for one receipt. Every action on these pages goes through here. A second
 * send while one is in flight is ignored, so two quick clicks cannot start two transactions. A
 * failure after the hash is known keeps the hash: the transaction may well have mined, and the
 * receipt link is how the user finds out before trying again.
 */
export function useTx(onMined: () => void) {
  const [tx, setTx] = useState<Tx>({ id: 0, label: "", status: "idle" });
  const inFlight = useRef(false);
  async function send(label: string, run: () => Promise<Hex>) {
    if (inFlight.current) return;
    inFlight.current = true;
    const id = ++noticeSeq;
    setTx({ id, label, status: "pending" });
    let hash: Hex | undefined;
    try {
      hash = await run();
      setTx({
        id,
        label,
        status: "pending",
        hash,
        detail: "Waiting for the receipt…",
      });
      const receipt = await client.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success")
        throw Error("The transaction reverted.");
      setTx({ id, label, status: "mined", hash });
      onMined();
    } catch (e) {
      const detail =
        hash && !/reverted/.test(message(e))
          ? `could not confirm it: ${message(e)}`
          : message(e);
      setTx({ id, label, status: "failed", detail, hash });
    } finally {
      inFlight.current = false;
    }
  }
  const clear = () =>
    setTx((t) =>
      t.status === "failed" ? { id: 0, label: "", status: "idle" } : t,
    );
  return { tx, send, clear };
}

/** How long an error stays on screen before it swipes away. */
export const ERROR_LIFETIME_MS = 10_000;

/**
 * An error that leaves by itself: shown for ERROR_LIFETIME_MS, then swiped off to the left and
 * removed, and `onDone` tells the owner to forget it, so the same error can be shown again later.
 * Key it by the notice's serial, so a repeat while one is showing starts a fresh ten seconds. With
 * reduced motion, or with animations disabled altogether, it simply disappears at the end.
 */
export function Vanishing({
  className,
  onDone,
  children,
}: {
  className: string;
  onDone?: () => void;
  children: ReactNode;
}) {
  const [phase, setPhase] = useState<"shown" | "leaving" | "gone">("shown");
  useEffect(() => {
    const t = setTimeout(() => setPhase("leaving"), ERROR_LIFETIME_MS);
    return () => clearTimeout(t);
  }, []);
  useEffect(() => {
    if (phase !== "leaving") return;
    // If no animation ever ends (animations switched off), finish after it would have.
    const t = setTimeout(() => setPhase("gone"), 700);
    return () => clearTimeout(t);
  }, [phase]);
  useEffect(() => {
    if (phase === "gone") onDone?.();
  }, [phase, onDone]);
  if (phase === "gone") return null;
  return (
    <div
      className={`infer-vanish ${className}`}
      data-phase={phase}
      role="alert"
      onAnimationEnd={() => phase === "leaving" && setPhase("gone")}
    >
      {children}
    </div>
  );
}

/** A two-way switch: Buy/Sell, Stake/Unstake. Tabs with arrow keys and one tab stop. */
export function Switch<T extends string>({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: T;
  options: [T, string][];
  onChange: (v: T) => void;
}) {
  return (
    <div
      className="infer-switch"
      role="tablist"
      aria-label={label}
      onKeyDown={(e) => {
        if (e.key !== "ArrowLeft" && e.key !== "ArrowRight") return;
        e.preventDefault();
        const i = options.findIndex(([id]) => id === value);
        const next =
          options[
            (i + (e.key === "ArrowRight" ? 1 : options.length - 1)) %
              options.length
          ][0];
        onChange(next);
        (
          e.currentTarget.querySelector(
            `[data-id="${next}"]`,
          ) as HTMLButtonElement | null
        )?.focus();
      }}
    >
      {options.map(([id, text]) => (
        <button
          key={id}
          type="button"
          role="tab"
          data-id={id}
          aria-selected={value === id}
          tabIndex={value === id ? 0 : -1}
          onClick={() => onChange(id)}
        >
          {text}
        </button>
      ))}
    </div>
  );
}

export function TxStatus({ tx, onDone }: { tx: Tx; onDone?: () => void }) {
  if (tx.status === "idle") return null;
  if (tx.status === "failed")
    return (
      <Vanishing
        key={tx.id}
        className="infer-tx infer-tx-failed"
        onDone={onDone}
      >
        <b>{tx.label}</b>
        {" · "}
        {tx.detail}
        {tx.hash && (
          <>
            {" · "}
            <a
              href={`https://etherscan.io/tx/${tx.hash}`}
              target="_blank"
              rel="noreferrer"
            >
              receipt ↗
            </a>
          </>
        )}
      </Vanishing>
    );
  return (
    <p className="infer-tx" role="status" data-state={tx.status}>
      <b>{tx.label}</b>
      {" · "}
      {tx.status === "pending"
        ? (tx.detail ?? "confirm in your wallet")
        : tx.status === "mined"
          ? "done"
          : tx.detail}
      {tx.hash && (
        <>
          {" · "}
          <a
            href={`https://etherscan.io/tx/${tx.hash}`}
            target="_blank"
            rel="noreferrer"
          >
            receipt ↗
          </a>
        </>
      )}
    </p>
  );
}

// ------------------------------------------------------------------ shell

export function Shell({
  page,
  depth,
  wallet,
  children,
  className,
}: {
  page: "app" | "claim" | "tokenomics";
  depth: number;
  wallet: Wallet;
  children: ReactNode;
  className?: string;
}) {
  const to = at(depth);
  const link = (id: typeof page, href: string, text: string) => (
    <a href={href} aria-current={page === id ? "page" : undefined}>
      {text}
    </a>
  );
  return (
    <div className={`infer ${className ?? ""}`}>
      <header className="infer-top">
        <a className="infer-mark" href={to("")} aria-label="INFER">
          <Mark />
          INFER
        </a>
        <nav className="infer-nav" aria-label="Site">
          {link("app", to(""), "Trade")}
          {link("claim", to("claim/"), "Claim")}
          {link("tokenomics", to("tokenomics/"), "Tokenomics")}
          <a className="infer-case" href={`${SITE}/`}>
            imdUSD ↗
          </a>
        </nav>
        <div className="infer-tools">
          {LIVE ? <span className="chip">Mainnet</span> : <StagingChip />}
          <ThemeToggle />
          <Vibe suite={INFER_VIBES} />
          {wallet.account ? (
            <span className="infer-account" title={wallet.account}>
              {short(wallet.account)}
            </span>
          ) : (
            <button
              className="infer-connect"
              disabled={wallet.busy}
              onClick={wallet.connect}
            >
              {wallet.busy ? "Connecting…" : "Connect wallet"}
            </button>
          )}
        </div>
      </header>
      {wallet.error && (
        <Vanishing
          key={wallet.error.id}
          className="global-notice"
          onDone={wallet.clearError}
        >
          {wallet.error.text}
        </Vanishing>
      )}
      {children}
    </div>
  );
}

/** A label and its value joined by a dotted leader, the ledger's own line. */
export function Line({
  k,
  v,
  strong,
}: {
  k: ReactNode;
  v: ReactNode;
  strong?: boolean;
}) {
  return (
    <div className={`infer-line${strong ? " strong" : ""}`}>
      <dt>{k}</dt>
      <dd>{v}</dd>
    </div>
  );
}

// ------------------------------------------------------------------ balances

/**
 * The connected account's balance of each token: a bigint once read, `undefined` while reading or
 * with no account, `null` when the token does not exist yet (its address is unset before launch).
 * `NATIVE` reads the account's ETH.
 */
export function useBalances(
  account: Address | null,
  list: (Address | null)[],
  tick: number,
) {
  const [out, setOut] = useState<(bigint | null | undefined)[]>(() =>
    list.map(() => undefined),
  );
  const key = list.join(",");
  useEffect(() => {
    let stale = false;
    setOut(list.map((t) => (t === null ? null : undefined)));
    if (!account) return;
    Promise.all(
      list.map((t) =>
        t === null
          ? Promise.resolve(null)
          : (t === NATIVE
              ? client.getBalance({ address: account })
              : client.readContract({
                  address: t,
                  abi: ERC20,
                  functionName: "balanceOf",
                  args: [account],
                })
            ).catch(() => undefined),
      ),
    ).then((v) => {
      if (!stale) setOut(v);
    });
    return () => {
      stale = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [account, key, tick]);
  return out;
}

export const useBalance = (
  account: Address | null,
  token: Address | null,
  tick: number,
) => useBalances(account, [token], tick)[0];

/**
 * The balance shown on every input box. Disconnected, or none of the token: it says so. Otherwise
 * the amount, and a click puts the whole balance in the box, every last unit of it.
 */
export function Balance({
  account,
  value,
  symbol,
  decimals,
  onUse,
}: {
  account: Address | null;
  value: bigint | null | undefined;
  symbol: string;
  decimals: number;
  onUse: (amount: string) => void;
}) {
  if (!account) return <span className="infer-bal">disconnected</span>;
  if (value === undefined) return <span className="infer-bal">…</span>;
  if (value === null || value === 0n)
    return <span className="infer-bal">No {symbol}</span>;
  return (
    <button
      type="button"
      className="infer-bal infer-bal-use"
      title={`Use the whole balance: ${formatUnits(value, decimals)} ${symbol}`}
      onClick={() => onUse(formatUnits(value, decimals))}
    >
      {tokens(value, 4, decimals)} {symbol}
    </button>
  );
}

/** The site mark: the favicon's own pixels (public/favicon.svg), drawn in the text colour so it
 * follows the theme. Read from the file at build time, so the two can never drift apart. */
const MARK =
  favicon.match(/<g style="fill:var\(--text\)">(.*?)<\/g>/)?.[1] ?? "";
export function Mark() {
  return (
    <svg
      className="infer-mark-glyph"
      viewBox="0 0 16 16"
      width="26"
      height="26"
      shapeRendering="crispEdges"
      aria-hidden="true"
      focusable="false"
    >
      <g fill="currentColor" dangerouslySetInnerHTML={{ __html: MARK }} />
    </svg>
  );
}
