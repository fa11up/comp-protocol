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

// The public site has no terminal yet, so anything that refers to it is redacted: removed from the
// page (not hidden with CSS) and drawn as a black bar of about the same length. Whole pages about
// the terminal are redacted throughout.
const TERMINAL_RE = /terminal/i;
const REDACT_WHOLE = new Set(["guides/use-the-terminal.md"]);
const plainText = (md) =>
  md
    .replace(/`([^`]*)`/g, "$1")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/[*_>#|-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
/** Braille filler standing in for `text`: random patterns in the original's word shapes, so lines
 * wrap like the original while none of its words reach the page. Seeded from the text so builds are
 * reproducible. */
const bar = (text) => {
  const src = plainText(text).slice(0, 400) || "xxxx";
  let seed = 2166136261;
  for (const ch of src) seed = Math.imul(seed ^ ch.charCodeAt(0), 16777619) >>> 0;
  const rnd = () => ((seed = Math.imul(seed ^ (seed >>> 15), 2246822507) >>> 0), seed / 4294967296);
  // Braille patterns U+2801..U+28FF (U+2800 is blank, so it is skipped).
  const filler = src.replace(/\S/g, () => String.fromCodePoint(0x2801 + Math.floor(rnd() * 255)));
  return `<span class="redacted" role="img" aria-label="Redacted"><span aria-hidden="true">${filler}</span></span>`;
};
/** A title with only the word "terminal" barred. */
const titleHtml = (t, redact) => {
  const e = escapeHtml(t);
  return redact ? e.replace(/terminal/gi, (w) => bar(w + "xx")) : e;
};
const titleText = (t, redact) => (redact ? t.replace(/terminal/gi, "████████") : t);

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
    // A wholly redacted page gets a neutral address in the public build, so its URL does not leak.
    const slug = !terminal && REDACT_WHOLE.has(file) ? "redacted" : name;
    return { file, section, name, dir: `docs/${section}/${slug}`, meta, body, order: Number(meta.order) };
  });
  pages.sort(
    (a, b) =>
      SECTIONS.findIndex(([s]) => s === a.section) - SECTIONS.findIndex(([s]) => s === b.section) || a.order - b.order,
  );
  const byFile = new Map(pages.map((p) => [p.file, p]));

  const template = readFileSync(resolve(outDir, "docs/index.html"), "utf8");
  if (!template.includes("<!--DOCS-BODY-->")) throw Error("docs/index.html has no <!--DOCS-BODY--> slot");

  // The site mark (the favicon's pixels), in the text colour so it follows the theme.
  const favicon = readFileSync(resolve(contentDir, "../../public/favicon.svg"), "utf8");
  const markRects = favicon.match(/<g style="fill:var\(--text\)">(.*?)<\/g>/)?.[1];
  if (!markRects) throw Error("public/favicon.svg: mark not found");
  const mark = `<svg viewBox="0 0 16 16" width="28" height="28" shape-rendering="crispEdges" aria-hidden="true" focusable="false"><g fill="currentColor">${markRects}</g></svg>`;

  // Sections fold closed; the one holding the current page starts open. Native <details>, no script.
  const nav = (currentDir) => {
    const here = pages.find((p) => p.dir === currentDir)?.section;
    return (
      `<nav class="docs-nav" id="docs-contents" aria-label="Documentation">` +
      `<a class="docs-home" href="${linkBetween(currentDir, "docs")}" aria-label="Docs home"${currentDir === "docs" ? ' aria-current="page"' : ""}>${mark}</a>` +
      SECTIONS.map(([s, label]) => {
        const items = pages.filter((p) => p.section === s);
        return `<details${s === here ? " open" : ""}><summary>${label}</summary><ul>${items
          .map(
            (p) =>
              `<li><a href="${linkBetween(currentDir, p.dir)}"${p.dir === currentDir ? ' aria-current="page"' : ""}>${titleHtml(p.meta.title, redact)}</a></li>`,
          )
          .join("")}</ul></details>`;
      }).join("") +
      `</nav>`
    );
  };

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

  const redact = !terminal;
  // A vault function named in code is linked to its entry on the Vault functions page, on its first
  // mention in a page's prose. Headings, tables and existing links are left alone.
  const FN_FILE = "reference/vault-functions.md";
  const fnPage = byFile.get(FN_FILE);
  const VAULT_FNS = new Set(fnPage ? [...fnPage.body.matchAll(/^###\s+`(\w+)\(/gm)].map((m) => m[1]) : []);
  const noLink = (t) => {
    if (!t || typeof t !== "object") return;
    if (t.type === "codespan") t.noLink = true;
    for (const k of ["tokens", "items", "header"]) if (Array.isArray(t[k])) t[k].forEach(noLink);
    if (Array.isArray(t.rows)) t.rows.forEach((r) => r.forEach(noLink));
  };
  const render = (page) => {
    const linked = new Set();
    const whole = redact && REDACT_WHOLE.has(page.file);
    const hit = (raw) => redact && (whole || TERMINAL_RE.test(raw));
    const marked = new Marked({ gfm: true });
    const used = new Map();
    marked.use({
      walkTokens(token) {
        if (token.type === "heading" || token.type === "table") noLink(token);
        if (token.type !== "link") return;
        noLink(token);
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
        paragraph(token) {
          return hit(token.raw) ? `<p>${bar(token.raw)}</p>\n` : `<p>${this.parser.parseInline(token.tokens)}</p>\n`;
        },
        listitem(item) {
          if (!hit(item.raw)) return false; // default rendering
          return `<li>${bar(item.text)}</li>\n`;
        },
        // Tables are built here so every body cell carries its column's name (data-label): on a phone
        // each row becomes a stacked card, labelled from it. Redacted cells become bars.
        table(token) {
          const cell = (c) => (hit(c.text) ? bar(c.text) : this.parser.parseInline(c.tokens));
          const align = (i) => (token.align[i] ? ` style="text-align:${token.align[i]}"` : "");
          const labels = token.header.map((h) => (hit(h.text) ? "" : plainText(h.text)));
          // A column whose every value is short never wraps; the long-prose columns take the squeeze.
          const short = token.header.map((_, i) => token.rows.every((r) => plainText(r[i]?.text ?? "").length <= 30));
          const cls = (i) => (short[i] ? ' class="nowrap"' : "");
          const head = token.header.map((h, i) => `<th scope="col"${cls(i)}${align(i)}>${cell(h)}</th>`).join("");
          const rows = token.rows
            .map(
              (row) =>
                `<tr>${row.map((c, i) => `<td data-label="${escapeHtml(labels[i] ?? "")}"${cls(i)}${align(i)}>${cell(c)}</td>`).join("")}</tr>`,
            )
            .join("\n");
          return `<div class="table-wrap"><table><thead><tr>${head}</tr></thead><tbody>\n${rows}\n</tbody></table></div>\n`;
        },
        blockquote(token) {
          return hit(token.raw) ? `<blockquote><p>${bar(token.raw)}</p></blockquote>\n` : false;
        },
        code(token) {
          return hit(token.text) ? `<p>${bar(token.text)}</p>\n` : false;
        },
        codespan(token) {
          const m = /^(\w+)(\(.*\))?$/.exec(token.text);
          if (!fnPage || page === fnPage || token.noLink || !m || !VAULT_FNS.has(m[1]) || linked.has(m[1])) return false;
          linked.add(m[1]);
          return `<a class="fn-link" href="${linkBetween(page.dir, fnPage.dir)}#${m[1]}"><code>${token.text}</code></a>`;
        },
        heading(token) {
          const inner = whole && token.depth > 1
            ? bar(token.text)
            : redact && TERMINAL_RE.test(token.text)
              ? titleHtml(token.text, true)
              : this.parser.parseInline(token.tokens);
          // A redacted heading's id must not spell out what it hides.
          let id = whole || (redact && TERMINAL_RE.test(token.text)) ? "redacted" : slugify(token.text);
          // Function entries get short anchors (#bark, not #barkaddress-owner) so other pages can link them.
          const fn = page === fnPage && /^`(\w+)\(/.exec(token.text);
          if (fn) id = fn[1];
          const n = used.get(id) ?? 0;
          used.set(id, n + 1);
          if (n) id = `${id}-${n}`;
          return `<h${token.depth} id="${id}">${inner}</h${token.depth}>\n`;
        },
      },
    });
    return marked.parse(page.body);
  };

  // Check every #anchor link resolves to a heading on its target page.
  for (const p of pages) {
    // Launch values are shown as an em dash with one note per page, never spelled out inline.
    if (p.body.includes("(under consideration)")) throw Error(`${p.file}: write a pending value as — and set pending: true`);
  }
  const PENDING_NOTE = `<p class="pending-note">A <span aria-hidden="true">—</span><span class="sr-only">dash</span> marks a value set at mainnet launch.</p>`;
  const rendered = new Map(
    pages.map((p) => [p.file, p.meta.pending === "true" ? render(p).replace("</h1>", `</h1>${PENDING_NOTE}`) : render(p)]),
  );
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
      (redact && REDACT_WHOLE.has(p.file) ? `<p class="redaction-note">Redacted until mainnet launch.</p>` : "") +
      rendered.get(p.file) +
      (sources.length && !(redact && REDACT_WHOLE.has(p.file))
        ? `<p class="doc-sources">Sources: ${sources.map((s) => `<a href="${REPO}${escapeHtml(s)}" target="_blank" rel="noreferrer">${escapeHtml(s)}</a>`).join(", ")}</p>`
        : "") +
      `<nav class="doc-pager" aria-label="Next and previous">` +
      (prev ? `<a class="prev" href="${linkBetween(p.dir, prev.dir)}"><span class="pager-label">Previous</span>${titleHtml(prev.meta.title, redact)}</a>` : "<span></span>") +
      (next ? `<a class="next" href="${linkBetween(p.dir, next.dir)}"><span class="pager-label">Next</span>${titleHtml(next.meta.title, redact)}</a>` : "<span></span>") +
      `</nav></article>` +
      nav(p.dir) +
      `</main>` +
      footer(p.dir);
    const desc = summary(p.body);
    const safeDesc = redact && (REDACT_WHOLE.has(p.file) || TERMINAL_RE.test(desc)) ? "" : desc;
    page(p.dir, `${titleText(p.meta.title, redact)} · imdUSD docs`, safeDesc || `imdUSD docs: ${titleText(p.meta.title, redact)}`, body);
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
            `<li><a href="${linkBetween("docs", p.dir)}">${titleHtml(p.meta.title, redact)}</a>${p.meta.audience ? `<span class="audience">${AUDIENCE[p.meta.audience] ?? ""}</span>` : ""}</li>`,
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
