# Persistent Whisper Implementation Plan
Goal: prevent per-request model reloads while isolating native crashes.
Architecture: bundled C helper with framed private pipes; a shared Swift client owns one helper and serializes work.
Tech stack: existing Swift/Foundation, AVFoundation, C bridge and Make.
Spec: ../specs/2026-09-18-persistent-whisper.md

- [x] Add deterministic helper-process fixtures and failing reuse/crash/cancellation/deadline tests.
- [x] Add background Swift client, connection reuse and bounded protocol handling.
- [x] Add C helper, explicit backend loading and build/bundle integration.
- [x] Route both PCM previews and final WAV audio to the shared helper; remove in-app native sessions.
- [x] Run synthetic native helper smoke test and deterministic regressions; make check and git diff --check.
- [ ] Build, install, launch, and report remaining microphone verification.
