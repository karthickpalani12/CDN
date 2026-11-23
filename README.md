# CDN Simulator & Media Latency Test Lab

This lab demonstrates how a **Content Delivery Network (CDN)** reduces latency and improves user experience for **images and video streaming**.

---

## 🎯 How It Works

```
                                      [User / Browser]
                                             │
                       ┌─────────────────────┴─────────────────────┐
                       ▼ (HTTP Request)                            │
        ┌──────────────────────────────┐                           │
        │      CDN Edge Server         │                           │
        │    http://localhost:8000     │                           │
        │  (Simulates nearby edge PoP) │                           │
        └──────────────┬───────────────┘                           │
                       │                                           │
         Cache HIT? ───┼──► YES: Serves from local cache (~1-3 ms) │
                       │                                           │
                       ▼ NO (Cache MISS)                           ▼ Direct / Bypass (~260 ms)
        ┌──────────────────────────────┐                           │
        │     Remote Origin Server     │ ◄─────────────────────────┘
        │    http://localhost:8001     │
        │  (Simulates distant server,  │
        │    adds +250ms trip latency) │
        └──────────────────────────────┘
```

1. **Origin Server (`:8001`)**:
   - Represents your distant backend / storage (e.g., Frankfurt/US-East origin).
   - Injected with a **250ms simulated geographic latency**.
   - Contains high-resolution media (`sample-image.jpg`) and streamable video (`sample-video.mp4`).
2. **CDN Edge Server (`:8000`)**:
   - Acts as a local Edge Point of Presence (PoP) right near the user.
   - **First Request (Cache MISS)**: Fetches the media from origin (takes ~260ms), stores a copy in `edge_cache/`, and returns it to the client.
   - **Subsequent Requests (Cache HIT)**: Serves directly from edge disk/RAM cache in **1 to 3ms** (**99% faster**).
   - **Video Range Requests (`HTTP 206 Partial Content`)**: Serves video chunks on demand (`Range: bytes=...`) allowing instant seeking and zero buffering stutter.

---

## 🚀 How to Run

### Method 1: Double-click
Double-click `start_cdn.bat` in this folder.

### Method 2: Command Line
```powershell
dart run cdn_lab.dart
```

Once started, open your browser:
👉 **http://localhost:8000**

---

## 🧪 What to Test in the Dashboard

1. **Image Delivery Latency**:
   - Click **"Load via CDN"**. The first time, watch it show **MISS** (~260ms).
   - Click it again. Watch it turn green: **HIT (~2ms)** — 99% latency reduction!
2. **Direct Comparison Benchmark**:
   - Click **"Test Latency Comparison"**. It queries both Origin directly and CDN Edge, showing you side-by-side time savings.
3. **Video Seeking (Byte-Range Streaming)**:
   - Scrub back and forth on the video timeline. Notice instant playback without reloading the whole file thanks to `Accept-Ranges: bytes` (HTTP 206).
4. **Cache Flush**:
   - Click **"Flush CDN Cache"** to wipe cached files and observe the transition from Cache MISS to Cache HIT again.

