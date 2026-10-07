// Swapping on the launch pool, a Uniswap v4 pool, through Uniswap's own contracts: the V4 Quoter for a
// quote, Permit2 for the allowance, and the Universal Router for the swap. Pure encoding here, no DOM,
// so Node can run it against a mainnet fork (tests/swap.fork.test.mjs) and the browser imports the same.
//
// Universal Router (mainnet 0x66a9…8Af, verified to embed the PoolManager): `execute(commands, inputs,
// deadline)`. One command, V4_SWAP (0x10), whose input is `abi.encode(bytes actions, bytes[] params)`
// with three actions: SWAP_EXACT_IN_SINGLE (0x06), SETTLE_ALL (0x0c) for the currency paid, TAKE_ALL
// (0x0f) for the currency received. A native-ETH leg is currency address(0) and travels as msg.value.
import {
  encodeAbiParameters,
  encodePacked,
  keccak256,
  parseAbi,
  type Address,
  type Hex,
} from "viem";

export type PoolKey = {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
};
export const NATIVE: Address = "0x0000000000000000000000000000000000000000";

export const UNIVERSAL_ROUTER = parseAbi([
  "function execute(bytes commands, bytes[] inputs, uint256 deadline) payable",
]);
export const QUOTER = parseAbi([
  // Not a view on chain (it reverts with its answer and catches it), but it is read with eth_call.
  "function quoteExactInputSingle(((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData) params) view returns (uint256 amountOut, uint256 gasEstimate)",
]);
export const PERMIT2 = parseAbi([
  "function allowance(address user, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)",
  "function approve(address token, address spender, uint160 amount, uint48 expiration)",
]);

const POOL_KEY_ABI = [
  {
    type: "tuple",
    components: [
      { name: "currency0", type: "address" },
      { name: "currency1", type: "address" },
      { name: "fee", type: "uint24" },
      { name: "tickSpacing", type: "int24" },
      { name: "hooks", type: "address" },
    ],
  },
] as const;

const EXACT_IN_SINGLE_ABI = [
  {
    type: "tuple",
    components: [
      {
        name: "poolKey",
        type: "tuple",
        components: [
          { name: "currency0", type: "address" },
          { name: "currency1", type: "address" },
          { name: "fee", type: "uint24" },
          { name: "tickSpacing", type: "int24" },
          { name: "hooks", type: "address" },
        ],
      },
      { name: "zeroForOne", type: "bool" },
      { name: "amountIn", type: "uint128" },
      { name: "amountOutMinimum", type: "uint128" },
      { name: "hookData", type: "bytes" },
    ],
  },
] as const;

/** The PoolManager's id for a key: keccak of the ABI-encoded key. */
export const poolId = (key: PoolKey): Hex =>
  keccak256(encodeAbiParameters(POOL_KEY_ABI, [key]));

/** The storage slot of the pool's slot0 in the PoolManager (`_pools` is at slot 6). */
export const slot0Slot = (key: PoolKey): Hex =>
  keccak256(
    encodeAbiParameters(
      [{ type: "bytes32" }, { type: "uint256" }],
      [poolId(key), 6n],
    ),
  );

/**
 * From a packed slot0 word: currency1 per currency0 (how much of currency1 one currency0 buys),
 * 1e18-scaled; or, with `inverse`, currency0 per currency1. For "pair per INFER" pass `inverse`
 * when INFER is currency1.
 */
export function priceFromSlot0(word: Hex, inverse: boolean): bigint {
  const sqrtP = BigInt(word) & ((1n << 160n) - 1n);
  if (sqrtP === 0n) return 0n;
  const Q = 1n << 96n;
  const c1PerC0 = (sqrtP * sqrtP * 10n ** 18n) / (Q * Q); // currency1 per currency0
  if (!inverse) return c1PerC0;
  return c1PerC0 === 0n ? 0n : 10n ** 36n / c1PerC0;
}

export const sorted = (a: Address, b: Address): boolean =>
  a.toLowerCase() < b.toLowerCase();

/** The calldata pieces for an exact-input single-pool swap: `execute(commands, inputs, deadline)`. */
export function encodeSwap(args: {
  key: PoolKey;
  tokenIn: Address;
  amountIn: bigint;
  minOut: bigint;
}): { commands: Hex; inputs: Hex[]; value: bigint } {
  const { key, tokenIn, amountIn, minOut } = args;
  if (amountIn > (1n << 128n) - 1n || minOut > (1n << 128n) - 1n)
    throw Error("Amount does not fit uint128.");
  const zeroForOne = tokenIn.toLowerCase() === key.currency0.toLowerCase();
  if (!zeroForOne && tokenIn.toLowerCase() !== key.currency1.toLowerCase())
    throw Error("Token is not in the pool.");
  const tokenOut = zeroForOne ? key.currency1 : key.currency0;
  const actions = encodePacked(["uint8", "uint8", "uint8"], [0x06, 0x0c, 0x0f]);
  const params: Hex[] = [
    encodeAbiParameters(EXACT_IN_SINGLE_ABI, [
      {
        poolKey: key,
        zeroForOne,
        amountIn,
        amountOutMinimum: minOut,
        hookData: "0x",
      },
    ]),
    encodeAbiParameters(
      [{ type: "address" }, { type: "uint256" }],
      [tokenIn, amountIn],
    ),
    encodeAbiParameters(
      [{ type: "address" }, { type: "uint256" }],
      [tokenOut, minOut],
    ),
  ];
  const input = encodeAbiParameters(
    [{ type: "bytes" }, { type: "bytes[]" }],
    [actions, params],
  );
  return {
    commands: "0x10",
    inputs: [input],
    value: tokenIn === NATIVE ? amountIn : 0n,
  };
}

/** The least a swap may return at `slippageBps` below the quote. */
export const minimumOut = (quoted: bigint, slippageBps: number) =>
  (quoted * BigInt(10_000 - slippageBps)) / 10_000n;
