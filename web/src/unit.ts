// The stablecoin's unit as the deployed token names it: imdUSD on mainnet, COMP on the Sepolia stack
// deployed before the rename. Read once per snapshot from symbol(); labels call unit() as they render.
let symbol = "imdUSD";
export const unit = () => symbol;
export function setUnit(s: unknown) {
  if (typeof s === "string" && /^[A-Za-z0-9._-]{1,16}$/.test(s)) symbol = s;
}
