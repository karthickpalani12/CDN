/**
 * Cloudflare Worker CDN Gateway for https://cdn-qy77.onrender.com
 * Caches images, videos (HTTP 206 byte-ranges), and static assets at Cloudflare's Edge
 */

const ORIGIN_BACKEND = 'https://cdn-qy77.onrender.com';

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const originUrl = new URL(url.pathname + url.search, ORIGIN_BACKEND);

    // Forward headers but rewrite host to origin
    const newHeaders = new Headers(request.headers);
    newHeaders.set('host', new URL(ORIGIN_BACKEND).host);

    const originRequest = new Request(originUrl.toString(), {
      method: request.method,
      headers: newHeaders,
    });

    // Check Cloudflare Edge Cache
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

    // Cache MISS: Fetch from Render backend
    const response = await fetch(originRequest, {
      cf: {
        cacheEverything: true,
        cacheTtl: 31536000, // 1 year edge cache
      },
    });

    // Cache successful responses at Cloudflare Edge
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

