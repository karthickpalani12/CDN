import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

const int CDN_PORT = 8000;
const int ORIGIN_PORT = 8001;
const int ORIGIN_SIMULATED_LATENCY_MS = 250; // Simulates geographic distance to origin

final Directory workDir = Directory.current;
final Directory originDir = Directory('${workDir.path}/origin_storage');
final Directory cacheDir = Directory('${workDir.path}/edge_cache');

int totalRequests = 0;
int cacheHits = 0;
int cacheMisses = 0;

void main() async {
  print('====================================================');
  print('       CDN SIMULATOR & LATENCY TEST LAB             ');
  print('====================================================');

  await setupSampleMedia();

  // 1. Start Origin Server
  final originServer = await HttpServer.bind(InternetAddress.loopbackIPv4, ORIGIN_PORT);
  print('[ORIGIN SERVER] Listening on http://localhost:$ORIGIN_PORT (Simulated latency: ${ORIGIN_SIMULATED_LATENCY_MS}ms)');
  originServer.listen(handleOriginRequest);

  // 2. Start CDN Edge Server
  final cdnServer = await HttpServer.bind(InternetAddress.loopbackIPv4, CDN_PORT);
  print('[CDN EDGE POPS] Listening on http://localhost:$CDN_PORT');
  print('----------------------------------------------------');
  print('Open your browser and visit: http://localhost:$CDN_PORT');
  print('Press Ctrl+C to stop.');
  print('====================================================\n');
  cdnServer.listen(handleCdnRequest);
}

// ---------------------------------------------------------------------------
// Sample Media Setup
// ---------------------------------------------------------------------------
Future<void> setupSampleMedia() async {
  if (!originDir.existsSync()) originDir.createSync(recursive: true);
  if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);

  // Check and generate base files if needed
  final baseImage = File(r'C:\Windows\Web\Screen\img100.jpg');
  final srcBytes = baseImage.existsSync() 
      ? baseImage.readAsBytesSync() 
      : Uint8List.fromList(List.generate(1024 * 500, (i) => i % 256));

  void ensureJpeg(String fileName, int targetBytes) {
    final file = File('${originDir.path}/$fileName');
    if (!file.existsSync() || file.lengthSync() < targetBytes - 50000) {
      final padNeeded = targetBytes - srcBytes.length;
      final bytesBuilder = BytesBuilder();
      // SOI
      bytesBuilder.add(srcBytes.sublist(0, 2));

      int remaining = padNeeded;
      const chunkSize = 65000;
      while (remaining > 0) {
        final cur = remaining > chunkSize ? chunkSize : remaining;
        final len = cur + 2;
        bytesBuilder.addByte(0xFF);
        bytesBuilder.addByte(0xFE);
        bytesBuilder.addByte((len >> 8) & 0xFF);
        bytesBuilder.addByte(len & 0xFF);
        bytesBuilder.add(Uint8List(cur));
        remaining -= (cur + 4);
      }
      bytesBuilder.add(srcBytes.sublist(2));
      file.writeAsBytesSync(bytesBuilder.toBytes());
      print('Created $fileName (${(file.lengthSync() / (1024 * 1024)).toStringAsFixed(1)} MB)');
    }
  }

  ensureJpeg('image-3mb.jpg', 3 * 1024 * 1024);
  ensureJpeg('image-5mb.jpg', 5 * 1024 * 1024);
  ensureJpeg('image-10mb.jpg', 10 * 1024 * 1024);
  ensureJpeg('sample-image.jpg', 1033330);

  // Ensure 15MB MP4 Video
  final video15Mb = File('${originDir.path}/video-15mb.mp4');
  if (!video15Mb.existsSync() || video15Mb.lengthSync() < 14 * 1024 * 1024) {
    const b64 = 'AAAAHGZ0eXBpc29tAAAAAGlzb21tcDQyAAACAG1vb3YAAABsbXZoZAAAAADa0rKx2tKysQAAA+gAAAAAAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAABidHJhawAAAFx0a2hkAAAAA9rSsrHa0rKxAAAAAQAAAAEAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACBtZGlhAAAAIG1kaGQAAAAA2tKysdrSsrEAAAPoAAAAAAAc5AAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABDb3JlIE1lZGlhIFZpZGVvAAAAAfFtaW5mAAAAFHZtaGQAAAABAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAHJc3RibAAAAHtzdHNkAAAAAAAAAAEAAABrYXZjMQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAEAAQASAAAAEgAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD//+AAAAF2F2Y0MBVQAO/+EAHmRAB6zSA3mCmgAALu4AAAeTAkGgAAAAAAhwEAACAgAAABhhc3R0cwAAAAAAAAABAAAAAQAAA+gAAAAUAHN0c3MAAAAAAAAAAQAAAAEAAAAUc3RzYwAAAAAAAAABAAAAAQAAAAEAAAABAAAAHHN0c3oAAAAAAAAAAAAAAAEAAAAYAAAAFXN0Y28AAAAAAAAAAQAAACQAAAB6bWRhdAAAABhkYXRhAAAAAA==';
    final baseMp4 = base64Decode(b64);
    const targetSize = 15 * 1024 * 1024;
    final padSize = targetSize - baseMp4.length;

    final builder = BytesBuilder();
    builder.add(baseMp4.sublist(0, 28)); // ftyp
    // Box size (big endian)
    final boxSizeHeader = Uint8List(4)
      ..buffer.asByteData().setUint32(0, padSize, Endian.big);
    builder.add(boxSizeHeader);
    builder.add(utf8.encode('free'));
    builder.add(Uint8List(padSize - 8));
    builder.add(baseMp4.sublist(28));

    video15Mb.writeAsBytesSync(builder.toBytes());
    print('Created video-15mb.mp4 (${(video15Mb.lengthSync() / (1024 * 1024)).toStringAsFixed(1)} MB)');
  }
}

