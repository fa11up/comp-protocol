import { readFileSync } from "node:fs";
import {
  decodeFunctionData,
  encodeEventTopics,
  encodeAbiParameters,
  encodeFunctionResult,
  encodeErrorResult,
  parseEther,
  zeroAddress,
  maxUint256,
} from "viem";
export const config = JSON.parse(
  readFileSync(new URL("../deployment-source.json", import.meta.url)),
);
export const abi = Object.fromEntries(
  [
    "ParameterizedVault",
    "PriceFeed",
    "NhiFeed",
    "SpotFeed",
    "CompToken",
    "MockIMD",
    "Parameters",
    "Treasury",
    "UsdPriceFeed",
    "SwarmWorkOracle",
    "MockWorkOracle",
  ].map((n) => [
    n,
    JSON.parse(
      readFileSync(new URL(`../public/abi/${n}.json`, import.meta.url)),
    ),
  ]),
);
export const account = "0x0000000000000000000000000000000000000a11";
export const candidate = "0x0000000000000000000000000000000000000b22";
export const addresses = {
  ...Object.fromEntries(config.contracts.map((c) => [c.name, c.address])),
  imdToken: "0x0000000000000000000000000000000000000011",
  compToken: "0x0000000000000000000000000000000000000012",
  parameters: "0x0000000000000000000000000000000000000013",
  treasury: "0x0000000000000000000000000000000000000014",
  usdPriceFeed: "0x0000000000000000000000000000000000000015",
  oracle: "0x0000000000000000000000000000000000000016",
};
const W = 10n ** 18n;
export const txHash = "0x" + "ab".repeat(32);
const blockHash = "0x" + "cd".repeat(32);
export const fixture = () => ({
  minCR: 150n,
  workCeiling: 1250n * W,
  maxDivergenceBps: 2000n,
  spotMultiplier: 1,
  priceMultiplier: 1,
  logMode: "rpc",
  explorerEmpty: false,
  ownerReadFail: false,
  extraPoint: false,
  logsRequested: [],
  reserve: 100n * W,
  supply: 10000n * W,
  allowance: 0n,
  stale: false,
  mode: "faucet",
  rejectSimulation: false,
  candidateCR: 180n,
  rpcFail: false,
  codeMissing: false,
  chainMismatch: false,
  sent: [],
  calls: [],
  now: BigInt(Math.floor(Date.now() / 1000)),
  pendingKind: 5,
  pendingEta: 1n,
});
export const block = (s) => ({
  number: "0x100",
  hash: blockHash,
  parentHash: "0x" + "00".repeat(32),
  nonce: "0x0000000000000000",
  sha3Uncles: blockHash,
  logsBloom: "0x" + "00".repeat(256),
  transactionsRoot: blockHash,
  stateRoot: blockHash,
  receiptsRoot: blockHash,
  miner: zeroAddress,
  difficulty: "0x0",
  totalDifficulty: "0x0",
  extraData: "0x",
  size: "0x200",
  gasLimit: "0x1c9c380",
  gasUsed: "0x0",
  timestamp: "0x" + s.now.toString(16),
  transactions: [],
  uncles: [],
  baseFeePerGas: "0x1",
});
const byAddr = Object.fromEntries(
  Object.entries(addresses).map(([k, v]) => [v.toLowerCase(), k]),
);
const abiName = {
  imdToken: "MockIMD",
  compToken: "CompToken",
  parameters: "Parameters",
  treasury: "Treasury",
  usdPriceFeed: "UsdPriceFeed",
  oracle: "SwarmWorkOracle",
};
function call(s, params) {
  const tx = params[0],
    name = byAddr[tx.to.toLowerCase()];
  if (!name) throw Error("Unknown target " + tx.to);
  let a = abi[abiName[name] || name],
    decoded;
  try {
    decoded = decodeFunctionData({ abi: a, data: tx.data });
  } catch (e) {
    if (name === "oracle") {
      a = abi.MockWorkOracle;
      decoded = decodeFunctionData({ abi: a, data: tx.data });
    } else throw e;
  }
  const { functionName: f, args = [] } = decoded;
  s.calls.push({ name, fn: f, args });
  const fn = a.find((x) => x.type === "function" && x.name === f);
  if (
    name === "oracle" &&
    s.mode === "faucet" &&
    ![
      "vault",
      "deployer",
      "mintingRights",
      "grantRights",
      "consumeRights",
    ].includes(f)
  )
    throw Error("Unsupported function");
  let value;
  if (fn.stateMutability === "nonpayable") {
    if (s.rejectSimulation) {
      const error = new Error("execution reverted");
      error.data = encodeErrorResult({
        abi: abi.ParameterizedVault,
        errorName: "RedemptionWorsensBacking",
      });
      throw error;
    }
    if (f === "redeem")
      value = (args[0] * (10000n - fee(s, args[0])) * 10n ** 14n) / (2n * W);
    else if (f === "approve" || f === "transfer") value = true;
    else if (f === "sync") value = 0n;
  } else if (name === "ParameterizedVault") {
    const scalar = {
      minCR: s.minCR,
      redemptionCeilingCR: s.minCR + 50n,
      redemptionSpread: 50n,
      redemptionReserve: s.reserve,
      REDEMPTION_FEE_FLOOR_BPS: 50n,
      REDEMPTION_FEE_CAP_BPS: 500n,
      totalDebt: s.supply - 20n * W,
      totalBadDebt: 0n,
      totalWorkMinted: 20n * W,
      totalNonPrincipalRedeemed: 0n,
      workCeiling: s.workCeiling,
      workRatioBps: 2500n,
      reserveValue: 1000n * W,
      securedCollateral: 1000n * W,
      backedDebt: 1000n * W,
      debtCeiling: 1000000n * W,
      stabilityFeeBps: 200n,
      maxDivergenceBps: s.maxDivergenceBps,
      gracePeriod: 21600n,
      liquidationWindow: 3600n,
      stabilityFeeOf: W,
      badDebtOf: 0n,
      debtOf: 1000n * W,
    };
    if (f in addresses) value = addresses[f];
    else if (f === "priceFeed") value = addresses.PriceFeed;
    else if (f === "nhiFeed") value = addresses.NhiFeed;
    else if (f === "spotFeed") value = addresses.SpotFeed;
    else if (f === "redemptionFeeBps") value = fee(s, args[0]);
    else if (f === "collateralRatio")
      value =
        args[0].toLowerCase() === candidate.toLowerCase()
          ? s.candidateCR
          : args[0].toLowerCase() === extraOwner.toLowerCase()
            ? BigInt(Math.round(260 * s.priceMultiplier))
            : BigInt(Math.round(175 * s.priceMultiplier));
    else if (f === "positions") {
      if (s.ownerReadFail && args[0].toLowerCase() === extraOwner.toLowerCase())
        throw Error("Position read unavailable");
      value =
        args[0].toLowerCase() === closedOwner.toLowerCase()
          ? [100n * W, 0n]
          : [
              1000n * W,
              args[0].toLowerCase() === extraOwner.toLowerCase()
                ? 250n * W
                : 1000n * W,
            ];
    } else if (f === "liquidationMarks")
      value = [s.now - 22000n, 21600n, true, account];
    else value = scalar[f];
  } else if (["imdToken", "compToken"].includes(name)) {
    value = {
      deployer: account,
      decimals: 18,
      balanceOf: 10000n * W,
      allowance: s.allowance,
      totalSupply: s.supply,
      vault: addresses.ParameterizedVault,
    }[f];
  } else if (name === "parameters") {
    const current = {
      debtCeiling: 1000000n * W,
      protocolBonusShareBps: 1000n,
      stabilityFeeBps: 200n,
      maxDivergenceBps: s.maxDivergenceBps,
      markerShareBps: 1000n,
    };
    value = {
      vault: addresses.ParameterizedVault,
      governor: account,
      TIMELOCK: 172800n,
      pendingChange: [s.pendingKind, s.pendingEta],
      current,
      compPerTaskWad: W / 10n,
      pendingRedemptionSpread: [50n, s.pendingEta],
      pendingWorkRatio: [2500n, 0n],
      pendingReserveAsset: [zeroAddress, zeroAddress, 0n, 0n],
      pendingSet: [current, 0n],
      pending: "0x",
    }[f];
  } else if (name === "treasury")
    value = {
      vault: addresses.ParameterizedVault,
      reserveAssets: [addresses.imdToken],
      withdrawer: account,
    }[f];
  else if (name === "oracle")
    value = {
      vault: addresses.ParameterizedVault,
      deployer: account,
      mintingRights: 980n * W,
      attestedTasks: 10000n,
      creditedTasks: 9000n,
      earnedRights: 1000n * W,
      consumedRights: 20n * W,
      compPerTaskWad: W / 10n,
      CLAIMANT: account,
      AGENT_ID: 51450n,
      latestValue: [10000n, s.now - 3600n],
      isStale: s.stale,
      maxAge: 86400n,
    }[f];
  else
    value = {
      latestValue: [
        name === "usdPriceFeed"
          ? 2n * W
          : name === "NhiFeed"
            ? (85n * W) / 100n
            : name === "SpotFeed"
              ? BigInt(Math.round(1e15 * s.spotMultiplier))
              : W / 1000n,
        s.now - 120n,
      ],
      isStale: s.stale,
      maxAge: 86400n,
      isReporter: true,
    }[f];
  if (value === undefined && fn.outputs.length)
    throw Error(`Missing fixture ${name}.${f}`);
  return encodeFunctionResult({ abi: a, functionName: f, result: value });
}
function fee(s, amount) {
  const base = (amount * W) / s.supply / 4n;
  const capped = base > 450n * 10n ** 14n ? 450n * 10n ** 14n : base;
  return 50n + (capped + 10n ** 14n - 1n) / 10n ** 14n;
}
export function rpc(s, body) {
  try {
    if (s.rpcFail) throw Error("Fixture RPC unavailable");
    let result;
    switch (body.method) {
      case "eth_chainId":
        result = s.chainMismatch ? "0x1" : "0xaa36a7";
        break;
      case "eth_getLogs": {
        s.logsRequested.push(body.params[0]);
        const p = body.params[0];
        result =
          s.logMode === "rpc"
            ? fixtureLogs(s, p.address).filter(
                (l) =>
                  BigInt(l.blockNumber) >= BigInt(p.fromBlock) &&
                  BigInt(l.blockNumber) <= BigInt(p.toBlock),
              )
            : [];
        break;
      }
      case "eth_getCode":
        result =
          s.codeMissing ||
          (body.params[1] !== "latest" && BigInt(body.params[1]) < 16n)
            ? "0x"
            : "0x6001600055";
        break;
      case "eth_blockNumber":
        result = "0x100";
        break;
      case "eth_getBlockByNumber":
        result = block(s);
        break;
      case "eth_call":
        result = call(s, body.params);
        break;
      case "eth_getTransactionReceipt":
        result = {
          transactionHash: txHash,
          transactionIndex: "0x0",
          blockHash,
          blockNumber: "0x100",
          from: account,
          to: addresses.ParameterizedVault,
          cumulativeGasUsed: "0x5208",
          gasUsed: "0x5208",
          contractAddress: null,
          logs: [],
          logsBloom: "0x" + "00".repeat(256),
          status: "0x1",
          effectiveGasPrice: "0x1",
          type: "0x2",
        };
        break;
      default:
        throw Error("Unmocked RPC " + body.method);
    }
    return { jsonrpc: "2.0", id: body.id, result };
  } catch (e) {
    return {
      jsonrpc: "2.0",
      id: body.id,
      error: { code: -32000, message: e.message, data: e.data },
    };
  }
}
export function sent(s, tx) {
  const name = byAddr[tx.to.toLowerCase()];
  const a = abi[abiName[name] || name];
  const d = decodeFunctionData({ abi: a, data: tx.data });
  s.sent.push({ name, ...d });
  if (d.functionName === "approve") s.allowance = d.args[1];
  return txHash;
}
export async function installWallet(
  page,
  { chain = "0x1", reject = false } = {},
) {
  await page.addInitScript(
    ({ account, chain, reject }) => {
      const listeners = {};
      window.__wallet = {
        chain,
        connected: false,
        added: false,
        reject,
        requests: [],
      };
      window.ethereum = {
        on: (n, cb) => {
          listeners[n] = cb;
        },
        removeListener: (n) => {
          delete listeners[n];
        },
        request: async ({ method, params }) => {
          const w = window.__wallet;
          w.requests.push({ method, params });
          if (method === "eth_accounts") return w.connected ? [account] : [];
          if (method === "eth_requestAccounts") {
            if (w.reject) throw { code: 4001, message: "User rejected" };
            w.connected = true;
            return [account];
          }
          if (method === "eth_chainId") return w.chain;
          if (method === "wallet_switchEthereumChain") {
            if (!w.added) {
              throw { code: 4902, message: "Unknown chain" };
            }
            w.chain = params[0].chainId;
            listeners.chainChanged?.(w.chain);
            return null;
          }
          if (method === "wallet_addEthereumChain") {
            w.added = true;
            return null;
          }
          if (method === "eth_sendTransaction") {
            if (w.reject) throw { code: 4001, message: "User rejected" };
            return window.__sendFixture(params[0]);
          }
          throw Error("Unmocked wallet " + method);
        },
      };
    },
    { account, chain, reject },
  );
}

