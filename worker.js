/**
 * Cloudflare Worker CDN Gateway for https://cdn-qy77.onrender.com
 * Fixes Cloudflare-to-Cloudflare header conflicts and double-slash paths
 */

const ORIGIN_BACKEND = 'https://cdn-qy77.onrender.com';

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    // Clean duplicate slashes (e.g. //media/ -> /media/)
    const cleanPath = url.pathname.replace(/\/+/g, '/');
    const targetUrl = ORIGIN_BACKEND + cleanPath + url.search;

    // Check Cloudflare Edge Cache first
    const cache = caches.default;
    let cachedResponse = await cache.match(request);

    if (cachedResponse) {
      const hitHeaders = new Headers(cachedResponse.headers);
      hitHeaders.set('X-Worker-Cache', 'HIT');
      return new Response(cachedResponse.body, {
        status: cachedResponse.status,
        statusText: cachedResponse.statusText,
        headers: hitHeaders,
      });
    }

    // Prepare clean headers for Render (avoid CF-to-CF 403 Forbidden header spoofing block)
    const forwardHeaders = new Headers();
    if (request.headers.get('accept')) forwardHeaders.set('accept', request.headers.get('accept'));
    if (request.headers.get('accept-encoding')) forwardHeaders.set('accept-encoding', request.headers.get('accept-encoding'));
    if (request.headers.get('range')) forwardHeaders.set('range', request.headers.get('range'));
    forwardHeaders.set('user-agent', request.headers.get('user-agent') || 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)');

    // Fetch from Render
    const response = await fetch(targetUrl, {
      method: request.method,
      headers: forwardHeaders,
      cf: {
        cacheEverything: true,
        cacheTtl: 31536000, // 1 year edge cache
      },
    });

    // Save successful media to Cloudflare Edge Cache
    if (response.status === 200 || response.status === 206) {
      ctx.waitUntil(cache.put(request, response.clone()));
    }

    const responseHeaders = new Headers(response.headers);
    responseHeaders.set('X-Worker-Cache', 'MISS');

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers: responseHeaders,
    });
  },
};
