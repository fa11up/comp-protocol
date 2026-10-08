// llms.txt for infer.imdusd.com (https://llmstxt.org): INFER for a language model, built from the
// same launch file as the pages. Before launch the public build ships launch.example.json, so every
// figure and address the launch sets is written —, exactly as the pages show it; nothing private
// reaches this file that the pages would not also show.
import { encodeAbiParameters, keccak256 } from "viem";

const SITE = "https://infer.imdusd.com";
const dash = "—";
const pct = (bps) => (bps === null || bps === undefined ? dash : `${(bps / 100).toLocaleString("en-US")}%`);
const val = (v, unit = "") => (v === null || v === undefined || v === "" ? dash : `${v}${unit}`);
const whole = (wei) => {
  if (wei === null || wei === undefined) return dash;
  const n = BigInt(wei) / 10n ** 18n;
  return `${n.toLocaleString("en-US")}`;
};
const addr = (a) => (a ? `\`${a}\`` : "published at launch");

const poolId = (key) =>
  keccak256(
    encodeAbiParameters(
      [
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
      ],
      [key],
    ),
  );

export function inferLlms(L) {
  const c = L.contracts;
  const live = c.infer !== null;
  const share = (key) => L.allocation.find((a) => a.key === key)?.bps ?? null;
  const key = L.poolKey;
  const pair = L.pair;
  const seasons = L.seasons;
  const founder = L.founder;
  const amounts = seasons.amounts.map((a, i) => `season ${i + 1}: ${a === null ? dash : `${whole(a)} INFER`}`).join("; ");

  return `# INFER

> INFER (Inference-Backed Endogenous Financial Reserve) is the token of the imdUSD protocol, on Ethereum mainnet. Fixed supply, minted once by IdentityMD's launch factory, with no owner, no further minting and no tax. It trades against ${pair} in a Uniswap v4 launch pool whose liquidity is held for good, is claimed in seasons against points for holding imdUSD, is redeemable for the community's legacy tokens (MIYA and MXXN), and stakes as sINFER for a share of what the protocol earns.

${
  live
    ? `Status: launched on Ethereum mainnet (chain id ${L.chainId}). The addresses below are the launch's; check each on chain before you send anything.`
    : `Status: not launched yet. Contract addresses and launch figures are published at launch on ${SITE}; until then this file, like the site, writes each one as ${dash}.`
}

