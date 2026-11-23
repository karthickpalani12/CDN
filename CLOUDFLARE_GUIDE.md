# Cloudflare CDN + Node.js Backend Integration Guide

This guide explains how to connect your Node.js backend service in `d:\CDN\node_service` with Cloudflare to deliver images and videos with ultra-low latency worldwide.

---

## 🎯 Architecture

```
User (Anywhere in the World)
          │
          ▼ (Ultra-low latency: 5–20 ms)
┌────────────────────────────────────────┐
│  Cloudflare Edge Data Center           │
│  - 300+ global locations               │
│  - Serves cached images & 206 videos   │
└──────────────────┬─────────────────────┘
                   │
         Cache Hit? ──► YES: Instant response to user
                   │
                  NO (Cache Miss)
                   ▼
┌────────────────────────────────────────┐
│  Your Node.js Origin Backend (:3000)   │
│  - Serves media/image-*.jpg            │
│  - Serves media/video-15mb.mp4         │
│  - Returns 's-maxage=31536000'         │
└────────────────────────────────────────┘
```

---

## 🚀 How to Run the Node.js Backend

1. Make sure Node.js is installed on your computer ([https://nodejs.org](https://nodejs.org) LTS version).
2. Start the service:
   - Double-click `start_node.bat`, or
   - Open terminal in `d:\CDN\node_service` and run:
     ```bash
     node server.js
     ```
3. Open **http://localhost:3000** in your browser to view the live dashboard.

---

## 🌐 3 Ways to Connect Cloudflare to Your Node.js Service

### Method 1: Cloudflare Tunnel (Best for Local Testing — No Port Forwarding Needed)
You can expose your local Node.js server to Cloudflare's global edge network in 30 seconds for free:

1. Download the Cloudflare Tunnel CLI (`cloudflared`):
   - Direct download: [https://github.com/cloudflare/cloudflared/releases/latest](https://github.com/cloudflare/cloudflared/releases/latest) (download `cloudflared-windows-amd64.exe` and rename to `cloudflared.exe`).
2. Run this command:
   ```bash
   cloudflared tunnel --url http://localhost:3000
   ```
3. Cloudflare will give you a public URL like:
   👉 `https://random-word-abc.trycloudflare.com`
4. Access that URL! All requests are now flowing through **real Cloudflare edge servers** with:
   - Free SSL
   - Cloudflare Ray edge detection
   - Edge media caching for your images and 15MB video!

---

### Method 2: Production Domain (Cloudflare DNS Proxy)
When your Node.js service is deployed to a server or VPS (e.g. AWS, DigitalOcean, Hetzner):

1. **Add DNS Record in Cloudflare**:
   - Type: `A` (or `CNAME`)
   - Name: `media` (e.g., `media.yourdomain.com`)
   - Target: Your Server's Public IP
   - Proxy status: **Proxied (Orange Cloud ON)**
2. **Configure Cloudflare Cache Rules**:
   - Go to Cloudflare Dashboard > **Caching** > **Cache Rules** > **Create Rule**:
     - When incoming requests match: `URI Path starts with "/media/"`
     - Cache eligibility: **Eligible for cache**
     - Edge Cache TTL: **Override origin: 1 year** (or Respect Origin)
3. **Cloudflare Cache Purge from Node.js**:
   - Copy `.env.example` to `.env` in `d:\CDN\node_service/`
   - Fill in `CLOUDFLARE_ZONE_ID` and `CLOUDFLARE_API_TOKEN`
   - The Node.js server can now purge Cloudflare's edge cache automatically whenever you upload or replace an image or video!

---

### Method 3: Cloudflare Worker (`cloudflare_worker.js`)
If you want serverless edge logic directly inside Cloudflare:

1. In Cloudflare Dashboard, go to **Workers & Pages** > **Create application** > **Create Worker**.
2. Copy the code from `d:\CDN\node_service\cloudflare_worker.js` and paste it into the editor.
3. Deploy the worker. It uses Cloudflare's native `caches.default` API to intercept media requests, cache byte ranges, and serve video and images in single-digit milliseconds.

