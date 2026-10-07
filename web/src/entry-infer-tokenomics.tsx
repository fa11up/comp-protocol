import { createRoot } from "react-dom/client";
import { Tokenomics } from "./infer/Tokenomics";
import "./style.css";
import { initializeTheme } from "./theme";
initializeTheme();
createRoot(document.getElementById("root")!).render(<Tokenomics />);
