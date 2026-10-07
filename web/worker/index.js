// imdusd.com's Worker: the effect of Cloudflare's "Always Use HTTPS" and one canonical host, then
// the static site. The zone settings need permissions the deploy login does not hold, so both
// redirects live here. Everything else is the assets binding, so _headers and _redirects still apply.
const HOST = "imdusd.com";
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    // One host for crawlers and caches: www. and plain http both land on https://imdusd.com.
    if (url.protocol === "http:" || url.hostname === `www.${HOST}`) {
      url.protocol = "https:";
      if (url.hostname === `www.${HOST}`) url.hostname = HOST;
      return Response.redirect(url.toString(), 301);
    }
    return env.ASSETS.fetch(request);
  },
};
