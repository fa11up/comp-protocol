import { createRoot } from "react-dom/client";
import { Landing } from "./Landing";
import "./style.css";
import { initializeTheme } from "./theme";
initializeTheme();
createRoot(document.getElementById("root")!).render(<Landing />);
