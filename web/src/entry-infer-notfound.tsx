import { softSite } from "./soft";
import { INFER_ROUTES, inferFrame } from "./infer/routes";
import { NotFound } from "./infer/NotFound";
import "./style.css";
import { initializeTheme } from "./theme";
import { startVibe } from "./vibe";
import { INFER_VIBES } from "./infer/vibes";
initializeTheme();
// The background starts before React renders, so this page's first paint carries it (vibe.tsx).
startVibe(INFER_VIBES);
softSite({ routed: false, mode: "keep", routes: INFER_ROUTES, initial: NotFound, frame: inferFrame });