- [Trade and stake](${SITE}/): buy and sell INFER on the launch pool, stake it for sINFER, and see your position
- [Buy](${SITE}/buy/): INFER's live price and market cap, and where to buy it
- [Claim](${SITE}/claim/): claim season points for holding imdUSD, and redeem MIYA or MXXN for INFER
- [Tokenomics](${SITE}/tokenomics/): the fixed supply and where every part of it goes
- [imdUSD](https://imdusd.com/llms.txt): the stablecoin protocol INFER belongs to

## Contracts

Ethereum mainnet, chain id ${L.chainId}. Every INFER bucket is a contract whose share is a constant in its verified source, paid in the launch transaction by a permissionless split.

| Contract | Address | What it does |
|---|---|---|
| INFER | ${addr(c.infer)} | The ERC-20 token. Fixed supply, no owner, no mint, no tax. |
| SeasonVault | ${addr(c.seasonVault)} | Holds the points-season pots; pays claims against each season's Merkle root, vesting over the following season. |
| LegacyRedeemer | ${addr(c.legacyRedeemer)} | Burns MIYA or MXXN for INFER at fixed rates, for one year from launch. |
| sINFER (StakedInfer) | ${addr(c.stakedInfer)} | The staking vault: deposit INFER for sINFER shares, redeem shares for INFER. |
| Dripper | ${addr(c.dripper)} | Releases the INFER the Treasury buys into sINFER over about a week. |
| FounderStream | ${addr(c.founderStream)} | The founder allocation, streamed linearly after a cliff. |
| ${pair} (the pair token) | ${addr(c.pair)} | The other side of the launch pool. |
| Uniswap v4 PoolManager | ${addr(c.poolManager)} | Holds the launch pool. |
| Uniswap Universal Router | ${addr(L.router.universalRouter)} | Executes swaps. |
| Uniswap V4 Quoter | ${addr(L.router.quoter)} | Quotes swaps (read with eth_call). |
| Permit2 | ${addr(L.router.permit2)} | The allowance contract the router spends through. |

Launch pool key: ${
    key
      ? `currency0 \`${key.currency0}\`, currency1 \`${key.currency1}\`, fee ${key.fee}, tickSpacing ${key.tickSpacing}, hooks \`${key.hooks}\`; pool id \`${poolId(key)}\` (keccak256 of the ABI-encoded key).`
      : `published at launch. The pool id is keccak256 of the ABI-encoded key (currency0, currency1, fee, tickSpacing, hooks).`
  }

## Tokenomics

- Supply: ${L.supply === null ? dash : `${whole(L.supply)} INFER`}, fixed.
- The launch: a custom-token launch on Ethereum mainnet by the IdentityMD swarm, which writes, reviews and deploys the contracts. The factory keeps a fixed share for the agents that build it, seeds the ${pair}/INFER pool on one side from the opening price upward and holds that liquidity for good, and sends the rest to the splitter that pays the buckets. The opening market cap (${L.openingMarketCapImd === null ? dash : `${whole(L.openingMarketCapImd)} ${pair}`}) is therefore also the pool's floor.

| Bucket | Share of supply | Notes |
|---|---|---|
${L.allocation.map((a) => `| ${a.label} | ${pct(a.bps)} | ${a.note} |`).join("\n")}

- Seasons: ${seasons.count} seasons of ${seasons.weeks} weeks, front-loaded: each pot is about ${val(seasons.decay, "×")} the one before, because the earliest depositors take the most risk (${amounts}). ${seasons.pointsRule} A season's Merkle root is set only after a swarm panel attests the published points file. A claim vests over the following season (${seasons.vestWeeks} weeks), so staying keeps earning while last season's claim pays out. Unclaimed INFER rolls into the next season; after the last, to the Treasury.
- Legacy redemptions: holders of the community's earlier tokens burn them for INFER at rates fixed from the redeemable supply on launch day, so neither allocation can be over-claimed. ${L.redemptions.map((r) => `${r.symbol} (${addr(r.token)}): ${val(r.rate)} INFER per ${r.symbol}, ${r.window}, allocation ${r.allocation === null ? dash : `${r.allocation} INFER`}.`).join(" ")} What is left after a year goes to the Treasury.
- Founder: a stream, not a grant: linear to miyagod.eth over ${val(founder.months, " months")} with a ${val(founder.cliffDays, "-day")} cliff, ${founder.amount === null ? dash : `${whole(founder.amount)} INFER`} in all. Nothing on day one.
- Treasury: the reserve is spent only by governance, every change public for 48 hours first. It also receives ${pct(L.fees.treasuryBps)} of the launch pool's trading fees, in ${pair} and INFER. That revenue funds the imdUSD oracle and buys the INFER that is dripped into sINFER: no emission, only what the protocol earns. Staked INFER also earns a points multiplier in the seasons.

## How to use them

Every action is a plain transaction from your own wallet; the site only reads the chain, quotes, and prepares calls. Simulate before sending.

### Buy or sell INFER (Uniswap v4)

1. Quote: \`V4Quoter.quoteExactInputSingle(((currency0, currency1, fee, tickSpacing, hooks) poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData))\` with eth_call; it returns \`(uint256 amountOut, uint256 gasEstimate)\`. \`zeroForOne\` is true when you pay currency0 (the lower address).
2. Allow Permit2: \`token.approve(Permit2, amount)\` on the token you pay, then \`Permit2.approve(token, UniversalRouter, uint160 amount, uint48 expiration)\`. Check \`Permit2.allowance(you, token, UniversalRouter)\` first; the site sets a 30-day expiration.
3. Swap: \`UniversalRouter.execute(bytes commands, bytes[] inputs, uint256 deadline)\` with one command, V4_SWAP (\`0x10\`). Its input is \`abi.encode(bytes actions, bytes[] params)\`, actions \`0x060c0f\`: SWAP_EXACT_IN_SINGLE (\`0x06\`) with \`(poolKey, zeroForOne, uint128 amountIn, uint128 amountOutMinimum, bytes hookData)\`, SETTLE_ALL (\`0x0c\`) with \`(currencyIn, amountIn)\`, TAKE_ALL (\`0x0f\`) with \`(currencyOut, amountOutMinimum)\`. Set \`amountOutMinimum\` to the quote less your slippage (the site defaults to ${pct(L.slippageBps)}) and a short deadline (the site uses 20 minutes).

### Claim season points

Seasons are numbered from 0 in the contract (the site shows season 1 for \`s = 0\`).

1. Read \`SeasonVault.season(s)\`: a zero \`root\` means the season is not open yet. \`potOf(s)\`, \`endOf(s)\` and \`deadlineOf(s)\` give its pot, end and claim deadline.
2. Fetch the season's claim file, published with the root: JSON \`{ season, root, total, claims: { "<lowercase address>": { amount, proof } } }\`.
3. \`SeasonVault.claim(uint256 s, address account, uint256 amount, bytes32[] proof)\` registers the entitlement for that account from its leaf in the claim file.
4. \`releasable(s, account)\` is what has vested; \`release(uint256 s, address account)\` pays it. \`entitlements(s, account)\` returns \`(amount, paid)\`.

### Redeem MIYA or MXXN

1. \`legacyToken.approve(LegacyRedeemer, amount)\`.
2. \`LegacyRedeemer.redeem(address legacy, uint256 amount)\` burns it and pays INFER at once: amount × the fixed rate. \`legacyA()\` and \`legacyB()\` are MIYA and MXXN, \`rateA()\`/\`rateB()\` their rates, \`allocationA()\`/\`allocationB()\` their allocations and \`redeemed(legacy)\` how much of each is already paid (the difference is what is left), and \`closesAt()\` when redemption ends. MXXN redeems only inside its full-moon transfer windows.

### Stake for sINFER

1. \`INFER.approve(sINFER, amount)\`, then \`sINFER.deposit(uint256 assets, address receiver)\` for shares.
2. \`sINFER.redeem(uint256 shares, address receiver, address owner)\` returns INFER; \`maxRedeem(owner)\` is the most you can redeem now, \`convertToAssets(shares)\` what shares are worth.
3. The Treasury buys INFER with protocol revenue and the Dripper releases it into the vault over about a week (\`Dripper.releasable()\`, \`lastDripAt()\`), so each sINFER is worth more INFER over time. There is no emission.

## Risks

- INFER's price is set by trading in the launch pool. It can fall back toward the opening price, and you can lose what you paid.
- Staking yield is only what the protocol earns; it can be zero.
- Season pots depend on a points file the swarm publishes and a panel attests; check your entry in the claim file before you rely on it.
- Always check a contract address on chain, and against this site, before approving a token to it.
`;
}