// ---------------------------------------------------------------------------
// Origin Server (Simulates High Latency Remote Origin Server)
// ---------------------------------------------------------------------------
Future<void> handleOriginRequest(HttpRequest request) async {
  final stopwatch = Stopwatch()..start();

  request.response.headers.add('Access-Control-Allow-Origin', '*');
  request.response.headers.add('Access-Control-Expose-Headers', '*');
  request.response.headers.add('Access-Control-Allow-Headers', '*');

  if (request.method == 'OPTIONS') {
    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
    return;
  }

  // Artificial geographic latency (cross-continent round trip)
  await Future.delayed(Duration(milliseconds: ORIGIN_SIMULATED_LATENCY_MS));

  final filePath = '${originDir.path}${request.uri.path}';
  final file = File(filePath);

  if (!file.existsSync()) {
    request.response.statusCode = HttpStatus.notFound;
    request.response.write('File Not Found on Origin: ${request.uri.path}');
    await request.response.close();
    return;
  }

  final fileSize = file.lengthSync();
  final mimeType = getMimeType(filePath);
  request.response.headers.contentType = ContentType.parse(mimeType);
  request.response.headers.add('Accept-Ranges', 'bytes');
  request.response.headers.add('X-Served-By', 'Origin-Server-Frankfurt');
  request.response.headers.add('X-Simulated-Origin-Latency', '${ORIGIN_SIMULATED_LATENCY_MS}ms');

  // Handle Range Header (HTTP 206 Partial Content)
  final rangeHeader = request.headers.value('range');
  if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
    final rangeSpec = rangeHeader.substring(6);
    final parts = rangeSpec.split('-');
    final start = int.tryParse(parts[0]) ?? 0;
    final end = (parts.length > 1 && parts[1].isNotEmpty)
        ? (int.tryParse(parts[1]) ?? fileSize - 1)
        : fileSize - 1;

    final length = end - start + 1;
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.add('Content-Range', 'bytes $start-$end/$fileSize');
    request.response.headers.contentLength = length;

    final raf = file.openSync();
    raf.setPositionSync(start);
    request.response.add(raf.readSync(length));
    raf.closeSync();

    stopwatch.stop();
    print('[ORIGIN] 206 Partial Content: ${request.uri.path} (bytes $start-$end) in ${stopwatch.elapsedMilliseconds}ms');
    await request.response.close();
    return;
  }

  request.response.statusCode = HttpStatus.ok;
  request.response.headers.contentLength = fileSize;
  await request.response.addStream(file.openRead());
  stopwatch.stop();
  print('[ORIGIN] 200 OK: ${request.uri.path} (${(fileSize/1024).round()} KB) in ${stopwatch.elapsedMilliseconds}ms');
  await request.response.close();
}

