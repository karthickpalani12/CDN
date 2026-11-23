/**
 * Production-ready Node.js Media Backend with Cloudflare CDN Integration
 * - Pure Node.js (Zero external npm dependencies needed to run)
 * - Video streaming with HTTP 206 Range requests (Accept-Ranges: bytes)
 * - Cloudflare Edge Caching headers (s-maxage, immutable, ETag)
 * - Cloudflare Cache Purge API integration
 * - Cloudflare Edge Header inspection (CF-Ray, CF-IPCountry, CF-Connecting-IP)
 */

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// Configuration
const PORT = process.env.PORT || 3000;
const MEDIA_DIR = path.join(__dirname, 'media');
const CLOUDFLARE_ZONE_ID = process.env.CLOUDFLARE_ZONE_ID || '';
const CLOUDFLARE_API_TOKEN = process.env.CLOUDFLARE_API_TOKEN || '';
const PUBLIC_CDN_URL = process.env.PUBLIC_CDN_URL || `http://localhost:${PORT}`;

// MIME Types
const MIME_TYPES = {
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.m4v': 'video/mp4',
  '.json': 'application/json',
  '.html': 'text/html'
};

const server = http.createServer(async (req, res) => {
  const startTime = Date.now();
  const parsedUrl = new URL(req.url, `http://${req.headers.host}`);
  const pathname = parsedUrl.pathname;

  // CORS Headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS, HEAD');
  res.setHeader('Access-Control-Expose-Headers', '*');

  if (req.method === 'OPTIONS') {
    res.writeHead(200);
    res.end();
    return;
  }

  // 1. Dashboard UI
  if (pathname === '/' || pathname === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(getDashboardHtml(req));
    return;
  }

  // 2. Cloudflare Diagnostic Endpoint
  if (pathname === '/api/cloudflare/status') {
    const cfInfo = {
      isBehindCloudflare: Boolean(req.headers['cf-ray']),
      cfRay: req.headers['cf-ray'] || 'Not detected (Direct Local Request)',
      cfConnectingIp: req.headers['cf-connecting-ip'] || req.socket.remoteAddress,
      cfCountry: req.headers['cf-ipcountry'] || 'Localhost',
      cfCacheStatus: req.headers['cf-cache-status'] || 'N/A',
      serverUptimeSec: Math.round(process.uptime()),
      zoneConfigured: Boolean(CLOUDFLARE_ZONE_ID && CLOUDFLARE_API_TOKEN),
      headersReceived: req.headers
    };
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(cfInfo, null, 2));
    return;
  }

  // 3. Cloudflare Cache Purge API Endpoint
  if (pathname === '/api/cloudflare/purge' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', async () => {
      try {
        const payload = body ? JSON.parse(body) : {};
        const result = await purgeCloudflareCache(payload);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (err) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: err.message }));
      }
    });
    return;
  }

  // 4. Media Delivery Endpoint (/media/:filename)
  if (pathname.startsWith('/media/')) {
    const filename = path.basename(pathname);
    const filePath = path.join(MEDIA_DIR, filename);

    if (!fs.existsSync(filePath)) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end(`File Not Found: ${filename}`);
      return;
    }

    const stat = fs.statSync(filePath);
    const fileSize = stat.size;
    const ext = path.extname(filePath).toLowerCase();
    const contentType = MIME_TYPES[ext] || 'application/octet-stream';

    // Generate strong ETag based on mtime and size
    const etag = `"${stat.mtime.getTime().toString(16)}-${fileSize.toString(16)}"`;

    // Check Conditional Revalidation (If-None-Match)
    if (req.headers['if-none-match'] === etag) {
      res.writeHead(304, {
        'ETag': etag,
        'Cache-Control': 'public, max-age=31536000, s-maxage=31536000, immutable',
        'Cloudflare-CDN-Cache-Control': 'max-age=31536000'
      });
      res.end();
      return;
    }

    // Common CDN Headers for Cloudflare
    const cdnHeaders = {
      'Content-Type': contentType,
      'Accept-Ranges': 'bytes',
      'ETag': etag,
      'Last-Modified': stat.mtime.toUTCString(),
      // Instruct both browser and Cloudflare Edge PoP to cache for 1 year
      'Cache-Control': 'public, max-age=31536000, s-maxage=31536000, immutable',
      'CDN-Cache-Control': 'max-age=31536000',
      'Cloudflare-CDN-Cache-Control': 'max-age=31536000',
      'X-Node-Origin': 'NodeJS-Backend-Service',
      'X-Response-Time': `${Date.now() - startTime}ms`
    };

    // Range Request Handling (HTTP 206 Partial Content for Video Streaming)
    const range = req.headers.range;
    if (range && range.startsWith('bytes=')) {
      const parts = range.replace(/bytes=/, '').split('-');
      const start = parseInt(parts[0], 10);
      const end = parts[1] ? parseInt(parts[1], 10) : fileSize - 1;

      if (start >= fileSize || end >= fileSize) {
        res.writeHead(416, { 'Content-Range': `bytes */${fileSize}` });
        res.end();
        return;
      }

      const chunkLength = (end - start) + 1;
      const fileStream = fs.createReadStream(filePath, { start, end });

      res.writeHead(206, {
        ...cdnHeaders,
        'Content-Range': `bytes ${start}-${end}/${fileSize}`,
        'Content-Length': chunkLength
      });

      fileStream.pipe(res);
      console.log(`[MEDIA 206] ${filename} bytes ${start}-${end} (${chunkLength} bytes) -> Range Served`);
      return;
    }

    // Full Content (HTTP 200)
    res.writeHead(200, {
      ...cdnHeaders,
      'Content-Length': fileSize
    });

    const fileStream = fs.createReadStream(filePath);
    fileStream.pipe(res);
    console.log(`[MEDIA 200] ${filename} (${(fileSize / (1024 * 1024)).toFixed(2)} MB) -> 200 OK`);
    return;
  }

  // 404 Fallback
  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not Found');
});

