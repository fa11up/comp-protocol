// infer.imdusd.com's Worker: the effect of Cloudflare's "Always Use HTTPS", then the static site built
// by `vite build --mode infer` (dist-infer/). Everything else is the assets binding, so _headers applies.
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
