// WalletConnect for the INFER pages: a phone wallet signs for a page it is not running in, which is the
// only way to trade from inside the X app (it has no browser extensions). This module is imported only
// when someone picks WalletConnect, so the protocol's code is never part of a page load.
//
// The protocol alone (@walletconnect/universal-provider), not Reown's modal: the chooser, the QR code and
// the links to wallet apps are ours (WalletChooser in ui.tsx), drawn in the page's own type and colours,
// and the Content-Security-Policy admits only WalletConnect's relay (vite.config.ts `WALLETCONNECT_ORIGINS`).
import UniversalProvider from "@walletconnect/universal-provider";
import { getAddress, type Address, type EIP1193Provider } from "viem";
import { LAUNCH } from "./config";
import projectFile from "./walletconnect.json";

/** WalletConnect's (Reown Cloud) project id: public, it ships in the page. Null hides the option. */
const WC_PROJECT_ID: string | null = projectFile.projectId;

const CHAIN = `eip155:${LAUNCH.chainId}`;
const METHODS = [
  "eth_sendTransaction",
  "personal_sign",
  "eth_signTypedData_v4",
  "wallet_switchEthereumChain",
];

export type WcSession = {
  provider: EIP1193Provider & {
    on: (event: string, listener: (arg: unknown) => void) => void;
    removeListener: (event: string, listener: (arg: unknown) => void) => void;
  };
  account: Address;
  /** The wallet app's own link back to itself, to open it for each signature on a phone. */
  walletLink: string | null;
  walletName: string;
  disconnect: () => Promise<void>;
};

const PAIRING_TIMEOUT_MS = 15_000;
const withTimeout = <T>(work: Promise<T>, ms: number, why: string) =>
  new Promise<T>((resolve, reject) => {
    const t = setTimeout(() => reject(Error(why)), ms);
    work.then(
      (v) => (clearTimeout(t), resolve(v)),
      (e) => (clearTimeout(t), reject(e)),
    );
  });

let shared: Promise<UniversalProvider> | null = null;
function init(): Promise<UniversalProvider> {
  if (!WC_PROJECT_ID) throw Error("WalletConnect is not configured.");
  shared ??= UniversalProvider.init({
    projectId: WC_PROJECT_ID,
    metadata: {
      name: "INFER",
      description: "INFER, the imdUSD protocol's token",
      url: "https://infer.imdusd.com",
      icons: ["https://infer.imdusd.com/icon-512.png"],
    },
  }).catch((e) => {
    shared = null; // a failed start is retried from scratch, not remembered
    throw e;
  });
  return shared;
}

function session(p: UniversalProvider): WcSession {
  const accounts = p.session?.namespaces.eip155?.accounts ?? [];
  const mine = accounts.find((a) => a.startsWith(`${CHAIN}:`));
  if (!mine) throw Error("The wallet connected no Ethereum mainnet account.");
  const peer = p.session!.peer.metadata;
  const request = ((args: { method: string; params?: unknown[] | object }) =>
    p.request(args, CHAIN)) as EIP1193Provider["request"];
  type Listener = (arg: unknown) => void;
  return {
    provider: {
      request,
      on: (e: string, l: Listener) => void p.on(e, l),
      removeListener: (e: string, l: Listener) => void p.removeListener(e, l),
    },
    account: getAddress(mine.split(":")[2]),
    walletLink: peer.redirect?.universal || peer.redirect?.native || null,
    walletName: peer.name || "WalletConnect",
    disconnect: async () => {
      await p.disconnect().catch(() => undefined);
    },
  };
}

/** A session kept from an earlier visit, or null: no prompt, no QR. */
export async function restore(): Promise<WcSession | null> {
  const p = await init();
  if (!p.session) return null;
  p.setDefaultChain(CHAIN, LAUNCH.rpc[0]);
  return session(p);
}

/** Pair a wallet: `onUri` receives the pairing link to show as a QR code and to hand to wallet apps. */
export async function connect(
  onUri: (uri: string) => void,
): Promise<WcSession> {
  const p = await withTimeout(
    init(),
    PAIRING_TIMEOUT_MS,
    "Could not reach WalletConnect. Check your connection and try again.",
  );
  if (p.session) await p.disconnect().catch(() => undefined);
  // A refused project or an unreachable relay never produces a pairing link and never errors either,
  // so no link within the timeout is a failure the page reports instead of waiting forever.
  let paired: () => void = () => undefined;
  const linked = new Promise<void>((r) => (paired = r));
  const show = (uri: unknown) => {
    paired();
    onUri(String(uri));
  };
  p.on("display_uri", show);
  try {
    const approved = p.connect({
      optionalNamespaces: {
        eip155: {
          methods: METHODS,
          chains: [CHAIN],
          events: ["accountsChanged", "chainChanged"],
          rpcMap: { [LAUNCH.chainId]: LAUNCH.rpc[0] },
        },
      },
    });
    await withTimeout(
      Promise.race([linked, approved]),
      PAIRING_TIMEOUT_MS,
      "Could not reach WalletConnect. Check your connection and try again.",
    );
    await approved;
  } finally {
    p.removeListener("display_uri", show);
  }
  p.setDefaultChain(CHAIN, LAUNCH.rpc[0]);
  return session(p);
}
