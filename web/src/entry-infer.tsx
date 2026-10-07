import { createRoot } from "react-dom/client";
import { App } from "./infer/App";
import "./style.css";
import { initializeTheme } from "./theme";
initializeTheme();
createRoot(document.getElementById("root")!).render(<App />);
