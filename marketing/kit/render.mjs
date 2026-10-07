// Renders the kit's raster files from the site's own mark and palette, at exact pixel sizes.
// Run: node marketing/kit/render.mjs   (uses the Playwright already installed under web/)
import { chromium } from "../../web/node_modules/playwright/index.mjs";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const here = import.meta.dirname;
const svg = (name) => readFileSync(resolve(here, "logo", name), "utf8");
const INK = "#16202E";
const IVORY = "#F7F5EF";
const SLATE = "#5A6472";
const HAIRLINE = "#D8D3C7";
const FONT = `'SFMono-Regular', Menlo, Consolas, 'Liberation Mono', monospace`;

const mark = (name, px) =>
  svg(name).replace("<svg ", `<svg width="${px}" height="${px}" style="display:block;image-rendering:pixelated" `);

const logo = (name, bg) => `<body style="margin:0;background:${bg}">${mark(name, 1024)}</body>`;

// End card: the site's header lockup (imd + bold USD), the mark, the address and the staging chip,
// inside a double hairline frame that nods to a banknote border.
// status: "staging" (the default card), "" (the word blanked, for a blink) or "live" (in engraved green, bold).
// The status word sits in a fixed 7ch box so the chip does not change width between the states.
const GREEN = "#2F5D50";
const endcard = (w, h, status = "staging") => {
  const m = Math.round(Math.min(w, h) * 0.3);
  const word = Math.round(Math.min(w, h) * 0.105);
  return `<body style="margin:0;width:${w}px;height:${h}px;background:${IVORY};font-family:${FONT};color:${INK}">
  <div style="position:absolute;inset:${Math.round(h * 0.04)}px;border:2px solid ${INK};"></div>
  <div style="position:absolute;inset:${Math.round(h * 0.04) + 10}px;border:1px solid ${HAIRLINE};"></div>
  <div style="position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:${Math.round(h * 0.035)}px">
    ${mark("mark-transparent.svg", m)}
    <div style="font-size:${word}px;letter-spacing:-0.02em;line-height:1">imd<b>USD</b></div>
    <div style="font-size:${Math.round(word * 0.32)}px;color:${SLATE};letter-spacing:0.04em">imdusd.com</div>
    <div style="font-size:${Math.round(word * 0.2)}px;letter-spacing:0.12em;text-transform:uppercase;border:1px solid ${SLATE};color:${SLATE};padding:${Math.round(word * 0.07)}px ${Math.round(word * 0.16)}px;white-space:pre">Mainnet · <span style="display:inline-block;width:calc(7ch + 0.84em);text-align:left;${status === "live" ? `color:${GREEN};font-weight:700` : ""}${status ? "" : "visibility:hidden"}">${status || "staging"}</span></div>
  </div></body>`;
};

const jobs = [
  ["logo/mark-on-ivory-1024.png", 1024, 1024, logo("mark-on-ivory.svg", IVORY), false],
  ["logo/mark-on-ink-1024.png", 1024, 1024, logo("mark-on-ink.svg", INK), false],
  ["logo/mark-transparent-1024.png", 1024, 1024, logo("mark-transparent.svg", "transparent"), true],
  ["endcard/endcard-1920x1080.png", 1920, 1080, endcard(1920, 1080), false],
  ["endcard/endcard-1080x1080.png", 1080, 1080, endcard(1080, 1080), false],
  ["endcard/endcard-1080x1920.png", 1080, 1920, endcard(1080, 1920), false],
  // the blink from STAGING to LIVE at the end of the explainer (16:9)
  ["endcard/endcard-1920x1080-blank.png", 1920, 1080, endcard(1920, 1080, ""), false],
  ["endcard/endcard-1920x1080-live.png", 1920, 1080, endcard(1920, 1080, "live"), false],
];

const browser = await chromium.launch();
for (const [out, w, h, html, transparent] of jobs) {
  const page = await browser.newPage({ viewport: { width: w, height: h } });
  await page.setContent(html);
  await page.screenshot({ path: resolve(here, out), omitBackground: transparent });
  await page.close();
  console.log("wrote", out);
}
await browser.close();
