import { defineConfig, type Plugin, type UserConfig } from "vite";
import {
  existsSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
// @ts-expect-error plain ESM build script without types
import { renderDocs, socialTags } from "./scripts/docs-pages.mjs";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";
// Three static pages: the landing page, the terminal and the docs. Plain files at /, /terminal/
// and /docs/, so the export needs no rewrite rules on whatever host serves imdusd.com.
// `vite build --mode public` is the site on imdusd.com: the homepage and docs only. The terminal is
// not built, every link to it is replaced (site.tsx TERMINAL), the install manifest opens the homepage,
// and Cloudflare gets security headers, a not-found page and a redirect for any old /terminal link.
const SITE = "https://imdusd.com";
const PUBLIC_REDIRECTS = `/terminal / 302
/terminal/* / 302
`;
const ROBOTS = `User-agent: *
Allow: /

Sitemap: ${SITE}/sitemap.xml
`;
/**
 * The headers Cloudflare serves with every public response. The Content-Security-Policy is built
 * after the export is written: the one inline script (the theme bootstrap in each page's <head>) is
 * allowed by its hash, so any other inline script, every inline style, and every connection to a
 * chain or a third party is refused by the browser. `connect-src 'none'` is also the public site's
 * promise (scripts/public-check.mjs): it reads no chain.
 */
const publicHeaders = (scriptHashes: string[], connect: string[] = []) => `/*
  Content-Security-Policy: default-src 'none'; script-src 'self' ${scriptHashes.map((h) => `'sha256-${h}'`).join(" ")}; style-src 'self'; img-src 'self' data:; font-src 'self'; manifest-src 'self'; connect-src ${connect.length ? connect.join(" ") : "'none'"}; frame-ancestors 'none'; base-uri 'self'; form-action 'none'; object-src 'none'; upgrade-insecure-requests
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()
  Strict-Transport-Security: max-age=31536000; includeSubDomains
/assets/*
  Cache-Control: public, max-age=31536000, immutable
`;

const walk = (dir: string): string[] =>
  readdirSync(dir).flatMap((n) => {
    const p = resolve(dir, n);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });

function publicSite(): Plugin {
  return {
    name: "imdusd-public-site",
    apply: "build",
    generateBundle() {
      this.emitFile({
        type: "asset",
        fileName: "_redirects",
        source: PUBLIC_REDIRECTS,
      });
      this.emitFile({ type: "asset", fileName: "robots.txt", source: ROBOTS });
    },
    writeBundle(options) {
      const dir = options.dir!;
      // The public homepage reads no chain, so the testnet deployment's ABIs are not shipped.
      rmSync(resolve(dir, "abi"), { recursive: true, force: true });
      // public/manifest.webmanifest describes the terminal; this site has none, so it is the site.
      const file = resolve(dir, "manifest.webmanifest");
      const manifest = JSON.parse(readFileSync(file, "utf8"));
      manifest.name = "imdUSD";
      manifest.start_url = "./";
      manifest.description =
        "imdUSD: a dollar-denominated stablecoin priced by IdentityMD swarm attestations.";
      writeFileSync(file, JSON.stringify(manifest, null, 2) + "\n");
      // The homepage's canonical URL and social card.
      const home = resolve(dir, "index.html");
      const html = readFileSync(home, "utf8");
      const description =
        html.match(/<meta\s+name="description"\s+content="([^"]*)"/)?.[1] ?? "";
      writeFileSync(
        home,
        html.replace(
          "</head>",
          `${socialTags(SITE, `${SITE}/`, "imdUSD", description, { type: "website" })}</head>`,
        ),
      );
      // The not-found page is served at whatever path was asked for, so its URLs must be absolute.
      const notFound = resolve(dir, "404.html");
      writeFileSync(
        notFound,
        readFileSync(notFound, "utf8").replace(/(["'(])\.\//g, "$1/"),
      );
    },
    // After every plugin has written (the docs pages included), hash each page's inline script and
    // write the headers. One theme bootstrap means one hash; a page that smuggled in another inline
    // script would add a second, which is the point of computing rather than pinning it.
    closeBundle() {
      const dir = resolve(import.meta.dirname, "../dist-public");
      const hashes = new Set<string>();
      for (const file of walk(dir).filter((f) => f.endsWith(".html"))) {
        for (const [, script] of readFileSync(file, "utf8").matchAll(
          /<script>([\s\S]*?)<\/script>/g,
        ))
          hashes.add(createHash("sha256").update(script).digest("base64"));
      }
      if (hashes.size !== 1)
        throw new Error(
          `expected one inline script across the public pages, found ${hashes.size}`,
        );
      writeFileSync(resolve(dir, "_headers"), publicHeaders([...hashes]));
    },
  };
}

/**
 * infer.imdusd.com (`vite build --mode infer`, root web/infer): the INFER token page, its own export
 * in dist-infer/. Unlike the public site it talks to a chain, so its Content-Security-Policy admits
 * exactly the RPC and claim-file origins the page's launch file names, and nothing else.
 */
const INFER_SITE = "https://infer.imdusd.com";
/**
 * /buy/ is an X player card: a post that links it shows the page itself, live, in a 480 × 560 frame,
 * with `buy-card.png` (src/infer, rendered from the page by scripts/render-infer-card.mjs) as the still
 * before play. The Worker admits x.com as a frame ancestor on this route only (worker/infer.js).
 */
const PLAYER = { width: 480, height: 560, image: "buy/card.png" };
function playerTags(url: string, title: string, description: string) {
  const image = `${INFER_SITE}/${PLAYER.image}`;
  return (
    `<link rel="canonical" href="${url}" />` +
    `<meta property="og:type" content="website" />` +
    `<meta property="og:site_name" content="imdUSD" />` +
    `<meta property="og:url" content="${url}" />` +
    `<meta property="og:title" content="${title}" />` +
    `<meta property="og:description" content="${description}" />` +
    `<meta property="og:image" content="${image}" />` +
    `<meta property="og:image:width" content="${PLAYER.width * 2}" />` +
    `<meta property="og:image:height" content="${PLAYER.height * 2}" />` +
    `<meta name="twitter:card" content="player" />` +
    `<meta name="twitter:title" content="${title}" />` +
    `<meta name="twitter:description" content="${description}" />` +
    `<meta name="twitter:image" content="${image}" />` +
    `<meta name="twitter:player" content="${url}" />` +
    `<meta name="twitter:player:width" content="${PLAYER.width}" />` +
    `<meta name="twitter:player:height" content="${PLAYER.height}" />`
  );
}
function inferSite(): Plugin {
  // The export directory, taken from the build rather than assumed, so `--outDir` works (a QA
  // build against a fork lives beside the real one without touching it).
  let dir = resolve(import.meta.dirname, "../dist-infer");
  const launchDir = resolve(import.meta.dirname, "src/infer");
  const launch = JSON.parse(
    readFileSync(
      resolve(
        launchDir,
        existsSync(resolve(launchDir, "launch.json"))
          ? "launch.json"
          : "launch.example.json",
      ),
      "utf8",
    ),
  ) as { rpc: string[]; claims: { origins: string[] } };
  return {
    name: "imdusd-infer-site",
    apply: "build",
    generateBundle() {
      this.emitFile({
        type: "asset",
        fileName: "robots.txt",
        source: `User-agent: *\nAllow: /\n\nSitemap: ${INFER_SITE}/sitemap.xml\n`,
      });
      this.emitFile({
        type: "asset",
        fileName: PLAYER.image,
        source: readFileSync(resolve(launchDir, "buy-card.png")),
      });
      this.emitFile({
        type: "asset",
        fileName: "sitemap.xml",
        source:
          `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n` +
          ["", "claim/", "tokenomics/"]
            .map((p) => `  <url><loc>${INFER_SITE}/${p}</loc></url>`)
            .join("\n") +
          `\n</urlset>\n`,
      });
    },
    writeBundle(options) {
      dir = options.dir ?? dir;
      // The not-found page is served at whatever path was asked for, so its URLs must be absolute.
      const notFound = resolve(dir, "404.html");
      writeFileSync(
        notFound,
        readFileSync(notFound, "utf8").replace(/(["'(])\.\.?\//g, "$1/"),
      );
      rmSync(resolve(dir, "abi"), { recursive: true, force: true });
      const file = resolve(dir, "manifest.webmanifest");
      const manifest = JSON.parse(readFileSync(file, "utf8"));
      manifest.name = "INFER";
      manifest.short_name = "INFER";
      manifest.start_url = "./";
      manifest.description =
        "INFER, the imdUSD protocol's token: claim, swap, stake and the tokenomics.";
      writeFileSync(file, JSON.stringify(manifest, null, 2) + "\n");
      for (const page of ["", "claim/", "tokenomics/", "buy/"]) {
        const file = resolve(dir, page, "index.html");
        const html = readFileSync(file, "utf8");
        const title = html.match(/<title>([^<]*)<\/title>/)?.[1] ?? "INFER";
        const description =
          html.match(/<meta\s+name="description"\s+content="([^"]*)"/)?.[1] ??
          "";
        writeFileSync(
          file,
          html.replace(
            "</head>",
            `${page === "buy/" ? playerTags(`${INFER_SITE}/${page}`, title, description) : socialTags(INFER_SITE, `${INFER_SITE}/${page}`, title, description, { type: "website" })}</head>`,
          ),
        );
      }
    },
    closeBundle() {
      const hashes = new Set<string>();
      for (const file of walk(dir).filter((f) => f.endsWith(".html"))) {
        for (const [, script] of readFileSync(file, "utf8").matchAll(
          /<script>([\s\S]*?)<\/script>/g,
        ))
          hashes.add(createHash("sha256").update(script).digest("base64"));
      }
      if (hashes.size !== 1)
        throw new Error(
          `expected one inline script on the INFER page, found ${hashes.size}`,
        );
      const origins = [
        ...new Set(
          [...launch.rpc, ...launch.claims.origins].map(
            (u) => new URL(u).origin,
          ),
        ),
      ];
      writeFileSync(
        resolve(dir, "_headers"),
        publicHeaders([...hashes], ["'self'", ...origins]),
      );
    },
  };
}

/** Static docs pages from web/content/docs, written beside the built docs shell. */
/**
 * Holds each page's first paint until its script has run, so the background (vibe.tsx, started as the
 * script loads) is in that paint: with the browser holding the old page until then, a link to another
 * page changes the page and not the background. Vite rewrites the entry tag, so it is added here.
 */
function renderBlocking(): Plugin {
  return {
    name: "imdusd-render-blocking",
    transformIndexHtml: {
      order: "post",
      handler: (html) =>
        html.replace(
          /<script type="module" crossorigin/g,
          '<script type="module" crossorigin blocking="render"',
        ),
    },
  };
}

function docsPages(terminal: boolean): Plugin {
  return {
    name: "imdusd-docs-pages",
    apply: "build",
    writeBundle(options) {
      const count = renderDocs({
        outDir: options.dir!,
        contentDir: resolve(import.meta.dirname, "content/docs"),
        terminal,
        site: terminal ? undefined : SITE,
      });
      this.info(`rendered ${count} docs pages`);
    },
  };
}

export default defineConfig(({ mode }) => {
  const site = mode === "public";
  if (mode === "infer") {
    const infer: UserConfig = {
      root: resolve(import.meta.dirname, "infer"),
      publicDir: resolve(import.meta.dirname, "public"),
      plugins: [react(), renderBlocking(), inferSite()],
      base: "./",
      build: {
        outDir: resolve(import.meta.dirname, "../dist-infer"),
        emptyOutDir: true,
        sourcemap: false,
        rollupOptions: {
          input: {
            index: resolve(import.meta.dirname, "infer/index.html"),
            claim: resolve(import.meta.dirname, "infer/claim/index.html"),
            buy: resolve(import.meta.dirname, "infer/buy/index.html"),
            tokenomics: resolve(
              import.meta.dirname,
              "infer/tokenomics/index.html",
            ),
            notfound: resolve(import.meta.dirname, "infer/404.html"),
          },
        },
      },
    };
    return infer;
  }
  return {
    plugins: site
      ? [react(), renderBlocking(), publicSite(), docsPages(false)]
      : [react(), renderBlocking(), docsPages(true)],
    // The public site reads no chain: swap the live homepage for a stub so viem and the RPC layer
    // are not bundled at all.
    resolve: site
      ? {
          alias: [
            {
              find: /^\.\/landing-live$/,
              replacement: resolve(
                import.meta.dirname,
                "src/landing-live.public.tsx",
              ),
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
            ? { notfound: resolve(import.meta.dirname, "404.html") }
            : {
                terminal: resolve(import.meta.dirname, "terminal/index.html"),
              }),
          docs: resolve(import.meta.dirname, "docs/index.html"),
        },
      },
    },
  };
});
