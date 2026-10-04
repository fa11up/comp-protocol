import { useSyncExternalStore } from "react";

type Theme = "light" | "dark";
const key = "comp-terminal-theme";
const system = window.matchMedia("(prefers-color-scheme: dark)");
let choice: Theme | null = null;
try {
  const saved = localStorage.getItem(key);
  if (saved === "light" || saved === "dark") choice = saved;
} catch {
  /* Storage may be disabled; the toggle still works for this visit. */
}
let current: Theme;
const listeners = new Set<() => void>();
function apply() {
  document.documentElement.classList.add("theme-changing");
  current = choice ?? (system.matches ? "dark" : "light");
  document.documentElement.dataset.theme = current;
  const style = getComputedStyle(document.documentElement);
  // Both media-scoped tags take the active theme's ground, so an explicit choice beats the OS.
  document
    .querySelectorAll('meta[name="theme-color"]')
    .forEach((m) =>
      m.setAttribute("content", style.getPropertyValue("--bg").trim()),
    );
  // The favicon follows an explicit choice too, not just the OS preference.
  const icon = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" fill="${style.getPropertyValue("--bg").trim()}"/><path d="M23 9H9v14h14M18 16h8" fill="none" stroke="${style.getPropertyValue("--text").trim()}" stroke-width="2"/></svg>`;
  document
    .querySelector('link[rel="icon"]')
    ?.setAttribute("href", `data:image/svg+xml,${encodeURIComponent(icon)}`);
  void document.documentElement.offsetHeight;
  requestAnimationFrame(() =>
    document.documentElement.classList.remove("theme-changing"),
  );
  listeners.forEach((fn) => fn());
}
system.addEventListener("change", () => {
  if (!choice) apply();
});
window.addEventListener("storage", (event) => {
  if (event.key === key) {
    choice =
      event.newValue === "light" || event.newValue === "dark"
        ? event.newValue
        : null;
    apply();
  }
});
export function initializeTheme() {
  apply();
}
export function ThemeToggle() {
  const theme = useSyncExternalStore(
    (fn) => {
      listeners.add(fn);
      return () => {
        listeners.delete(fn);
      };
    },
    () => current,
  );
  const next = theme === "dark" ? "light" : "dark";
  return (
    <button
      type="button"
      className="theme-toggle"
      aria-label={`Use ${next} theme`}
      title={`Use ${next} theme`}
      onClick={() => {
        choice = next;
        try {
          localStorage.setItem(key, choice);
        } catch {
          /* Optional persistence. */
        }
        apply();
      }}
    >
      {/* The icon names the theme a click switches to, as on imd.fun. */}
      <svg
        viewBox="0 0 20 20"
        width="20"
        height="20"
        aria-hidden="true"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        {next === "dark" ? (
          <path d="M15.5 12.5A6.5 6.5 0 0 1 7.5 4.5a6.5 6.5 0 1 0 8 8z" />
        ) : (
          <>
            <circle cx="10" cy="10" r="3.25" />
            <path d="M10 2.5v1.75M10 15.75v1.75M2.5 10h1.75M15.75 10h1.75M4.7 4.7l1.24 1.24M14.06 14.06l1.24 1.24M4.7 15.3l1.24-1.24M14.06 5.94l1.24-1.24" />
          </>
        )}
      </svg>
    </button>
  );
}
