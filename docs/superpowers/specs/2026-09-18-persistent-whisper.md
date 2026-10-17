# Persistent local Whisper
Approved direction: keep Whisper warm outside the app process.
Use a bundled C helper and private stdin/stdout pipes; no HTTP listener or new data persistence. The helper loads GGML backends and one model, then accepts bounded 16 kHz mono float PCM requests. It returns bounded UTF-8 results.
The Swift client serializes requests on a background queue and shares one helper across service instances (preview and final). Model/language changes replace the helper. Cancellation discards the caller's result promptly without killing a healthy warm helper; canceled queued work is skipped. Startup and inference have separate bounded deadlines; failure invalidates the helper, and the next request can restart.
The existing CLI remains available when no bundled helper is present or input cannot use the helper. Native Whisper code must never execute in the app.
First-use model loading is expected. Subsequent requests must reuse the same PID/model. Synthetic process tests cover reuse, configuration changes, cancellation, timeout, malformed responses and crash recovery. A native synthetic-audio smoke test validates actual backend loading, followed by make check, a build and local reinstall. Live microphone verification is user-driven.

Compatibility: vendor upstream 1.8.6 headers and license to make clean builds deterministic. Verify the loaded runtime version before any by-value struct API calls; unsupported versions use CLI fallback. The helper alone receives disable-library-validation so hardened-runtime builds can load Homebrew libraries; the main app's entitlements are unchanged.
Automatic language uses language="auto" with detect_language=false so Whisper detects and then transcribes, rather than returning detection-only.