// ---------------------------------------------------------------------------
// CDN Edge Server (Reverse Proxy with Disk & Range Caching)
// ---------------------------------------------------------------------------
Future<void> handleCdnRequest(HttpRequest request) async {
  final stopwatch = Stopwatch()..start();

  request.response.headers.add('Access-Control-Allow-Origin', '*');
  request.response.headers.add('Access-Control-Expose-Headers', '*');
  request.response.headers.add('Access-Control-Allow-Headers', '*');

  if (request.method == 'OPTIONS') {
    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
    return;
  }

  final path = request.uri.path;

  // 1. Dashboard UI
  if (path == '/' || path == '/index.html') {
    request.response.headers.contentType = ContentType.html;
    request.response.write(getDashboardHtml());
    await request.response.close();
    return;
  }

  // 2. Stats API
  if (path == '/api/stats') {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({
      'totalRequests': totalRequests,
      'cacheHits': cacheHits,
      'cacheMisses': cacheMisses,
      'hitRatio': totalRequests == 0 ? '0%' : '${((cacheHits / totalRequests) * 100).toStringAsFixed(1)}%',
      'cachedFiles': cacheDir.existsSync() ? cacheDir.listSync().length : 0,
    }));
    await request.response.close();
    return;
  }

  // 3. Purge Cache API
  if (path == '/api/clear-cache') {
    if (cacheDir.existsSync()) {
      for (var f in cacheDir.listSync()) {
        f.deleteSync(recursive: true);
      }
    }
    cacheHits = 0;
    cacheMisses = 0;
    totalRequests = 0;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'status': 'cleared'}));
    await request.response.close();
    print('[CDN] Cache purged successfully.');
    return;
  }

  // 4. Direct Origin Bypass (for latency comparison testing)
  if (path.startsWith('/origin-direct/')) {
    final mediaName = path.replaceFirst('/origin-direct/', '');
    final originUri = Uri.parse('http://127.0.0.1:$ORIGIN_PORT/$mediaName');
    await proxyToOriginDirect(request, originUri, stopwatch: stopwatch);
    return;
  }

  // 5. CDN Caching Proxy for Media
  if (path.startsWith('/media/')) {
    totalRequests++;
    final mediaName = path.replaceFirst('/media/', '');
    final cachedFile = File('${cacheDir.path}/$mediaName');

    if (cachedFile.existsSync()) {
      // ⚡ CACHE HIT! Serve directly from local Edge disk/RAM
      cacheHits++;
      stopwatch.stop();
      serveCachedFile(request, cachedFile, mediaName, stopwatch.elapsedMilliseconds);
      return;
    } else {
      // 🐢 CACHE MISS! Fetch complete file from origin, store in edge cache, then serve
      cacheMisses++;
      final originUri = Uri.parse('http://127.0.0.1:$ORIGIN_PORT/$mediaName');
      await fetchFullAndCache(request, originUri, cachedFile, mediaName, stopwatch);
      return;
    }
  }

  request.response.statusCode = HttpStatus.notFound;
  request.response.write('Not Found');
  await request.response.close();
}

// ---------------------------------------------------------------------------
// Serve Cached File with Full Range (HTTP 206) & HTTP 200 Support
// ---------------------------------------------------------------------------
Future<void> serveCachedFile(
  HttpRequest request,
  File cachedFile,
  String mediaName,
  int hitLatencyMs,
) async {
  final fileSize = cachedFile.lengthSync();
  final mimeType = getMimeType(cachedFile.path);

  request.response.headers.contentType = ContentType.parse(mimeType);
  request.response.headers.add('Accept-Ranges', 'bytes');
  request.response.headers.add('X-Cache-Status', 'HIT');
  request.response.headers.add('X-CDN-Edge-Location', 'Local-Edge-PoP');
  request.response.headers.add('X-Response-Time-Ms', '$hitLatencyMs');
  request.response.headers.add('Cache-Control', 'public, max-age=31536000, immutable');

  final rangeHeader = request.headers.value('range');
  if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
    final rangeSpec = rangeHeader.substring(6);
    final parts = rangeSpec.split('-');
    final start = int.tryParse(parts[0]) ?? 0;
    final end = (parts.length > 1 && parts[1].isNotEmpty)
        ? (int.tryParse(parts[1]) ?? fileSize - 1)
        : fileSize - 1;
    final length = end - start + 1;

    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.add('Content-Range', 'bytes $start-$end/$fileSize');
    request.response.headers.contentLength = length;

    final raf = cachedFile.openSync();
    raf.setPositionSync(start);
    request.response.add(raf.readSync(length));
    raf.closeSync();

    print('[CDN HIT] ⚡ 206 Partial Content: $mediaName (bytes $start-$end) served from Edge Cache in ${hitLatencyMs}ms');
  } else {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentLength = fileSize;
    await request.response.addStream(cachedFile.openRead());
    print('[CDN HIT] ⚡ 200 OK: $mediaName (${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB) served from Edge Cache in ${hitLatencyMs}ms');
  }

  await request.response.close();
}

