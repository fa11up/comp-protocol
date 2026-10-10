import { useEffect, useState } from "react";

/**
 * The disconnect control, both sites' header: a box with an ×, and nothing else. It exists only while a
 * wallet is connected, and is drawn the way the engravings are: on connect a slot opens at the end of the
 * header, a pen traces the frame clockwise from the top-left, then the × in two strokes. On disconnect it
 * runs backwards, the × lifting, the frame unwinding, and the slot closing so nothing takes its place.
 * With reduced motion it simply appears and goes. Connecting is the amount boxes' "Disconnected" label.
 *
 * Drawn once per document: a page switch (soft.tsx) mounts a new header, and a box that was already on screen
 * appears there fully drawn ("shown") instead of drawing itself again. It draws again only after it has gone.
 */
let onScreen = false;

export function DisconnectBox({
  connected,
  label,
  onDisconnect,
}: {
  connected: boolean;
  /** Accessible name and tooltip, e.g. "Disconnect 0x12…". */
  label: string;
  onDisconnect: () => void;
}) {
  const [phase, setPhase] = useState<"gone" | "in" | "shown" | "out">(() =>
    connected ? (onScreen ? "shown" : "in") : "gone",
  );
  useEffect(() => {
    if (connected) {
      setPhase((p) => (p === "in" || p === "shown" ? p : onScreen ? "shown" : "in"));
      onScreen = true;
      return;
    }
    onScreen = false; // leaving: the next connect draws it, whether or not the unwind finishes here
    let still = false;
    try {
      still = matchMedia("(prefers-reduced-motion: reduce)").matches;
    } catch {}
    // Without motion no animation ends, so the box goes at once.
    setPhase((p) => (p === "gone" || still ? "gone" : "out"));
  }, [connected]);
  if (phase === "gone") return null;
  return (
    <span
      className={`disconnect-slot is-${phase}`}
      onAnimationEnd={(e) => {
        if (phase === "out" && e.target === e.currentTarget) setPhase("gone");
      }}
    >
      <button
        type="button"
        className="disconnect-box"
        aria-label={label}
        title={label}
        disabled={phase === "out"}
        onClick={onDisconnect}
      >
        <svg viewBox="0 0 36 36" aria-hidden="true" focusable="false">
          <rect className="db-frame" x="0.5" y="0.5" width="35" height="35" pathLength={100} />
          <g className="db-x">
            <path className="db-x1" d="M13 13 L23 23" pathLength={100} />
            <path className="db-x2" d="M23 13 L13 23" pathLength={100} />
          </g>
        </svg>
      </button>
    </span>
  );
}
