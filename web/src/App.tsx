import { useCallback, useEffect, useRef, useState } from "react";
import { type Address, type Hash, type EIP1193Provider } from "viem";
import { loadConfig, switchChain, wallet, type Runtime } from "./config";
import { snapshot, type Snapshot, feedsReady } from "./state";
import { Pane, type Actions, type Request, AddressLink } from "./actions";
import { Redemption } from "./Redemption";
import { Position, Work, Oracle, Keeper, Backing, Governance } from "./Panes";
import { message, fmt } from "./math";
import { explained } from "./explain";
import { ThemeToggle } from "./theme";
import { LoanBook, useCharts } from "./Charts";
import { Ticker } from "./motion";
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
  const panes = [
    "loans",
    "position",
    "redemption",
    "work",
    "oracle",
    "keeper",
    "backing",
    "governance",
  ];
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
          <ThemeToggle />
          <span className="network">{r.config.network.name} / testnet</span>
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
        <span>
          Supply{" "}
          <b>
            <Ticker text={`${fmt(s?.v.supply, 18, 2)} COMP`} />
          </b>
        </span>
        <span>
          Block <b>{s?.block.toString() ?? "—"}</b>
        </span>
        <button disabled={refreshing || !!busy} onClick={() => void refresh()}>
          {refreshing ? "Refreshing…" : "Refresh state"}
        </button>
      </div>
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
            onChange={(e) => setMobilePane(e.target.value)}
          >
            {panes.map((p) => (
              <option key={p} value={p}>
                {p[0].toUpperCase() + p.slice(1)}
              </option>
            ))}
          </select>
        </label>
      </nav>
      <main
        id="terminal-main"
        className="grid"
        data-mobile-pane={mobilePane}
        tabIndex={-1}
      >
        <Pane id="loans" index="00" title="Loan book" tag="Live risk bands">
          <LoanBook charts={charts} available={!!s} />
        </Pane>
        <Pane
          id="position"
          index="01"
          title="Position"
          tag={account ? "Wallet" : "Disconnected"}
        >
          <Position r={r} s={s} actions={actions} />
        </Pane>
        <Pane id="redemption" index="02" title="Redemption" tag="Reserve first">
          <Redemption r={r} s={s} actions={actions} />
        </Pane>
        <Pane
          id="work"
          index="03"
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
        <Pane id="oracle" index="04" title="Oracle" tag="Feeds">
          <Oracle r={r} s={s} actions={actions} now={now} charts={charts} />
        </Pane>
        <Pane id="keeper" index="05" title="Keeper" tag="Permissionless">
          <Keeper r={r} s={s} actions={actions} now={now} />
        </Pane>
        <Pane id="backing" index="06" title="Backing" tag="Treasury">
          <Backing r={r} s={s} actions={actions} />
        </Pane>
        <Pane id="governance" index="07" title="Governance" tag="Timelock">
          <Governance r={r} s={s} actions={actions} now={now} />
        </Pane>
      </main>
      <footer>
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
          <span>COMP / v.10</span>
          <span>
            {s
              ? `Read ${Math.max(0, Math.floor((Date.now() - s.loadedAt) / 1000))}s ago`
              : "Awaiting RPC"}
          </span>
          <a href="./imd-deployment.json" target="_blank" rel="noreferrer">
            Deployment ↗
          </a>
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
