// Renders web/content/docs/**/*.md into static pages under <out>/docs/, after Vite has built the
// docs shell (docs/index.html). Each page is real HTML at /docs/<section>/<page>/ so it links, reads
// without JavaScript and can be indexed; the React entry only mounts the shared header.
//
// The content was written by the swarm, so it is treated as untrusted: raw HTML in the Markdown is
// escaped, never rendered, and every internal link must resolve to a page or the build fails.
import { readFileSync, writeFileSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { resolve, relative, dirname, posix } from "node:path";
import { Marked } from "marked";

const SECTIONS = [
  ["overview", "Overview"],
  ["guides", "Guides"],
  ["keepers", "Keepers"],
  ["governance", "Governance"],
  ["economics", "Economics"],
  ["reference", "Reference"],
];
const AUDIENCE = {
  everyone: "For everyone",
  borrowers: "For borrowers",
  keepers: "For keepers",
  governance: "For governance",
  integrators: "For integrators",
};
const REPO = "https://github.com/fa11up/infer-protocol/blob/main/";

const escapeHtml = (s) =>
  String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

/** GitHub-style heading ids, so `page.md#a-heading` links keep working. */
const slugify = (text) =>
  text
    .toLowerCase()
    .replace(/<[^>]+>/g, "")
    .replace(/[^\p{L}\p{N}\s_-]/gu, "")
    .trim()
    .replace(/\s/g, "-");

function frontMatter(source, file) {
  const m = source.match(/^---\n([\s\S]*?)\n---\n/);
  if (!m) throw Error(`${file}: missing front matter`);
  const meta = { sources: [] };
  let list = null;
  for (const line of m[1].split("\n")) {
    const item = line.match(/^\s+-\s+(.*)$/);
    if (item && list) meta[list].push(item[1].trim());
    else {
      const kv = line.match(/^(\w+):\s*(.*)$/);
      if (!kv) continue;
      if (kv[2] === "") {
        list = kv[1];
        meta[list] = [];
      } else {
        list = null;
        meta[kv[1]] = kv[2].trim();
      }
    }
  }
  for (const k of ["title", "section", "order"]) if (!meta[k]) throw Error(`${file}: front matter lacks ${k}`);
  return { meta, body: source.slice(m[0].length) };
}

function walk(dir, base = dir) {
  return readdirSync(dir).flatMap((n) => {
    const p = resolve(dir, n);
    return statSync(p).isDirectory() ? walk(p, base) : n.endsWith(".md") ? [relative(base, p)] : [];
  });
}

/** Path from one docs page directory to another, both relative to the site root, ending in "/". */
const linkBetween = (fromDir, toDir) => {
  const r = posix.relative(fromDir, toDir);
  return r === "" ? "./" : `${r}/`;
};

export function renderDocs({ outDir, contentDir, terminal }) {
  const files = walk(contentDir).map((f) => f.split("\\").join("/"));
  const pages = files.map((file) => {
    const { meta, body } = frontMatter(readFileSync(resolve(contentDir, file), "utf8"), file);
    const [section, name] = file.replace(/\.md$/, "").split("/");
    if (!SECTIONS.some(([s]) => s === section)) throw Error(`${file}: unknown section ${section}`);
    return { file, section, name, dir: `docs/${section}/${name}`, meta, body, order: Number(meta.order) };
  });
  pages.sort(
    (a, b) =>
      SECTIONS.findIndex(([s]) => s === a.section) - SECTIONS.findIndex(([s]) => s === b.section) || a.order - b.order,
  );
  const byFile = new Map(pages.map((p) => [p.file, p]));

  const template = readFileSync(resolve(outDir, "docs/index.html"), "utf8");
  if (!template.includes("<!--DOCS-BODY-->")) throw Error("docs/index.html has no <!--DOCS-BODY--> slot");

  const nav = (currentDir) =>
    `<nav class="docs-nav" id="docs-contents" aria-label="Documentation">` +
    `<a class="docs-home" href="${linkBetween(currentDir, "docs")}"${currentDir === "docs" ? ' aria-current="page"' : ""}>Docs home</a>` +
    SECTIONS.map(([s, label]) => {
      const items = pages.filter((p) => p.section === s);
      return `<h2>${label}</h2><ul>${items
        .map(
          (p) =>
            `<li><a href="${linkBetween(currentDir, p.dir)}"${p.dir === currentDir ? ' aria-current="page"' : ""}>${escapeHtml(p.meta.title)}</a></li>`,
        )
        .join("")}</ul>`;
    }).join("") +
    `</nav>`;

  const footer = (currentDir) => {
    const root = posix.relative(currentDir, "") || ".";
    return (
      `<footer class="site-footer"><nav aria-label="Footer">` +
      (terminal ? `<a href="${root}/terminal/">Terminal</a>` : "") +
      `<a href="${linkBetween(currentDir, "docs")}">Docs</a>` +
      `<a href="https://infer.miyagod.eth.limo" target="_blank" rel="noreferrer">Whitepaper ↗</a>` +
      `</nav><span>imdUSD · built on IdentityMD</span></footer>`
    );
  };

  const render = (page) => {
    const marked = new Marked({ gfm: true });
    const used = new Map();
    marked.use({
      walkTokens(token) {
        if (token.type !== "link") return;
        const [target, hash] = token.href.split("#");
        if (/^[a-z]+:/i.test(target)) return; // external
        if (!target) return; // same-page anchor
        if (!target.endsWith(".md")) throw Error(`${page.file}: link to a non-page ${token.href}`);
        const file = posix.normalize(posix.join(posix.dirname(page.file), target));
        const to = byFile.get(file);
        if (!to) throw Error(`${page.file}: broken link ${token.href} (no ${file})`);
        token.href = linkBetween(page.dir, to.dir) + (hash ? `#${hash}` : "");
      },
      renderer: {
        // Swarm-written content: raw HTML is shown as text, never rendered.
        html: (token) => escapeHtml(token.text),
        heading(token) {
          const inner = this.parser.parseInline(token.tokens);
          let id = slugify(token.text);
          const n = used.get(id) ?? 0;
          used.set(id, n + 1);
          if (n) id = `${id}-${n}`;
          return `<h${token.depth} id="${id}">${inner}</h${token.depth}>\n`;
        },
      },
    });
    return marked
      .parse(page.body)
      .replace(/<table>/g, '<div class="table-wrap"><table>')
      .replace(/<\/table>/g, "</table></div>");
  };

  // Check every #anchor link resolves to a heading on its target page.
  const rendered = new Map(pages.map((p) => [p.file, render(p)]));
  for (const p of pages) {
    for (const [, href] of rendered.get(p.file).matchAll(/href="([^"]*#[^"]+)"/g)) {
      const [path, hash] = href.split("#");
      const dir = path ? posix.normalize(posix.join(p.dir, path)).replace(/\/$/, "") : p.dir;
      const target = pages.find((q) => q.dir === dir);
      if (!target) continue;
      if (!rendered.get(target.file).includes(` id="${hash}"`)) throw Error(`${p.file}: anchor #${hash} not found in ${target.file}`);
    }
  }

  const page = (dir, title, description, body) => {
    const depth = dir.split("/").length; // docs = 1, docs/a/b = 3
    const up = "../".repeat(depth);
    let html = template;
    if (depth !== 1) html = html.replace(/(["'(])\.\.\//g, `$1${up}`);
    html = html
      .replace(/<title>[^<]*<\/title>/, `<title>${escapeHtml(title)}</title>`)
      .replace(
        /(<meta\s+name="description"\s+content=")[^"]*(")/,
        (_, a, b) => `${a}${escapeHtml(description)}${b}`,
      )
      .replace("<!--DOCS-BODY-->", body);
    mkdirSync(resolve(outDir, dir), { recursive: true });
    writeFileSync(resolve(outDir, dir, "index.html"), html);
  };

  const summary = (md) =>
    (md.replace(/^#.*$/gm, "").match(/^[^\s#>|`-].+$/m)?.[0] ?? "")
      .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
      .replace(/[`*_]/g, "")
      .slice(0, 160);

  pages.forEach((p, i) => {
    const prev = pages[i - 1];
    const next = pages[i + 1];
    const sources = [...new Set((p.meta.sources ?? []).map((s) => s.replace(/:.*$/, "")))];
    const label = SECTIONS.find(([s]) => s === p.section)[1];
    const body =
      `<main class="docs" id="docs-main">` +
      `<a class="docs-skip" href="#docs-contents">Contents</a>` +
      `<article class="doc">` +
      `<p class="doc-meta">${label}${p.meta.audience ? ` · ${AUDIENCE[p.meta.audience] ?? escapeHtml(p.meta.audience)}` : ""}</p>` +
      rendered.get(p.file) +
      (sources.length
        ? `<p class="doc-sources">Sources: ${sources.map((s) => `<a href="${REPO}${escapeHtml(s)}" target="_blank" rel="noreferrer">${escapeHtml(s)}</a>`).join(", ")}</p>`
        : "") +
      `<nav class="doc-pager" aria-label="Next and previous">` +
      (prev ? `<a class="prev" href="${linkBetween(p.dir, prev.dir)}"><span>Previous</span>${escapeHtml(prev.meta.title)}</a>` : "<span></span>") +
      (next ? `<a class="next" href="${linkBetween(p.dir, next.dir)}"><span>Next</span>${escapeHtml(next.meta.title)}</a>` : "<span></span>") +
      `</nav></article>` +
      nav(p.dir) +
      `</main>` +
      footer(p.dir);
    page(p.dir, `${p.meta.title} · imdUSD docs`, summary(p.body) || `imdUSD docs: ${p.meta.title}`, body);
  });

  const index =
    `<main class="docs" id="docs-main">` +
    `<a class="docs-skip" href="#docs-contents">Contents</a>` +
    `<article class="doc docs-index"><p class="doc-meta">imdUSD</p><h1>Documentation</h1>` +
    `<p class="lede">How imdUSD works, how to use it, and how to read and keep the contracts.</p>` +
    SECTIONS.map(([s, label]) => {
      const items = pages.filter((p) => p.section === s);
      return `<section><h2>${label}</h2><ul>${items
        .map(
          (p) =>
            `<li><a href="${linkBetween("docs", p.dir)}">${escapeHtml(p.meta.title)}</a>${p.meta.audience ? `<span>${AUDIENCE[p.meta.audience] ?? ""}</span>` : ""}</li>`,
        )
        .join("")}</ul></section>`;
    }).join("") +
    `</article>` +
    nav("docs") +
    `</main>` +
    footer("docs");
  page("docs", "imdUSD docs", "How imdUSD works: borrowing, redemption, liquidation, the swarm oracle and the contracts.", index);
  return pages.length;
}