// ---------------------------------------------------------------------------
// Cache Miss: Fetch FULL File from Origin -> Save to Disk -> Serve Request
// ---------------------------------------------------------------------------
Future<void> fetchFullAndCache(
  HttpRequest clientReq,
  Uri originUri,
  File cacheFile,
  String mediaName,
  Stopwatch stopwatch,
) async {
  final client = HttpClient();
  try {
    // Edge requests the COMPLETE file from Origin (without Range) to populate cache
    final originReq = await client.getUrl(originUri);
    final originResp = await originReq.close();

    if (originResp.statusCode != HttpStatus.ok) {
      clientReq.response.statusCode = originResp.statusCode;
      await clientReq.response.addStream(originResp);
      await clientReq.response.close();
      return;
    }

    // Stream download directly to local cache file
    final sink = cacheFile.openWrite();
    await originResp.pipe(sink);

    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;
    final fileSize = cacheFile.lengthSync();

    print('[CDN MISS] 🐢 Fetched from Origin: $mediaName (${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB) in ${elapsed}ms -> Saved to Edge Cache');

    // Now serve the client request directly from the freshly written cache file!
    await serveCachedFile(clientReq, cacheFile, mediaName, elapsed);
  } catch (e) {
    clientReq.response.statusCode = HttpStatus.badGateway;
    clientReq.response.write('Error connecting to Origin: $e');
    await clientReq.response.close();
  } finally {
    client.close();
  }
}

// ---------------------------------------------------------------------------
// Proxy Directly (Origin Bypass for Latency Comparison)
// ---------------------------------------------------------------------------
Future<void> proxyToOriginDirect(
  HttpRequest clientReq,
  Uri originUri, {
  required Stopwatch stopwatch,
}) async {
  final client = HttpClient();
  try {
    final originReq = await client.getUrl(originUri);
    final range = clientReq.headers.value('range');
    if (range != null) originReq.headers.add('range', range);

    final originResp = await originReq.close();

    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;

    clientReq.response.statusCode = originResp.statusCode;
    originResp.headers.forEach((name, values) {
      for (var v in values) {
        clientReq.response.headers.add(name, v);
      }
    });

    clientReq.response.headers.add('X-Cache-Status', 'BYPASS');
    clientReq.response.headers.add('X-Response-Time-Ms', '$elapsed');

    await originResp.pipe(clientReq.response);
    print('[ORIGIN DIRECT] 🌐 Direct request: ${originUri.path} in ${elapsed}ms');
  } catch (e) {
    clientReq.response.statusCode = HttpStatus.badGateway;
    clientReq.response.write('Bypass Error: $e');
    await clientReq.response.close();
  } finally {
    client.close();
  }
}

String getMimeType(String path) {
  final ext = path.split('.').last.toLowerCase();
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'svg':
      return 'image/svg+xml';
    case 'webp':
      return 'image/webp';
    case 'mp4':
      return 'video/mp4';
    case 'webm':
      return 'video/webm';
    default:
      return 'application/octet-stream';
  }
}

