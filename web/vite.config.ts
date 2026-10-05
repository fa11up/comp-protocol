import { defineConfig, type Plugin } from "vite";
import { readFileSync, writeFileSync } from "node:fs";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";
// Three static pages: the landing page, the terminal and the docs. Plain files at /, /terminal/
// and /docs/, so the export needs no rewrite rules on whatever host serves imdusd.com.
// `vite build --mode public` is the site on imdusd.com: the homepage and docs only. The terminal is
// not built, every link to it is replaced (site.tsx TERMINAL), the install manifest opens the homepage,
// and Cloudflare Pages gets security headers and a redirect for any old /terminal link.
const PUBLIC_HEADERS = `/*
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()
  Strict-Transport-Security: max-age=31536000; includeSubDomains
/imd-deployment.json
  Cache-Control: no-cache
/abi/*
  Cache-Control: no-cache
/assets/*
  Cache-Control: public, max-age=31536000, immutable
`;
const PUBLIC_REDIRECTS = `/terminal / 302
/terminal/* / 302
`;
function publicSite(): Plugin {
  return {
    name: "imdusd-public-site",
    apply: "build",
    generateBundle() {
      this.emitFile({ type: "asset", fileName: "_headers", source: PUBLIC_HEADERS });
      this.emitFile({ type: "asset", fileName: "_redirects", source: PUBLIC_REDIRECTS });
    },
    writeBundle(options) {
      // public/manifest.webmanifest opens the terminal; this site has none, so open the homepage.
      const file = resolve(options.dir!, "manifest.webmanifest");
      const manifest = JSON.parse(readFileSync(file, "utf8"));
      manifest.start_url = "./";
      manifest.description =
        "imdUSD: a dollar-denominated stablecoin priced by IdentityMD swarm attestations.";
      writeFileSync(file, JSON.stringify(manifest, null, 2) + "\n");
    },
  };
}

export default defineConfig(({ mode }) => {
  const site = mode === "public";
  return {
  plugins: site ? [react(), publicSite()] : [react()],
  base: "./",
  // The points engine lives at ../points/engine.ts so the CLI and the terminal share one file.
  server: { fs: { allow: [".."] } },
  build: {
    outDir: site ? "../dist-public" : "../dist",
    emptyOutDir: true,
    sourcemap: false,
    rollupOptions: {
      input: {
        home: resolve(import.meta.dirname, "index.html"),
        ...(site
          ? {}
          : { terminal: resolve(import.meta.dirname, "terminal/index.html") }),
        docs: resolve(import.meta.dirname, "docs/index.html"),
      },
    },
  },
};
});
