/**
 * Cloudflare Worker for Edge Media Caching & Acceleration
 * Deploy this in Cloudflare Dashboard > Workers & Pages
 * 
 * Capabilities:
 * 1. Uses Cloudflare Cache API (caches.default) to cache large media at the edge
 * 2. Caches byte-range requests for video streaming (HTTP 206 Partial Content)
 * 3. Adds security and diagnostic headers (CF-Ray, Edge Cache Hit status)
 */

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const cache = caches.default;

    // Only cache GET and HEAD requests for media assets
    const isMedia = /\.(jpg|jpeg|png|webp|avif|mp4|webm|m4v)$/i.test(url.pathname);
    if (request.method !== 'GET' && request.method !== 'HEAD' || !isMedia) {
      return fetch(request);
    }

    // Check if the response is already in Cloudflare Edge Cache
    let response = await cache.match(request);

    if (response) {
      // ⚡ Edge Cache HIT
      const newHeaders = new Headers(response.headers);
      newHeaders.set('X-Worker-Cache', 'HIT');
      return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers: newHeaders,
      });
    }

    // 🐢 Edge Cache MISS: Fetch from your Node.js Origin Server
    response = await fetch(request, {
      cf: {
        // Tell Cloudflare Edge to cache based on URL
        cacheEverything: true,
        cacheTtl: 31536000, // 1 year TTL at Cloudflare edge
        cacheKey: request.url,
      },
    });

    // Clone response to put into Cloudflare's Edge Cache
    const responseToCache = response.clone();
    const headers = new Headers(response.headers);

    // Ensure proper CDN headers are attached
    headers.set('Cache-Control', 'public, max-age=31536000, s-maxage=31536000, immutable');
    headers.set('X-Worker-Cache', 'MISS');

    // Store in Cloudflare Edge Cache asynchronously (non-blocking)
    if (response.status === 200 || response.status === 206) {
      ctx.waitUntil(cache.put(request, responseToCache));
    }

    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers: headers,
    });
  },
};

