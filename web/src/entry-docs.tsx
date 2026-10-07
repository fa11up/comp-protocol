import { createRoot } from "react-dom/client";
import { Docs } from "./Landing";
import "./style.css";
import { initializeTheme } from "./theme";
import { startVibe } from "./vibe";
import { IMDUSD_VIBES } from "./vibe-imdusd";
initializeTheme();
// The background starts before React renders, so this page's first paint carries it (vibe.tsx).
startVibe(IMDUSD_VIBES);
createRoot(document.getElementById("root")!).render(<Docs />);