/**
 * Call Cloudflare Purge API
 */
function purgeCloudflareCache({ files, purgeEverything }) {
  return new Promise((resolve, reject) => {
    if (!CLOUDFLARE_ZONE_ID || !CLOUDFLARE_API_TOKEN) {
      resolve({
        success: false,
        message: 'CLOUDFLARE_ZONE_ID or CLOUDFLARE_API_TOKEN not set in environment.',
        help: 'Add them to .env or environment variables to enable remote Cloudflare API purging.'
      });
      return;
    }

    let payload = {};
    if (purgeEverything) {
      payload = { purge_everything: true };
    } else if (Array.isArray(files) && files.length > 0) {
      // Full URLs required by Cloudflare
      payload = {
        files: files.map(f => f.startsWith('http') ? f : `${PUBLIC_CDN_URL}${f}`)
      };
    } else {
      payload = { purge_everything: true };
    }

    const postData = JSON.stringify(payload);
    const options = {
      hostname: 'api.cloudflare.com',
      port: 443,
      path: `/client/v4/zones/${CLOUDFLARE_ZONE_ID}/purge_cache`,
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${CLOUDFLARE_API_TOKEN}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData)
      }
    };

    const req = https.request(options, (cfRes) => {
      let data = '';
      cfRes.on('data', chunk => data += chunk);
      cfRes.on('end', () => {
        try {
          resolve(JSON.parse(data));
        } catch (e) {
          resolve({ raw: data });
        }
      });
    });

    req.on('error', (e) => reject(e));
    req.write(postData);
    req.end();
  });
}

