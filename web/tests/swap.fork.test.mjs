// The trade pane's swap encoding, exercised for real against a mainnet fork: buy IMD with ETH on the
// live IMD/ETH launch pool through the Universal Router, then sell some back through Permit2. Skipped
// when no anvil fork answers on 127.0.0.1:8545 (`anvil --fork-url <mainnet rpc>`).
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  parseEther,
} from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { mainnet } from "viem/chains";
import {
  encodeSwap,
  minimumOut,
  NATIVE,
  PERMIT2,
  QUOTER,
  UNIVERSAL_ROUTER,
  poolId,
} from "../src/infer/swap.ts";

const RPC = "http://127.0.0.1:8545";
const forked = await fetch(RPC, {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({
    jsonrpc: "2.0",
    id: 1,
    method: "eth_chainId",
    params: [],
  }),
})
  .then((r) => r.json())
  .then((j) => j.result === "0x1")
  .catch(() => false);

const IMD = "0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7";
const KEY = {
  currency0: NATIVE,
  currency1: IMD,
  fee: 10_000,
  tickSpacing: 200,
  hooks: NATIVE,
};
const ROUTER = {
  universalRouter: "0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af",
  quoter: "0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203",
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
};
const ERC20 = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 value) returns (bool)",
]);

test("the pool id matches the PoolManager's", () => {
  // The IMD/ETH pool id the protocol pins in DeploymentConfig.sol (IMD_POOL_ID).
  assert.equal(
    poolId(KEY),
    "0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3",
  );
});

test(
  "buy with ETH, then sell through Permit2, on a mainnet fork",
  { skip: !forked && "no anvil fork on :8545" },
  async () => {
    // A fresh key, funded by the fork. Anvil's well-known accounts are EIP-7702-delegated on mainnet (their
    // leaked keys were claimed), so ETH sent to them is forwarded away by their delegated code.
    const account = privateKeyToAccount(generatePrivateKey());
    const pub = createPublicClient({ chain: mainnet, transport: http(RPC) });
    const wal = createWalletClient({
      account,
      chain: mainnet,
      transport: http(RPC),
    });
    await pub.request({
      method: "anvil_setBalance",
      params: [account.address, `0x${parseEther("10").toString(16)}`],
    });
    assert.equal(
      await pub.getCode({ address: account.address }),
      undefined,
      "the test account carries no code",
    );
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 1200);

    // Buy: 1 ETH in.
    const amountIn = parseEther("1");
    const [quoted] = await pub.readContract({
      address: ROUTER.quoter,
      abi: QUOTER,
      functionName: "quoteExactInputSingle",
      args: [
        {
          poolKey: KEY,
          zeroForOne: true,
          exactAmount: amountIn,
          hookData: "0x",
        },
      ],
    });
    assert.ok(quoted > 0n, "a quote");
    const buy = encodeSwap({
      key: KEY,
      tokenIn: NATIVE,
      amountIn,
      minOut: minimumOut(quoted, 100),
    });
    assert.equal(buy.value, amountIn);
    const before = await pub.readContract({
      address: IMD,
      abi: ERC20,
      functionName: "balanceOf",
      args: [account.address],
    });
    let hash = await wal.writeContract({
      address: ROUTER.universalRouter,
      abi: UNIVERSAL_ROUTER,
      functionName: "execute",
      args: [buy.commands, buy.inputs, deadline],
      value: buy.value,
    });
    let receipt = await pub.waitForTransactionReceipt({ hash });
    assert.equal(receipt.status, "success", "the buy mined");
    const after = await pub.readContract({
      address: IMD,
      abi: ERC20,
      functionName: "balanceOf",
      args: [account.address],
    });
    const got = after - before;
    assert.ok(
      got >= minimumOut(quoted, 100) && got <= quoted,
      `received ${got} for a quote of ${quoted}`,
    );

    // Sell half of it back: ERC-20 approval to Permit2, Permit2 approval to the router, then the swap.
    const sellIn = got / 2n;
    hash = await wal.writeContract({
      address: IMD,
      abi: ERC20,
      functionName: "approve",
      args: [ROUTER.permit2, (1n << 256n) - 1n],
    });
    await pub.waitForTransactionReceipt({ hash });
    hash = await wal.writeContract({
      address: ROUTER.permit2,
      abi: PERMIT2,
      functionName: "approve",
      args: [IMD, ROUTER.universalRouter, (1n << 160n) - 1n, Number(deadline)],
    });
    await pub.waitForTransactionReceipt({ hash });
    const [quotedEth] = await pub.readContract({
      address: ROUTER.quoter,
      abi: QUOTER,
      functionName: "quoteExactInputSingle",
      args: [
        {
          poolKey: KEY,
          zeroForOne: false,
          exactAmount: sellIn,
          hookData: "0x",
        },
      ],
    });
    const sell = encodeSwap({
      key: KEY,
      tokenIn: IMD,
      amountIn: sellIn,
      minOut: minimumOut(quotedEth, 100),
    });
    assert.equal(sell.value, 0n);
    const ethBefore = await pub.getBalance({ address: account.address });
    hash = await wal.writeContract({
      address: ROUTER.universalRouter,
      abi: UNIVERSAL_ROUTER,
      functionName: "execute",
      args: [sell.commands, sell.inputs, deadline],
    });
    receipt = await pub.waitForTransactionReceipt({ hash });
    assert.equal(receipt.status, "success", "the sell mined");
    const ethAfter = await pub.getBalance({ address: account.address });
    const gas = receipt.gasUsed * receipt.effectiveGasPrice;
    const ethGot = ethAfter + gas - ethBefore;
    assert.ok(
      ethGot >= minimumOut(quotedEth, 100) && ethGot <= quotedEth,
      `received ${ethGot} wei for a quote of ${quotedEth}`,
    );
    const left = await pub.readContract({
      address: IMD,
      abi: ERC20,
      functionName: "balanceOf",
      args: [account.address],
    });
    assert.equal(
      left,
      after - sellIn,
      "exactly the amount sold left the wallet",
    );
  },
);