// ---------------------------------------------------------------------------
// Modern Interactive HTML Testing Dashboard
// ---------------------------------------------------------------------------
String getDashboardHtml() {
  return '''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>CDN Latency & Large Media Test Lab (3MB, 5MB, 10MB, 15MB)</title>
  <style>
    :root {
      --bg: #0b1120;
      --card: #1e293b;
      --border: #334155;
      --accent: #38bdf8;
      --green: #22c55e;
      --yellow: #f59e0b;
      --red: #ef4444;
      --text: #f8fafc;
      --text-dim: #94a3b8;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    body { background: var(--bg); color: var(--text); padding: 24px; }
    .header { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--border); padding-bottom: 16px; margin-bottom: 24px; }
    .header h1 { font-size: 22px; display: flex; align-items: center; gap: 10px; }
    .badge { background: #0284c7; color: white; padding: 4px 10px; border-radius: 999px; font-size: 12px; }
    .btn { background: #2563eb; color: white; border: none; padding: 8px 14px; border-radius: 6px; cursor: pointer; font-weight: 600; font-size: 13px; transition: 0.2s; }
    .btn:hover { background: #1d4ed8; }
    .btn-outline { background: transparent; border: 1px solid var(--border); color: var(--text); }
    .btn-outline:hover { background: #334155; }
    .btn-danger { background: var(--red); }
    .btn-danger:hover { background: #dc2626; }

    .stats-row { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin-bottom: 24px; }
    .stat-card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 16px; text-align: center; }
    .stat-card .val { font-size: 28px; font-weight: 700; color: var(--accent); margin-top: 4px; }
    .stat-card .lbl { font-size: 12px; color: var(--text-dim); text-transform: uppercase; }

    .section-title { font-size: 18px; margin: 24px 0 12px 0; color: var(--accent); display: flex; align-items: center; gap: 8px; }

    .media-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 20px; margin-bottom: 24px; }
    .card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 18px; display: flex; flex-direction: column; justify-content: space-between; }
    .card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
    .card-title { font-size: 15px; font-weight: 600; display: flex; align-items: center; gap: 6px; }
    .size-tag { background: #334155; font-size: 12px; padding: 2px 8px; border-radius: 4px; color: #38bdf8; }

    .preview-box { background: #000; border-radius: 6px; height: 180px; overflow: hidden; display: flex; align-items: center; justify-content: center; position: relative; margin-bottom: 12px; }
    .preview-box img, .preview-box video { max-width: 100%; max-height: 100%; object-fit: contain; }

    .metric-badge { position: absolute; bottom: 8px; right: 8px; padding: 4px 10px; border-radius: 4px; font-weight: 700; font-size: 12px; background: rgba(0,0,0,0.85); }
    .hit { color: var(--green); border: 1px solid var(--green); }
    .miss { color: var(--yellow); border: 1px solid var(--yellow); }
    .bypass { color: var(--red); border: 1px solid var(--red); }

    .metric-table { background: #0b1120; border-radius: 6px; padding: 10px; font-size: 12px; margin-bottom: 12px; }
    .metric-row { display: flex; justify-content: space-between; padding: 4px 0; border-bottom: 1px solid #1e293b; }
    .metric-row:last-child { border-bottom: none; }

    .btn-group { display: flex; gap: 8px; }
    .btn-group .btn { flex: 1; text-align: center; text-decoration: none; display: inline-block; }

    .log-box { background: #070c18; border: 1px solid var(--border); border-radius: 6px; padding: 12px; height: 200px; overflow-y: auto; font-family: monospace; font-size: 12px; line-height: 1.6; }
    .log-hit { color: var(--green); }
    .log-miss { color: var(--yellow); }
    .log-origin { color: var(--red); }
  </style>
</head>
<body>

  <div class="header">
    <div>
      <h1>🚀 CDN Latency & Large Media Test Lab <span class="badge">Multi-Asset</span></h1>
      <p style="color: var(--text-dim); font-size: 13px; margin-top: 4px;">
        Origin Server (+250ms simulated remote trip) vs CDN Edge Cache (0–5ms disk/RAM delivery)
      </p>
    </div>
    <div style="display: flex; gap: 8px;">
      <button class="btn btn-danger" onclick="clearCache()">🗑️ Flush CDN Cache</button>
    </div>
  </div>

  <div class="stats-row">
    <div class="stat-card">
      <div class="lbl">Total Requests</div>
      <div class="val" id="stat-total">0</div>
    </div>
    <div class="stat-card">
      <div class="lbl">Cache Hits (Instant)</div>
      <div class="val" id="stat-hits" style="color: var(--green);">0</div>
    </div>
    <div class="stat-card">
      <div class="lbl">Cache Misses (Origin Trip)</div>
      <div class="val" id="stat-misses" style="color: var(--yellow);">0</div>
    </div>
    <div class="stat-card">
      <div class="lbl">Hit Ratio</div>
      <div class="val" id="stat-ratio">0%</div>
    </div>
  </div>

  <!-- Large Images Section -->
  <div class="section-title">🖼️ High-Resolution Images (3 MB, 5 MB, 10 MB)</div>
  <div class="media-grid">

    <!-- 3 MB Card -->
    <div class="card">
      <div class="card-header">
        <span class="card-title">🖼️ Image Sample <span class="size-tag">3.0 MB</span></span>
      </div>
      <div class="preview-box">
        <img id="img-3mb" src="/media/image-3mb.jpg" alt="3MB Image" />
        <div id="badge-3mb" class="metric-badge hit">Ready</div>
      </div>
      <div class="metric-table">
        <div class="metric-row"><span>Download Time:</span><strong id="time-3mb">-</strong></div>
        <div class="metric-row"><span>Transfer Speed:</span><strong id="speed-3mb">-</strong></div>
        <div class="metric-row"><span>Cache Status:</span><strong id="status-3mb">-</strong></div>
      </div>
      <div class="btn-group">
        <button class="btn" onclick="testMedia('image-3mb.jpg', 'img-3mb', 'badge-3mb', 'time-3mb', 'speed-3mb', 'status-3mb', 3)">⚡ Test via CDN</button>
        <a class="btn btn-outline" href="/media/image-3mb.jpg" download="image-3mb.jpg">📥 Download</a>
      </div>
    </div>

    <!-- 5 MB Card -->
    <div class="card">
      <div class="card-header">
        <span class="card-title">🖼️ Image Sample <span class="size-tag">5.0 MB</span></span>
      </div>
      <div class="preview-box">
        <img id="img-5mb" src="/media/image-5mb.jpg" alt="5MB Image" />
        <div id="badge-5mb" class="metric-badge hit">Ready</div>
      </div>
      <div class="metric-table">
        <div class="metric-row"><span>Download Time:</span><strong id="time-5mb">-</strong></div>
        <div class="metric-row"><span>Transfer Speed:</span><strong id="speed-5mb">-</strong></div>
        <div class="metric-row"><span>Cache Status:</span><strong id="status-5mb">-</strong></div>
      </div>
      <div class="btn-group">
        <button class="btn" onclick="testMedia('image-5mb.jpg', 'img-5mb', 'badge-5mb', 'time-5mb', 'speed-5mb', 'status-5mb', 5)">⚡ Test via CDN</button>
        <a class="btn btn-outline" href="/media/image-5mb.jpg" download="image-5mb.jpg">📥 Download</a>
      </div>
    </div>

    <!-- 10 MB Card -->
    <div class="card">
      <div class="card-header">
        <span class="card-title">🖼️ Image Sample <span class="size-tag">10.0 MB</span></span>
      </div>
      <div class="preview-box">
        <img id="img-10mb" src="/media/image-10mb.jpg" alt="10MB Image" />
        <div id="badge-10mb" class="metric-badge hit">Ready</div>
      </div>
      <div class="metric-table">
        <div class="metric-row"><span>Download Time:</span><strong id="time-10mb">-</strong></div>
        <div class="metric-row"><span>Transfer Speed:</span><strong id="speed-10mb">-</strong></div>
        <div class="metric-row"><span>Cache Status:</span><strong id="status-10mb">-</strong></div>
      </div>
      <div class="btn-group">
        <button class="btn" onclick="testMedia('image-10mb.jpg', 'img-10mb', 'badge-10mb', 'time-10mb', 'speed-10mb', 'status-10mb', 10)">⚡ Test via CDN</button>
        <a class="btn btn-outline" href="/media/image-10mb.jpg" download="image-10mb.jpg">📥 Download</a>
      </div>
    </div>

  </div>

  <!-- 15 MB Video Section -->
  <div class="section-title">🎥 Video Streaming & Range Seeking (15 MB)</div>
  <div class="media-grid" style="grid-template-columns: 2fr 1fr;">

    <div class="card">
      <div class="card-header">
        <span class="card-title">🎥 15MB MP4 Video Player <span class="size-tag">15.0 MB</span></span>
        <span style="font-size: 12px; color: var(--accent);">Accept-Ranges: bytes (HTTP 206)</span>
      </div>
      <div class="preview-box" style="height: 220px;">
        <video id="test-video" controls src="/media/video-15mb.mp4"></video>
        <div id="badge-video" class="metric-badge hit">Range 206 Ready</div>
      </div>
      <div class="btn-group">
        <button class="btn" onclick="reloadVideo()">⚡ Reload Video (Test Seeking)</button>
        <a class="btn btn-outline" href="/media/video-15mb.mp4" download="video-15mb.mp4">📥 Download 15MB Video (CDN)</a>
        <a class="btn btn-outline" style="border-color: #ef4444; color: #ef4444;" href="/origin-direct/video-15mb.mp4" download="video-origin.mp4">🌐 Download Direct Origin</a>
      </div>
    </div>

    <div class="card">
      <div class="card-header">
        <span class="card-title">⚡ Video CDN Caching Workflow</span>
      </div>
      <div class="metric-table" style="font-size: 13px; line-height: 1.8;">
        <div><strong>1. First Playback (MISS):</strong></div>
        <div style="color: var(--yellow); margin-bottom: 8px;">Edge pulls 15MB once from origin & saves to SSD.</div>
        
        <div><strong>2. Subsequent Seeks (HIT):</strong></div>
        <div style="color: var(--green); margin-bottom: 8px;">Edge answers byte ranges in 0–2ms. No origin delay!</div>

        <div><strong>3. Result:</strong></div>
        <div style="color: var(--accent);">Zero buffering & instant scrubbing for all users.</div>
      </div>
    </div>

  </div>

  <!-- Real-time Traffic Log -->
  <div class="section-title">📋 Live Edge Traffic & Caching Log</div>
  <div class="log-box" id="log-box"></div>

  <script>
    function addLog(msg, type = 'hit') {
      const box = document.getElementById('log-box');
      const time = new Date().toLocaleTimeString();
      const line = document.createElement('div');
      line.className = 'log-' + type;
      line.innerText = '[' + time + '] ' + msg;
      box.prepend(line);
    }

    async function updateStats() {
      try {
        const res = await fetch('/api/stats');
        const data = await res.json();
        document.getElementById('stat-total').innerText = data.totalRequests;
        document.getElementById('stat-hits').innerText = data.cacheHits;
        document.getElementById('stat-misses').innerText = data.cacheMisses;
        document.getElementById('stat-ratio').innerText = data.hitRatio;
      } catch (e) {}
    }

    async function testMedia(file, imgId, badgeId, timeId, speedId, statusId, sizeMb) {
      const badge = document.getElementById(badgeId);
      badge.innerText = 'Downloading...';
      badge.className = 'metric-badge';

      const t0 = performance.now();
      const res = await fetch('/media/' + file);
      const blob = await res.blob();
      const t1 = performance.now();
      const elapsed = Math.round(t1 - t0);

      const cacheStatus = res.headers.get('X-Cache-Status') || (elapsed < 100 ? 'HIT' : 'MISS');
      const mbps = (sizeMb / (elapsed / 1000)).toFixed(1);

      document.getElementById(imgId).src = URL.createObjectURL(blob);
      document.getElementById(timeId).innerText = elapsed + ' ms';
      document.getElementById(speedId).innerText = mbps + ' MB/s';
      document.getElementById(statusId).innerText = cacheStatus === 'HIT' ? '⚡ CACHE HIT (Local Edge)' : '🐢 CACHE MISS (From Origin)';
      document.getElementById(statusId).style.color = cacheStatus === 'HIT' ? 'var(--green)' : 'var(--yellow)';

      if (cacheStatus === 'HIT') {
        badge.innerText = '⚡ ' + elapsed + ' ms (HIT)';
        badge.className = 'metric-badge hit';
        addLog('GET /media/' + file + ' (' + sizeMb + 'MB) -> 200 OK [' + elapsed + 'ms, ' + mbps + ' MB/s] ⚡ CACHE HIT', 'hit');
      } else {
        badge.innerText = '🐢 ' + elapsed + ' ms (MISS)';
        badge.className = 'metric-badge miss';
        addLog('GET /media/' + file + ' (' + sizeMb + 'MB) -> 200 OK [' + elapsed + 'ms] 🐢 CACHE MISS (Saved to Edge)', 'miss');
      }
      updateStats();
    }

    async function clearCache() {
      await fetch('/api/clear-cache');
      addLog('🗑️ Edge Cache Purged. Next calls will be MISS (fetching from origin).', 'miss');
      updateStats();
    }

    function reloadVideo() {
      const v = document.getElementById('test-video');
      v.src = '/media/video-15mb.mp4?seek=' + Date.now();
      v.play();
      addLog('Video stream started with HTTP 206 Accept-Ranges...', 'hit');
    }

    // Auto-update stats every 2 seconds
    setInterval(updateStats, 2000);
    updateStats();
  </script>
</body>
</html>
''';
}
