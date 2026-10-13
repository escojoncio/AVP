# AVP — Work plan

Native visionOS app that runs **Half-Life: Alyx** (Steam's native ARM64 Linux build) on
**Apple Vision Pro**, with no PC and no Mac step. Graphics on **VPKEngine** (own Vulkan → Metal
driver, `escojoncio/VPKEngine`), antialiasing with **VPKTAA**.

Status: plan settled (2026-10-13), implementation starting.

---

## 1. Principles

- **Everything on the headset, inside the IPA.** No installer, no Mac. The app signs in to
  Steam, downloads, converts, signs, pre-caches and launches.
- **The IPA carries no Valve code or data.** Every game file comes from the player's own Steam
  account onto their own headset.
- **No JIT, ever.** Converted libraries are signed on device (same mechanism as
  VisionQuestPro: `vp_codesign` with the player's imported `.p12`).
- **The app rules over the game.** Every setting chosen in the app is enforced on every launch,
  whatever the game's own config files, saved options or Steam Cloud settings say (see §6).
- **All settings live in the app UI**, never in text files. All diagnostics go to the log.
- Bundle id `com.kdt.livecontainer` (shared slot with VisionQuestPro / AstroVisionPro).

## 2. Official Steam connection (from the app)

Swift Steam client (adapted from Glovebox's SteamLauncherKit, MIT):
- Official CM connection (websocket), password encrypted with Steam's RSA key + Steam Guard
  (mobile approval / code). Only the refresh token is stored (Keychain). Password never stored.
- **Ownership check**: licences × PICS packages for app 546560. Steam also refuses depot keys to
  accounts that don't own the game, so nothing can be downloaded without an original copy.
- Download from Steam's CDN, pinned manifests (tested build), every chunk verified (AES +
  LZMA/zstd + Adler-32, per-file SHA-1), resumable journal, background URLSession.
  - 546561 content (~67 GB).
  - 546564 Linux binaries: **only `linuxsteamrtarm64`** (real ELF files, not placeholders —
    we convert them on device). x86-64 and Windows binaries are skipped.
- Steam Cloud save sync (download-then-upload, backups before replacing, never propagates
  deletions).

## 3. Preparation on device (replaces Glovebox's Mac build)

All pure data transforms, ported from Glovebox's Python to C/Swift:
1. **Runtime libraries**: 17 Debian arm64 `.deb` pinned by SHA-256 (libstdc++, libgcc_s,
   OpenSSL, GLib, …) downloaded from Debian, `ar` + `data.tar.xz/zst` extracted → 22 `.so`.
2. **Conversion**: every ELF of `bin/linuxsteamrtarm64`, `hlvr/bin/linuxsteamrtarm64`, `hlvr`
   and the runtime libs (~89) → `klepton_ld` in process (VisionQuestPro's INPROC build, with
   Glovebox's extra x18 veneers: casp pairs, `blr/adr x18`, stp/ldp writeback).
3. **Signing**: `vp_codesign` with the imported `.p12`; re-sign if the certificate changes.
4. **Pipeline list**: rebuild the Fossilize database from the game's own `.vcs` shaders using a
   recipe with offsets only (no shader code in the repo), port of `engine/pipelines.py`.
5. **Pre-compile** every pipeline through VPKEngine into its `MTLBinaryArchive` before the first
   play (progress bar). New pipelines met in play are recorded and compiled for the next launch.
   Goal: **zero shader stutter, first session included**.
6. Outputs live in the user folder (Files): `AVP/game`, `AVP/cache` (converted + signed libs,
   pipelines, archives), `AVP/logs`. Survives app reinstall.

## 4. Runtime (Klepton fork owned by AVP)

AVP keeps its own Klepton copy (VisionQuestPro's on-device fork) merged with Glovebox's Linux
pieces; VisionQuestPro is not touched.
- glibc personality (`runtime/linux`): ELF TLS/TLSDESC, SysV sem, eventfd + epoll fast path,
  Linux↔Darwin signal numbers, 4K `mprotect` on 16K pages, BFS `dlsym`, `/proc/self/exe`.
- LuaJIT (GC64, interpreter only) and V8 `--jitless`; SDL3 + sdl2-compat (offscreen video).
- In-process Steam networking loopback; Steam API shim (language from the app).
- OpenVR shim on Compositor Services + ARKit: projections, pose prediction, PS VR2 Sense as
  Touch (31-bone skeleton from capacitive touch, Core Haptics), real GPU frame time.
- Memory: increased memory limit, big allocations via mmap, eye-image retirement,
  real `VK_EXT_memory_budget` from `os_proc_available_memory`.
- Known game fixes: NPC eyeball shader UBO guard, minmax sampler fake.

## 5. Graphics: VPKEngine

### 5.1 Gaps to close for Source 2 (in `gpu/metal2` + SPIR-V translator)
1. Dynamically indexed descriptor arrays (bindless) → argument buffers.
2. Vulkan 1.3 surface: Vulkan11/12/13 features/properties, dynamic rendering (exists),
   depth/stencil resolve, maintenance2, image_format_list, separate_stencil_usage,
   swapchain_mutable_format, host_image_copy, dynamic_rendering_local_read (framebuffer fetch).
3. Timeline semaphores, sync2, per-submit fences (no device-wide waits).
4. Timestamp queries (MTLCounterSet) → auto-fidelity works.
5. 16/64-bit integer types, MS texture reads, `vkCmdResolveImage`.
6. Foveation with `MTLRasterizationRateMap` (fixed, adjustable). No MetalFX (unsuitable for VR).
7. Cross-submission ordering (build 24, patch 0029): with untracked resources every encoder of a
   command buffer must be ordered after the previous command buffer (Vulkan barriers cover all
   earlier submissions); 12 command buffers in flight stays the default.

**Diagnostic switch (hidden, temporary): MoltenVK.** Only to isolate CPU/OpenVR/signing bugs from
VPKEngine bugs while the gaps are closed. Not a play mode; removed once VPKEngine boots Alyx.

### 5.2 VPKTAA, fully native
**Decision (build 21): the game renders with its own MSAA 4x (the reference picture) and VPKTAA works
only on the foveated periphery.** Phase 1 (done): a spatial reconstruction in the compositor's unwarp
(`kl_eye_recon`: clamped Catmull-Rom + smoothing along the local edge) wherever the foveated eye is
magnified; the sharp centre is never touched (its quality is the render resolution). Phase 2: temporal
accumulation in the periphery only, with jitter and camera motion from depth + pose. The inputs it
needs, from the research below:
- **Depth**: the eye depth the game renders (already captured for the compositor).
- **Camera motion**: from depth + previous/current eye pose (exact for static geometry).
- **Object motion**: VPKEngine keeps the previous frame's copy of each draw's transform data
  (UBO/push constant ranges feeding the position output) and the translated vertex shader
  computes the position twice (current + previous) → per-pixel motion vectors written to an
  extra render target in the main pass. Exact for skinned and moving objects.
- **Jitter**: sub-pixel Halton offsets injected into the projection the OpenVR shim returns.
- (Superseded) game MSAA off with VPKTAA: the 1x game could not foveate its colour-only eye passes
  (build 19). The temporal resolve still runs on its own queue (as in VisionQuestPro) when it returns.

## 6. The app rules over the game
Enforced on **every** launch, overriding game files, in-game options and Steam Cloud:
- `video2.txt` and `vr_fidelity_levels_override.csv` written from app settings (Vendor/Device ID
  matching VPKEngine so the game doesn't discard them).
- Launch convars + Lua hooks at `player_activate` that re-apply them if the game changes them.
- OpenVR shim reports the render size, FOV and refresh the app chose.
- VPKEngine enforces anisotropy and texture cap regardless of what the game asks; the game's MSAA is
  forced to 4x (convars); foveation is Klepton's rate map on every MSAA eye pass.

## 7. Settings menu (in the app)
Render resolution (% / native Vision Pro) · dynamic resolution on/off + range · texture quality
(pool, cap) · foveation (off / M2 / M5: 60° sharp zone 10° below the forward axis, periphery quality 10–65 % /
custom: sharp zone, periphery, transition) · VPKTAA periphery (on, intensity, sharpness) · anisotropy (x16 default) · language (system if
available, else English; voice always English) · FPS HUD · movement defaults · diagnostics
captures.

## 8. Phases
1. Repo scaffold from VisionQuestPro (app, Klepton fork, CI `[build]`-only, VPKEngine checkout).
2. Merge Glovebox Linux/OpenVR/x18 pieces into the Klepton fork; LuaJIT/SDL/Fossilize in CI.
3. Steam client + download + Cloud.
4. Preparation pipeline (debs, conversion, signing, pipelines recipe).
5. Launch + menu + enforcement; first device test (MoltenVK diagnostic switch available).
6. VPKEngine gaps (§5.1), then native VPKTAA (§5.2), foveation.
7. Polish: stutter reports in the log, performance HUD, memory tuning.

## 9. Credits
Glovebox (MIT) · Klepton by Max Thomas (MIT) · Fossilize, LuaJIT, SDL, Debian runtime libs
(own licences) · OpenVR headers (BSD-3).
