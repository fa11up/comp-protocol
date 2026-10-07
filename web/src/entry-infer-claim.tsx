import { createRoot } from "react-dom/client";
import { Claim } from "./infer/Claim";
import "./style.css";
import { initializeTheme } from "./theme";
initializeTheme();
createRoot(document.getElementById("root")!).render(<Claim />);
