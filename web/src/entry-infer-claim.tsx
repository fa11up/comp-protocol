import { createRoot } from "react-dom/client";
import { Claim } from "./infer/Claim";
import "./style.css";
import { initializeTheme } from "./theme";
import { startVibe } from "./vibe";
import { INFER_VIBES } from "./infer/vibes";
initializeTheme();
// The background starts before React renders, so this page's first paint carries it (vibe.tsx).
startVibe(INFER_VIBES);
createRoot(document.getElementById("root")!).render(<Claim />);
