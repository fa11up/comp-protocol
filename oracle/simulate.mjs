#!/usr/bin/env node
/**
 * Simulate what the swarm can actually attest, for free, before paying 0.5 IMD.
 *
 * Two layers:
 *  1. `problemsOf` from the plane's own check-answer.mjs — the formal rules every agent runs.
 *  2. A recipe/answerType compatibility check that check-answer.mjs does NOT make. The deployer
 *     reruns the recipe and signs only if it reproduces the answer, so a recipe whose output type
 *     cannot be the declared answerType can never be signed — even though the checker says "ok".
 *     That gap is what burned 1.0 IMD on the price question.
 *
 *   node simulate.mjs
 */
import { problemsOf } from "./check-answer.mjs";

// What each recipe kind actually yields, from REFERENCE.md.
const YIELDS = {
  "log-sum": ["uint256"],
  "log-rank": ["address[]", "bytes32[]"],
  "call-compare": ["bool"],
  "v4-volume-rank": ["bytes32[]", "address[]"],
  panel: ["bool", "address", "bytes32", "uint256", "address[]", "bytes32[]"], // nothing is rerun
};

const WINDOW = { fromBlock: 26085932, toBlock: 26093104, toBlockHash: "0x7118b37401a2a2a6301402b4ddb2abf255e04ce42e1eb4f5eac206a5b0f98571" };
const REQ = "0x7d1b59815736" + "0".repeat(52);

const brief = (answerType, evidence = "chain") => ({ requestId: REQ, chainId: 1, window: WINDOW, answerType, evidence });
const answer = (answerType, value, recipe, figure) => ({
  v: 1, requestId: REQ, chainId: 1, window: WINDOW, answerType,
  answer: value, ...(figure !== undefined ? { figure } : {}), recipe, notes: "simulated",
});

const CASES = [
  {
    name: "what we asked for: a price from slot0(), as uint256",
    brief: brief("uint256"),
    answer: answer("uint256", "1292410679962996",
      { kind: "call-compare", to: "0xd6a822d028bbf7b6edfa1533e110ee40c08551d9",
        function: "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 a, uint16 b, uint16 c, uint8 d, bool e)",
        args: [], op: "==", threshold: "2203836211050920052324214573504" }, "1292410679962996"),
  },
  {
    name: "the same price with no recipe that can express the arithmetic",
    brief: brief("uint256"),
    answer: answer("uint256", "1292410679962996", { kind: "arithmetic", expr: "1e18*2**192/s**2" }, "1292410679962996"),
  },
  {
    name: "a PRICE BOUND as bool: is sqrtPriceX96 >= X at the closing block",
    brief: brief("bool"),
    answer: answer("bool", true,
      { kind: "call-compare", to: "0xd6a822d028bbf7b6edfa1533e110ee40c08551d9",
        function: "function slot0() view returns (uint160 sqrtPriceX96, int24 tick, uint16 a, uint16 b, uint16 c, uint8 d, bool e)",
        args: [], op: ">=", threshold: "2203836211050920052324214573504" }),
  },
  {
    name: "IMD swap volume over the window as uint256 (log-sum)",
    brief: brief("uint256"),
    answer: answer("uint256", "123456789",
      { kind: "log-sum", address: "0xd6a822d028bbf7b6edfa1533e110ee40c08551d9",
        event: "event Swap(address indexed sender, address indexed recipient, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)",
        sumArg: "amount1", abs: true }, "123456789"),
  },
  {
    name: "IMD transfer volume over the window (log-sum on the token itself)",
    brief: brief("uint256"),
    answer: answer("uint256", "987654321",
      { kind: "log-sum", address: "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7",
        event: "event Transfer(address indexed from, address indexed to, uint256 value)",
        sumArg: "value", abs: false }, "987654321"),
  },
  {
    name: "NETWORK HEALTH: how many agents bound on chain in the window (a COUNT)",
    brief: brief("uint256"),
    // AgentBound(uint256 agentId, uint8 kind, address collection, uint256 tokenId, address owner).
    // The only numeric arguments are ids. Summing them is meaningless; the catalogue has no way
    // to say "count the matching events", so a population metric cannot be expressed at all.
    answer: answer("uint256", "92",
      { kind: "log-sum", address: "0xde152afb7db5373f34876e1499fbd893a82dd336",
        event: "event AgentBound(uint256 indexed agentId, uint8 indexed kind, address indexed collection, uint256 tokenId, address owner)",
        sumArg: "count", abs: false }, "92"),
  },
  {
    name: "NETWORK HEALTH, forced to sum tokenId because count is unavailable",
    brief: brief("uint256"),
    answer: answer("uint256", "177431",
      { kind: "log-sum", address: "0xde152afb7db5373f34876e1499fbd893a82dd336",
        event: "event AgentBound(uint256 indexed agentId, uint8 indexed kind, address indexed collection, uint256 tokenId, address owner)",
        sumArg: "tokenId", abs: false }, "177431"),
  },
  {
    name: "the price as a PANEL question (off-chain evidence, nothing rerun)",
    brief: brief("uint256", "panel"),
    answer: answer("uint256", "1292410679962996",
      { kind: "panel", source: "https://app.uniswap.org/explore/pools/ethereum/0xd6a822d028bbf7b6edfa1533e110ee40c08551d9" }, "1292410679962996"),
  },
];

let worst = 0;
for (const c of CASES) {
  const problems = problemsOf(c.answer, c.brief, Buffer.byteLength(JSON.stringify(c.answer)));
  const kind = c.answer.recipe?.kind;
  const yields = YIELDS[kind];
  const rerunnable = yields ? yields.includes(c.brief.answerType) : false;
  const verdict = problems.length ? "REFUSED by the checker" : rerunnable ? "OK" : "PASSES THE CHECKER BUT CANNOT BE SIGNED";
  if (verdict !== "OK") worst = 1;
  console.log(`\n${verdict}  —  ${c.name}`);
  console.log(`   recipe ${kind} yields ${yields ? yields.join("|") : "(not in the catalogue)"}, question wants ${c.brief.answerType}`);
  for (const p of problems) console.log(`   - ${p}`);
  if (!problems.length && !rerunnable) {
    console.log(`   - the deployer reruns this recipe and gets a ${yields?.join("|") ?? "?"}, which can never equal a ${c.brief.answerType} answer`);
  }
}
process.exit(worst);
