// imdusd.com's Worker. NOT RUN in normal operation (run_worker_first is false, so Cloudflare serves every file
// straight from its cache and never invokes it): both redirects below are now the zone's "Always Use HTTPS"
// setting and a www -> imdusd.com Redirect Rule. Kept as the fallback if those are ever switched off: set
// run_worker_first back to true in wrangler.jsonc and this restores them.
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
