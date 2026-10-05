// imdusd.com's Worker: the effect of Cloudflare's "Always Use HTTPS", then the static site.
// The zone setting needs a zone-settings permission the deploy login does not hold, so the redirect
// lives here instead. Everything else is the assets binding, so _headers and _redirects still apply.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.protocol === "http:") {
      url.protocol = "https:";
      return Response.redirect(url.toString(), 301);
    }
    return env.ASSETS.fetch(request);
  },
};
