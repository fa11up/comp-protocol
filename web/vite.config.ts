import { defineConfig, type Plugin } from "vite";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
// @ts-expect-error plain ESM build script without types
import { renderDocs } from "./scripts/docs-pages.mjs";
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
      // The public homepage reads no chain, so the testnet deployment's ABIs are not shipped.
      rmSync(resolve(options.dir!, "abi"), { recursive: true, force: true });
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

/** Static docs pages from web/content/docs, written beside the built docs shell. */
function docsPages(terminal: boolean): Plugin {
  return {
    name: "imdusd-docs-pages",
    apply: "build",
    writeBundle(options) {
      const count = renderDocs({
        outDir: options.dir!,
        contentDir: resolve(import.meta.dirname, "content/docs"),
        terminal,
      });
      this.info(`rendered ${count} docs pages`);
    },
  };
}

export default defineConfig(({ mode }) => {
  const site = mode === "public";
  return {
  plugins: site
    ? [react(), publicSite(), docsPages(false)]
    : [react(), docsPages(true)],
  // The public site reads no chain: swap the live homepage for a stub so viem and the RPC layer
  // are not bundled at all.
  resolve: site
    ? {
        alias: [
          {
            find: /^\.\/landing-live$/,
            replacement: resolve(import.meta.dirname, "src/landing-live.public.tsx"),
          },
        ],
      }
    : {},
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
