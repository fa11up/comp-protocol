import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";
// Three static pages: the landing page, the terminal and the docs. Plain files at /, /terminal/
// and /docs/, so the export needs no rewrite rules on whatever host serves imdusd.com.
export default defineConfig({
  plugins: [react()],
  base: "./",
  // The points engine lives at ../points/engine.ts so the CLI and the terminal share one file.
  server: { fs: { allow: [".."] } },
  build: {
    outDir: "../dist",
    emptyOutDir: true,
    sourcemap: false,
    rollupOptions: {
      input: {
        home: resolve(import.meta.dirname, "index.html"),
        terminal: resolve(import.meta.dirname, "terminal/index.html"),
        docs: resolve(import.meta.dirname, "docs/index.html"),
      },
    },
  },
});
