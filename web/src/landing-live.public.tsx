// The public build's stand-in for landing-live.tsx (aliased in vite.config.ts): imdusd.com reads no
// chain, so the live homepage and everything it imports stay out of the bundle.
export function LiveLanding() {
  return null;
}
