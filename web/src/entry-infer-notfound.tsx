import { createRoot } from "react-dom/client";
import { NotFound } from "./infer/NotFound";
import "./style.css";
import { initializeTheme } from "./theme";
initializeTheme();
createRoot(document.getElementById("root")!).render(<NotFound />);
