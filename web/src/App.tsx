import { useCallback, useEffect, useRef, useState } from "react";
import {
  formatUnits,
  type Address,
  type Hash,
  type EIP1193Provider,
} from "viem";
import { loadConfig, switchChain, wallet, type Runtime } from "./config";
import { snapshot, type Snapshot, feedsReady } from "./state";
import { Pane, Tabs, type Actions, type Request, AddressLink } from "./actions";
import { Redemption } from "./Redemption";
import { Position, Work, Oracle, Keeper, Backing, Governance } from "./Panes";
import { message, fmt } from "./math";
import { explained } from "./explain";
import { ThemeToggle } from "./theme";
import { LoanBook, useCharts } from "./Charts";
import { Ticker } from "./motion";
import { MarketCap, compact } from "./MarketCap";
export default function App() {
  const [r, setRuntime] = useState<Runtime>();
  const [error, setError] = useState("");
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let active = true;
    setError("");
    loadConfig()
      .then((v) => {
        if (active) setRuntime(v);
      })
      .catch((e) => {
        if (active) setError(message(e));
      });
    return () => {
      active = false;
    };
  }, [attempt]);
  if (!r)
    return (
      <div className="boot">
        <h1>COMP / Terminal</h1>
        <ThemeToggle />
        <p role="status">
          {error || "Loading deployment and verifying ABI integrity…"}
        </p>
        {error && (
          <button onClick={() => setAttempt((x) => x + 1)}>
            Retry configuration
          </button>
        )}
      </div>
    );
  return <Terminal r={r} />;
}
function Terminal({ r }: { r: Runtime }) {
  const [account, setAccount] = useState<Address>();
  const [chainId, setChainId] = useState<number>();
  const [s, setSnapshot] = useState<Snapshot>();
  const [readError, setReadError] = useState("");
  const [refreshing, setRefreshing] = useState(false);
  const [walletError, setWalletError] = useState("");
  const [connecting, setConnecting] = useState(false);
  const [busy, setBusy] = useState("");
  const [review, setReview] = useState<{
    id: string;
    request: Request;
    account: Address;
  }>();
  const [tx, setTx] = useState<{ status: string; hash?: Hash; error?: string }>(
    { status: "No transaction submitted." },
  );
  const [now, setNow] = useState(BigInt(Math.floor(Date.now() / 1000)));
  const [mobilePane, setMobilePane] = useState("loans");
  const [desk, setDesk] = useState("position");
  const [view, setView] = useState("loans");
  const charts = useCharts(r, s);
  const dialog = useRef<HTMLDialogElement>(null);
  const locked = useRef(false);
  const serial = useRef(0);
  const accountRef = useRef(account);
  accountRef.current = account;
  const refresh = useCallback(async () => {
    const id = ++serial.current;
    setRefreshing(true);
    try {
      const next = await snapshot(r, account);
      if (id === serial.current) {
        setSnapshot(next);
        setReadError("");
      }
    } catch (e) {
      if (id === serial.current) {
        setReadError(message(e));
        setSnapshot(undefined);
      }
    } finally {
      if (id === serial.current) setRefreshing(false);
    }
  }, [r, account]);
  useEffect(() => {
    setSnapshot(undefined);
    void refresh();
    const i = setInterval(() => {
      if (document.visibilityState === "visible" && !locked.current)
        void refresh();
    }, 15000);
    return () => {
      clearInterval(i);
      serial.current++;
    };
  }, [refresh]);
  useEffect(() => {
    const i = setInterval(
      () => setNow(BigInt(Math.floor(Date.now() / 1000))),
      1000,
    );
    return () => clearInterval(i);
  }, []);
  useEffect(() => {
    const p = window.ethereum;
    if (!p) return;
    const changed = (a: unknown) => {
      setAccount((a as Address[])[0]);
      setReview(undefined);
      setSnapshot(undefined);
      setTx({ status: "Account changed. Review actions again." });
    };
    const network = (id: unknown) => {
      setChainId(Number(id));
      setReview(undefined);
    };
    p.on?.("accountsChanged", changed);
    p.on?.("chainChanged", network);
    void p
      .request({ method: "eth_accounts" })
      .then(changed)
      .catch(() => {});
    void p
      .request({ method: "eth_chainId" })
      .then(network)
      .catch(() => {});
    return () => {
      p.removeListener?.("accountsChanged", changed);
      p.removeListener?.("chainChanged", network);
    };
  }, []);
  useEffect(() => {
    if (review && !dialog.current?.open) dialog.current?.showModal();
    if (!review && dialog.current?.open) dialog.current.close();
  }, [review]);
  const correctChain = chainId === r.config.chainId;
  const recent = s && Date.now() - s.loadedAt < 45000;
  const ready =
    !!account &&
    correctChain &&
    !!s?.verified &&
    !!recent &&
    !readError &&
    s.errors.length === 0;
  const reason = !account
    ? "Connect a wallet to use this control."
    : !correctChain
      ? `Switch to ${r.config.network.name} to continue.`
      : !s
        ? "Waiting for verified contract state."
        : !recent
          ? "State is outdated. Refresh before continuing."
          : s.errors.length
            ? "Some required reads failed. Refresh before continuing."
            : "";
  async function connect() {
    setConnecting(true);
    setWalletError("");
    try {
      const p = window.ethereum;
      if (!p)
        throw Error(
          "No browser wallet found. Install an Ethereum wallet extension, then reload.",
        );
      const a = await p.request({ method: "eth_requestAccounts" });
      setAccount(a[0] as Address);
      setChainId(Number(await p.request({ method: "eth_chainId" })));
    } catch (e) {
      setWalletError(message(e));
    } finally {
      setConnecting(false);
    }
  }
  async function changeChain() {
    setConnecting(true);
    setWalletError("");
    try {
      if (!window.ethereum) throw Error("No wallet found.");
      await switchChain(r, window.ethereum);
      setChainId(
        Number(await window.ethereum.request({ method: "eth_chainId" })),
      );
    } catch (e) {
      setWalletError(message(e));
    } finally {
      setConnecting(false);
    }
  }
  async function guard(p: EIP1193Provider) {
    if (!ready || !account)
      throw Error(reason || "Fresh verified state is required.");
    const [accounts, chain] = await Promise.all([
      p.request({ method: "eth_accounts" }),
      p.request({ method: "eth_chainId" }),
    ]);
    if (
      Number(chain) !== r.config.chainId ||
      accounts[0]?.toLowerCase() !== account.toLowerCase() ||
      accountRef.current !== account
    )
      throw Error("Wallet account or chain changed. Refresh and review again.");
    if ((await r.client.getChainId()) !== r.config.chainId)
      throw Error("RPC chain mismatch.");
  }
  const actions: Actions = {
    ready,
    busy,
    reason,
    account,
    run: async (id, request) => {
      if (locked.current) throw Error("Wait for the current action to finish.");
      locked.current = true;
      setBusy(id);
      try {
        const p = window.ethereum;
        if (!p) throw Error("Connect a browser wallet.");
        await guard(p);
        await r.client
          .simulateContract({
            ...request.target,
            functionName: request.fn,
            args: request.args,
            account,
          })
          .catch((e) =>
            explained(
              e,
              { fn: request.fn, args: request.args, s, account },
              request.explain,
            ),
          );
        setTx({
          status: "Simulation passed. Review the transaction before signing.",
        });
        setReview({ id, request, account: account! });
      } finally {
        locked.current = false;
        setBusy("");
      }
    },
  };
  function cancelReview() {
    setReview(undefined);
    setTx({ status: "Review cancelled. Nothing was sent." });
  }
  async function submit() {
    if (!review || locked.current) return;
    const { id, request } = review;
    locked.current = true;
    setBusy(id);
    setTx({ status: "Checking the transaction again…" });
    try {
      const p = window.ethereum;
      if (!p) throw Error("Wallet disconnected.");
      if (review.account !== account)
        throw Error("Account changed. Cancel and review again.");
      await guard(p);
      const simulation = await r.client
        .simulateContract({
          ...request.target,
          functionName: request.fn,
          args: request.args,
          account,
        })
        .catch((e) =>
          explained(
            e,
            { fn: request.fn, args: request.args, s, account },
            request.explain,
          ),
        );
      await guard(p);
      setTx({ status: "Confirm this action in your wallet." });
      const hash = await wallet(r, p).writeContract({
        ...simulation.request,
        account: account!,
        chain: r.chain,
      });
      setTx({ status: "Submitted. Waiting for on-chain confirmation…", hash });
      setReview(undefined);
      const receipt = await r.client.waitForTransactionReceipt({
        hash,
        confirmations: 1,
        timeout: 120000,
      });
      if (receipt.status !== "success")
        throw Error("Transaction reverted on chain. No changes were applied.");
      setTx({ status: "Confirmed. Refreshing balances and state…", hash });
      await refresh();
      setTx({ status: "Confirmed on chain.", hash });
    } catch (e) {
      setTx((old) => ({
        ...old,
        status: "Action stopped.",
        error: message(e),
      }));
    } finally {
      locked.current = false;
      setBusy("");
    }
  }
  const monitor = [
    ["loans", "Loan book"],
    ["oracle", "Oracle"],
    ["backing", "Backing"],
  ] as const;
  const deskTabs = [
    ["position", "Position"],
    ["redemption", "Redeem"],
    ["work", "Work"],
    ["keeper", "Keeper"],
    ["governance", "Govern"],
  ] as const;
  return (
    <div className="terminal">
      <a href="#terminal-main" className="skip">
        Skip to terminal panes
      </a>
      <header className="topbar">
        <div className="brand">
          <h1>
            COMP<span> / </span>Terminal
          </h1>
          <span className="edition">Compute-backed stablecoin</span>
        </div>
        <div className="wallet-bar">
          <span className="network">{r.config.network.name} / testnet</span>
          <ThemeToggle />
          {account ? (
            <>
              <span className="account" title={account}>
                {account.slice(0, 6)}…{account.slice(-4)}
              </span>
              {!correctChain && (
                <button
                  className="primary"
                  disabled={connecting}
                  onClick={changeChain}
                >
                  {connecting
                    ? "Switching…"
                    : `Switch to ${r.config.network.name}`}
                </button>
              )}
            </>
          ) : (
            <button className="primary" disabled={connecting} onClick={connect}>
              {connecting ? "Connecting…" : "Connect wallet"}
            </button>
          )}
        </div>
      </header>
      {walletError || readError || s?.errors.length ? (
        <div className="global-notice" role="alert">
          {walletError ||
            readError ||
            `Unavailable reads: ${s?.errors.join(", ")}. Refresh to retry.`}
        </div>
      ) : null}
      <nav className="mobile-nav" aria-label="Terminal panes">
        <label>
          View pane
          <select
            value={mobilePane}
            onChange={(e) => {
              setMobilePane(e.target.value);
              if (deskTabs.some(([id]) => id === e.target.value))
                setDesk(e.target.value);
              else setView(e.target.value);
            }}
          >
            {[...monitor.slice(0, 1), ...deskTabs, ...monitor.slice(1)].map(
              ([id, label]) => (
                <option key={id} value={id}>
                  {label}
                </option>
              ),
            )}
          </select>
        </label>
      </nav>
      <main
        id="terminal-main"
        className="workspace"
        data-mobile-pane={mobilePane}
        data-desk={desk}
        data-monitor={view}
        tabIndex={-1}
      >
        <div className="monitor">
          <Tabs
            label="Monitor"
            tabs={monitor}
            value={view}
            onChange={(id) => {
              setView(id);
              setMobilePane(id);
            }}
          />
          <Pane
            monitor
            id="loans"
            index="00"
            title="Loan book"
            tag="Live risk bands"
          >
            <LoanBook charts={charts} available={!!s} />
          </Pane>
          <Pane monitor id="oracle" index="01" title="Oracle" tag="Feeds">
            <Oracle r={r} s={s} now={now} charts={charts} />
          </Pane>
          <Pane
            monitor
            columns
            id="backing"
            index="02"
            title="Backing"
            tag="Treasury"
          >
            <Backing r={r} s={s} />
          </Pane>
        </div>
        <div className="desk">
          <Tabs
            label="Desk"
            tabs={deskTabs}
            value={desk}
            onChange={(id) => {
              setDesk(id);
              setMobilePane(id);
            }}
          />
          <Pane
            desk
            id="position"
            index="03"
            title="Position"
            tag={account ? "Wallet" : "Disconnected"}
          >
            <Position r={r} s={s} actions={actions} />
          </Pane>
          <Pane
            desk
            id="redemption"
            index="04"
            title="Redemption"
            tag="Reserve first"
          >
            <Redemption r={r} s={s} actions={actions} />
          </Pane>
          <Pane
            desk
            id="work"
            index="05"
            title="Work"
            tag={
              s?.work.mode === "attested"
                ? "Attested"
                : s?.work.mode === "faucet"
                  ? "Test credits"
                  : "Oracle"
            }
          >
            <Work r={r} s={s} actions={actions} now={now} charts={charts} />
          </Pane>
          <Pane desk id="keeper" index="06" title="Keeper" tag="Permissionless">
            <Keeper r={r} s={s} actions={actions} now={now} />
          </Pane>
          <Pane
            desk
            id="governance"
            index="07"
            title="Governance"
            tag="Timelock"
          >
            <Governance r={r} s={s} actions={actions} now={now} />
          </Pane>
        </div>
      </main>
      <footer>
        <div className="statusbar">
          <span>
            <span className="status-dot" />{" "}
            {readError
              ? "RPC unavailable"
              : s
                ? feedsReady(s)
                  ? "Feeds ready"
                  : "Feeds require attention"
                : "Verifying deployment"}
          </span>
          <MarketCap supply={s?.v.supply} />
          <span title="Treasury reserve assets, valued in USD">
            Reserves{" "}
            <b>
              <Ticker
                text={
                  s?.v.reserveValue === undefined
                    ? "—"
                    : `$${compact.format(Number(formatUnits(s.v.reserveValue, 18)))}`
                }
              />
            </b>
          </span>
          <span>
            Block <b>{s?.block.toString() ?? "—"}</b>
          </span>
          <button
            className={`refresh${refreshing ? " is-refreshing" : ""}`}
            aria-label={refreshing ? "Refreshing state" : "Refresh state"}
            title="Refresh"
            disabled={refreshing || !!busy}
            onClick={() => void refresh()}
          >
            <svg
              viewBox="0 0 20 20"
              width="18"
              height="18"
              aria-hidden="true"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.5"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              <path d="M16 10a6 6 0 1 1-1.76-4.24" />
              <path d="M16 3.5v3.25h-3.25" />
            </svg>
          </button>
        </div>
        <div className="footer-line">
          <div className="transaction-status" role="status">
            <span>
              {busy ? "↳ " : ""}
              {tx.error || tx.status}
            </span>
            {tx.hash && (
              <a
                href={`${r.config.network.explorer}/tx/${tx.hash}`}
                target="_blank"
                rel="noreferrer"
              >
                View transaction ↗
              </a>
            )}
          </div>
          <div className="footer-meta">
            <span>COMP / v.11</span>
            <span>
              {s
                ? `Read ${Math.max(0, Math.floor((Date.now() - s.loadedAt) / 1000))}s ago`
                : "Awaiting RPC"}
            </span>
            <a href="./imd-deployment.json" target="_blank" rel="noreferrer">
              Deployment ↗
            </a>
          </div>
        </div>
      </footer>
      <dialog
        ref={dialog}
        onCancel={(e) => {
          if (busy) e.preventDefault();
          else cancelReview();
        }}
        onClose={() => {
          if (!busy) setReview(undefined);
        }}
      >
        <h2>Review transaction</h2>
        {review && (
          <>
            <p>{review.request.summary}</p>
            <AddressLink
              value={review.request.target.address}
              explorer={r.config.network.explorer}
              label="Target contract"
            />
            <p className="micro">
              {review.request.fn} · {r.config.network.name} · wallet {account}
            </p>
            <p className="micro">
              The transaction is simulated again before signing. Network gas is
              paid in ETH. Simulation cannot guarantee execution in a later
              block.
            </p>
            <div role="status">{tx.error || tx.status}</div>
            <div className="button-row">
              <button disabled={!!busy} onClick={cancelReview}>
                Cancel
              </button>
              <button
                className="primary"
                disabled={!!busy || !ready}
                onClick={() => void submit()}
              >
                {busy ? "Processing…" : "Confirm in wallet"}
              </button>
            </div>
          </>
        )}
      </dialog>
    </div>
  );
}