export const extraOwner = "0x0000000000000000000000000000000000000c33";
export const closedOwner = "0x0000000000000000000000000000000000000d44";
export function fixtureLogs(s, address) {
  const name = byAddr[address.toLowerCase()];
  const a = abi[abiName[name] || name];
  const event = (eventName, args, height, index) => {
    const item = a.find((e) => e.type === "event" && e.name === eventName);
    return {
      address,
      topics: encodeEventTopics({ abi: a, eventName, args }),
      data: encodeAbiParameters(
        item.inputs.filter((i) => !i.indexed),
        item.inputs.filter((i) => !i.indexed).map((i) => args[i.name]),
      ),
      blockNumber: "0x" + height.toString(16),
      logIndex: "0x" + index.toString(16),
      transactionIndex: "0x0",
      transactionHash: "0x" + height.toString(16).padStart(64, "0"),
      blockHash,
      removed: false,
    };
  };
  if (name === "ParameterizedVault")
    return [account, candidate, extraOwner, closedOwner, account].map(
      (owner, i) =>
        event(
          "CollateralDeposited",
          { account: owner, amount: 100n * W },
          100 + i,
          0,
        ),
    );
  if (!["PriceFeed", "NhiFeed", "SpotFeed", "oracle"].includes(name)) return [];
  return [7200, 7000, 2400, 120, ...(s.extraPoint ? [30] : [])].flatMap(
    (seconds, i) => {
      const value =
        name === "NhiFeed"
          ? ((80n + BigInt(i)) * W) / 100n
          : name === "oracle"
            ? 10000n + BigInt(i)
            : W / 1000n + (BigInt(i) * W) / 100000n;
      return [
        event(
          "ValueUpdated",
          { value, updatedAt: s.now - BigInt(seconds) },
          100 + i * 10,
          0,
        ),
        event(
          "AttestationAccepted",
          {
            requestId: "0x" + i.toString(16).padStart(64, "0"),
            questionHash: "0x" + "01".repeat(32),
          },
          100 + i * 10,
          1,
        ),
      ];
    },
  );
}
export function blockscout(s, url) {
  const parsed = new URL(url),
    address = parsed.pathname.split("/")[4];
  const all = s.explorerEmpty ? [] : fixtureLogs(s, address).reverse();
  const page = Number(parsed.searchParams.get("cursor") || 0);
  const items = all.slice(page, page + 3).map((l) => ({
    address: { hash: l.address },
    block_number: Number(BigInt(l.blockNumber)),
    index: Number(BigInt(l.logIndex)),
    transaction_hash: l.transactionHash,
    data: l.data,
    topics: l.topics,
  }));
  return {
    items,
    next_page_params: page + 3 < all.length ? { cursor: page + 3 } : null,
  };
}
