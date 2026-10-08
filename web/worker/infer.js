// infer.imdusd.com's Worker: the effect of Cloudflare's "Always Use HTTPS", then the static site built
// by `vite build --mode infer` (dist-infer/). Everything else is the assets binding, so _headers applies.
//
// One exception to _headers: /buy/ is an X player card, which X shows by framing the page inside a post.
// _headers forbids every frame (`frame-ancestors 'none'`, `X-Frame-Options: DENY`), and this route alone
// is answered with X's origins as its frame ancestors instead. Its scripts and styles are ordinary
// assets and keep the site's headers; only the document itself may be framed, and only by X.
// (whitepaper.imdusd.com runs this same Worker and has no /buy/, so there it is a 404 as before.)
export const FRAME_ANCESTORS =
  "frame-ancestors https://x.com https://*.x.com https://twitter.com https://*.twitter.com";
const FRAMEABLE = new Set(["/buy/", "/buy/index.html"]);

export function frameable(response) {
  const headers = new Headers(response.headers);
  const csp = headers.get("Content-Security-Policy");
  if (csp)
    headers.set(
      "Content-Security-Policy",
      csp.replace(/frame-ancestors [^;]*/, FRAME_ANCESTORS),
    );
  headers.delete("X-Frame-Options");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.protocol === "http:") {
      url.protocol = "https:";
      return Response.redirect(url.toString(), 301);
    }
    const response = await env.ASSETS.fetch(request);
    return FRAMEABLE.has(url.pathname) && response.ok
      ? frameable(response)
      : response;
  },
};