function getDashboardHtml(req) {
  const cfRay = req.headers['cf-ray'] || 'None (Direct Local)';
  const cfCountry = req.headers['cf-ipcountry'] || 'Local';
  const cfCache = req.headers['cf-cache-status'] || 'Local';

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Node.js Backend + Cloudflare CDN</title>
  <style>
    :root {
      --bg: #0f172a; --card: #1e293b; --border: #334155;
      --cf-orange: #f38020; --green: #22c55e; --text: #f8fafc; --text-dim: #94a3b8;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    body { background: var(--bg); color: var(--text); padding: 24px; }
    .header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); padding-bottom: 16px; margin-bottom: 24px; }
    .cf-badge { background: var(--cf-orange); color: white; padding: 4px 12px; border-radius: 999px; font-size: 13px; font-weight: 700; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 20px; margin-bottom: 24px; }
    .card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 20px; }
    .card h2 { font-size: 16px; margin-bottom: 12px; color: var(--cf-orange); display: flex; justify-content: space-between; }
    .media-preview { height: 160px; background: #000; border-radius: 6px; display: flex; align-items: center; justify-content: center; overflow: hidden; margin-bottom: 12px; }
    .media-preview img, .media-preview video { max-width: 100%; max-height: 100%; object-fit: contain; }
    .btn { background: #2563eb; color: white; border: none; padding: 8px 14px; border-radius: 6px; cursor: pointer; font-weight: 600; font-size: 13px; text-decoration: none; display: inline-block; }
    .btn:hover { background: #1d4ed8; }
    .btn-cf { background: var(--cf-orange); }
    .btn-cf:hover { background: #d96f14; }
    .table { width: 100%; font-size: 13px; margin-bottom: 12px; border-collapse: collapse; }
    .table td { padding: 6px 0; border-bottom: 1px solid #334155; }
    .table td:last-child { text-align: right; font-weight: 600; color: #38bdf8; }
    .log-box { background: #070c18; border: 1px solid var(--border); border-radius: 6px; padding: 12px; height: 160px; overflow-y: auto; font-family: monospace; font-size: 12px; line-height: 1.6; color: #a5f3fc; }
  </style>
</head>
<body>

  <div class="header">
    <div>
      <h1 style="display:flex; align-items:center; gap:10px;">
        ⚡ Node.js Media Service <span class="cf-badge">Cloudflare CDN Integrated</span>
      </h1>
      <p style="color: var(--text-dim); font-size: 13px; margin-top: 4px;">
        Listening on Port ${PORT} • Ready for Cloudflare Proxy & Cloudflare Tunnel
      </p>
    </div>
    <div>
      <button class="btn btn-cf" onclick="purgeCloudflare()">🗑️ Cloudflare Cache Purge</button>
    </div>
  </div>

  <div class="grid">
    <!-- Cloudflare Edge Inspector -->
    <div class="card">
      <h2>🌐 Cloudflare Edge Inspector</h2>
      <table class="table">
        <tr><td>Cloudflare Ray (Edge PoP):</td><td>${cfRay}</td></tr>
        <tr><td>Visitor Country (CF-IPCountry):</td><td>${cfCountry}</td></tr>
        <tr><td>CF Cache Status:</td><td>${cfCache}</td></tr>
        <tr><td>Cache-Control Header:</td><td>s-maxage=31536000</td></tr>
        <tr><td>Video Range Support:</td><td>Accept-Ranges: bytes</td></tr>
      </table>
      <div style="font-size: 12px; color: var(--text-dim);">
        When traffic passes through Cloudflare, <code>CF-Ray</code> reveals the exact edge data center (e.g., BOM, DEL, FRA, SJC).
      </div>
    </div>

    <!-- 15 MB Video -->
    <div class="card">
      <h2>🎥 15MB MP4 Video (Byte-Ranges)</h2>
      <div class="media-preview">
        <video controls src="/media/video-15mb.mp4"></video>
      </div>
      <div style="display:flex; gap:8px;">
        <a class="btn" href="/media/video-15mb.mp4" download>📥 Download (15MB)</a>
        <button class="btn btn-cf" onclick="testRange()">Test Range Header</button>
      </div>
    </div>

    <!-- Images -->
    <div class="card">
      <h2>🖼️ High-Res Images</h2>
      <div class="media-preview">
        <img src="/media/image-3mb.jpg" alt="3MB Sample" />
      </div>
      <div style="display:flex; gap:8px;">
        <a class="btn" href="/media/image-3mb.jpg" download>3 MB</a>
        <a class="btn" href="/media/image-5mb.jpg" download>5 MB</a>
        <a class="btn" href="/media/image-10mb.jpg" download>10 MB</a>
      </div>
    </div>
  </div>

  <div class="card">
    <h2>📋 Live API & Diagnostic Log</h2>
    <div class="log-box" id="log-box">
      [Ready] Node.js backend running on http://localhost:${PORT}<br/>
      [Ready] Media endpoints: /media/image-3mb.jpg, /media/video-15mb.mp4<br/>
      [Ready] Cloudflare Cache-Control: public, max-age=31536000, s-maxage=31536000, immutable
    </div>
  </div>

  <script>
    function log(msg) {
      const b = document.getElementById('log-box');
      b.innerHTML = '[' + new Date().toLocaleTimeString() + '] ' + msg + '<br/>' + b.innerHTML;
    }

    async function testRange() {
      const res = await fetch('/media/video-15mb.mp4', {
        headers: { 'Range': 'bytes=0-1024' }
      });
      log('Range Request (bytes=0-1024) -> Status: ' + res.status + ' (' + (res.headers.get('Content-Range') || '206 Partial Content') + ')');
    }

    async function purgeCloudflare() {
      log('Calling POST /api/cloudflare/purge...');
      const res = await fetch('/api/cloudflare/purge', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ purge_everything: true })
      });
      const data = await res.json();
      log('Cloudflare Purge Response: ' + JSON.stringify(data));
    }
  </script>
</body>
</html>`;
}

server.listen(PORT, () => {
  console.log('====================================================');
  console.log(`🚀 NODE.JS MEDIA BACKEND + CLOUDFLARE CDN`);
  console.log(`📡 Listening on: http://localhost:${PORT}`);
  console.log(`📁 Serving media from: ${MEDIA_DIR}`);
  console.log('====================================================');
});

