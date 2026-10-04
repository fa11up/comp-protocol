// Uniswap v4 spot price, read the way the plane's own `univ4-spot` recipe reads it.
//
// This is deliberately a port rather than an approximation: the feed only accepts an attestation
// answering the question it pins, and that question names this recipe. If the watcher computed the
// price differently from the panel, it would trigger on a number nobody will attest to.
//
// Derivation, from apps/deployer/src/oracle-recipes.ts in the plane:
//   the canonical PoolManager keeps `mapping(PoolId => Pool.State) _pools` at slot 6, and a pool's
//   slot0 is the first word of its State, so the word is at keccak256(abi.encode(poolId, 6)) and
//   sqrtPriceX96 is its low 160 bits.
import { utils, BigNumber } from "ethers";

export const V4_POOLS_SLOT = 6;
const SQRT_PRICE_MASK = BigNumber.from(1).shl(160).sub(1);
const Q192 = BigNumber.from(1).shl(192);
const WAD = BigNumber.from(10).pow(18);

export const EXTSLOAD_ABI = ["function extsload(bytes32 slot) view returns (bytes32)"];

export function poolStateSlot(poolId) {
  return utils.keccak256(utils.defaultAbiCoder.encode(["bytes32", "uint256"], [poolId, V4_POOLS_SLOT]));
}

/** currency0 per 1e18 currency1, or the other way round with `invert`. Exact integer arithmetic. */
export function spotFromSqrtPrice(sqrtPriceX96, invert = false) {
  const sqrt = BigNumber.from(sqrtPriceX96);
  if (sqrt.isZero()) throw new Error("pool is not initialised here: sqrtPriceX96 is 0");
  const squared = sqrt.mul(sqrt);
  return invert ? WAD.mul(squared).div(Q192) : WAD.mul(Q192).div(squared);
}

/** The live spot, in wei of currency0 per 1e18 raw units of currency1 (ETH per IMD, for our pool). */
export async function readSpot(provider, { poolManager, poolId, invert = false }, blockTag = "latest") {
  const word = await provider.call(
    { to: poolManager, data: new utils.Interface(EXTSLOAD_ABI).encodeFunctionData("extsload", [poolStateSlot(poolId)]) },
    blockTag,
  );
  const sqrtPriceX96 = BigNumber.from(word).and(SQRT_PRICE_MASK);
  return { sqrtPriceX96, spot: spotFromSqrtPrice(sqrtPriceX96, invert) };
}
