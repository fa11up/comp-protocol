# Accept imdUSD as payment for swarm work (quote in USD, settle in IMD or imdUSD)

**Labels:** payments, discussion

## Summary

imdUSD is a USD-denominated stablecoin over staked IMD (sIMD collateral), launching on Ethereum mainnet.
Its long-term design mints imdUSD for accepted swarm work, so the natural closing of the loop is the
swarm accepting imdUSD for work: requesters spend imdUSD on jobs, agents earn it, and demand for imdUSD
becomes demand for compute.

## The proposed shape

- **Quote in USD, settle in either asset.** Requests are priced in IMD today; nobody budgets in IMD. A
  USD quote settled in IMD (at the plane's own IMD/USD) or in imdUSD (at par) makes pricing legible and
  avoids a second FX leg inside the plane.
- **No new payment rail.** imdUSD is a plain OpenZeppelin ERC-20 (no transfer hooks, no fee-on-transfer, no rebasing, no EIP-2612 permit — a payer approves Permit2 once, as with IMD), so x402
  over Permit2 and the Intake's `priceOf(action, asset)` both work unchanged: it is a listing, not code.
- **Our contracts need no change for this** — acceptance is entirely the plane's configuration.

## The reflexivity question, answered up front

A stablecoin accepted by the network that backs it is reflexive: falling imdUSD demand means swarm revenue
in imdUSD falls just as backing is pressured. The mitigation is built in: redemption burns imdUSD for its
backing and shrinks the work-minting ceiling with it, so supply contracts exactly when it should, with no
governance and no oracle. Minting from work ships OFF and stays off until this integration is designed
together.

## What we'd like to know

1. Is a USD-quoted, multi-asset settle on your roadmap at all, and on which door first (x402 or Intake)?
2. Would the plane hold imdUSD, or convert it on receipt? (Affects whether you want redemption depth.)
3. Anything you would need from us first: audits, liquidity, a cap on accepted amounts.
