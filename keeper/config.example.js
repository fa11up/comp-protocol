// Copy to config.js and fill in. config.js is gitignored and must NEVER be committed.
//
// NO PRIVATE KEYS IN THIS FILE. The watcher is read-only. The relay and liquidation loops take their
// key from the environment at run time, so a config file that leaks reveals addresses and bands, not
// custody.
export default {
  // --- read-only ---
  MAINNET_RPC_URL: process.env.MAINNET_RPC_URL || "https://ethereum-rpc.publicnode.com",
  VAULT_RPC_URL: process.env.VAULT_RPC_URL || "https://ethereum-sepolia-rpc.publicnode.com",

  // The deeper of the two live IMD pools. The v3 WETH pool is drained — liquidity() is 0 — so
  // anything priced from it is a frozen leftover.
  POOL: {
    poolManager: "0x000000000004444c5dc75cb358380d2e3de08a90",
    poolId: "0xb07d640fd9e2eb9dc81b953c8e4fd006bdfeaf276010fb5418eb763ca15abfb3",
    // false yields wei of native ETH per 1e18 raw IMD, which is the direction every feed quotes.
    // Inverting gives ~3.1e20 and is the classic misreading: it looks like a market move.
    invert: false,
  },

  // The feeds to watch. `role` is only for the log; `payload` is the oracle request to buy when this
  // feed needs an update, and must be the payload whose question the feed actually pins.
  FEEDS: [
    { role: "price", address: "0xC677A113e06d70a313FfB459B291ec4bEcF5AB18", payload: "whitepaper/requests/price-univ4-v3-quote.json" },
    { role: "spot",  address: "0x0535C1A564B2594676239428A113d542cd6c2Ed9", payload: "whitepaper/requests/spot-univ4-quote.json" },
  ],

  // --- the vault the liquidator watches ---
  VAULT: "0xD8CbC70B9C2dfC75762686dd4795e2aC033452c5",
  // Positions live in a mapping with no on-chain enumeration, so events are the only index there is —
  // and a public RPC is an unsound source for them. Measured on 2026-10-04 against this vault: a
  // 50,000-block span found the one real depositor while a 40,669-block span INSIDE the same range
  // found nothing, neither erroring. The node also caps ranges at 50,000 and is not an archive node.
  // Blockscout returns the whole decoded history, paginated and deterministic.
  INDEXER: "https://eth-sepolia.blockscout.com",

  // --- the trigger band, which is the whole point ---
  //
  // Fire on MOVEMENT, not on a clock. A feed absorbs at most `maxDeviationBps` per update, so the
  // trigger must be strictly narrower or the feed is eventually asked to make a jump it cannot take.
  // Expressed as a fraction of each feed's own on-chain cap, read at run time rather than duplicated
  // here: half the cap leaves room for the market to keep moving while a request is in flight.
  TRIGGER_FRACTION_OF_CAP: 0.5,

  // Also fire when a feed is this close to going stale, because a stale feed halts the vault and the
  // first value accepted afterwards re-anchors the band with no deviation bound at all.
  STALENESS_MARGIN_SECONDS: 3 * 3600,

  // Refuse to fire more often than this however much the price moves, so a violent market cannot
  // drain the IMD budget in an hour. Each request costs 0.5 IMD.
  MIN_SECONDS_BETWEEN_REQUESTS: 1800,
};
