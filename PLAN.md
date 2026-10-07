# AVP — Work plan

Port of **Half-Life: Alyx** (Steam Frame's native ARM64 build) to **Apple Vision Pro**
(visionOS, main target: Vision Pro M2), using a Klepton-style approach.

> Status: **planning**. There is no code yet. This document collects everything that has
> been decided and researched so work can start without repeating the research.

---

## 1. Goal

A visionOS app (this project's IPA) that does **everything on the Vision Pro itself**,
with no steps on a PC:

1. Sign in to Steam (with Steam Guard / 2FA if needed).
2. Tap **Download** and the app fetches the game from the user's own account
   (content + ARM64 binaries) into a **user-accessible folder**.
3. The app adapts the files so they launch with this project, including a
   **full shader pre-cache**.
4. A **launch menu** lets the user tune resolution, foveation, anti-aliasing and upscaling.
5. Tap **Play**.

Main requirement: **good performance and sharpness on Vision Pro M2**, with foveation
similar to Steam Frame's (sharp centre, reduced periphery) and adjustable.

---

## 2. Verified facts about the game

### Depots (app 546560)
| Depot  | Content                            | Notes |
|--------|------------------------------------|-------|
| 546561 | Shared content (~67 GB)            | Data, no code. Same on every platform |
| 546563 | Windows binaries                   | **x86-64 only** (checked: PE `0x8664`, no ARM64EC metadata) |
| 546564 | Linux binaries                     | Contains **x86-64 and ARM64** in separate folders |

The app downloads **546561 + 546564** (only the ARM64 part of the latter is used).

### Linux depot layout
```
game/hlvr.sh                         # launcher; recreates library symlinks
game/bin/linuxsteamrt64/             # x86-64 (unused)
game/bin/linuxsteamrtarm64/          # ARM64  <-- what we port
game/hlvr/bin/linuxsteamrtarm64/     # libclient.so, libserver.so, libhost.so
```
The library symlinks (`link:target` pairs in the `create_symlinks` function of
`hlvr.sh`) must be recreated during preparation.

### ARM64 binaries (checked)
- ELF64 **aarch64**, linked against **glibc** (highest required version `GLIBC_2.38`,
  Steam Runtime). **Not Android/bionic** → Klepton needs a glibc layer.
- Key dependencies:
  - `hlvr` → `libmimalloc.so`, `libstdc++.so.6`, `libc.so.6`
  - `libengine2.so` → `libm`, `libstdc++`, `libuuid.so.1`, `ld-linux-aarch64.so.1`,
    `libtier0`, `libvstdlib`, **`libsteam_api.so`**, `libc`
  - `libvr.so` → **`libopenvr_api.so`** (VR through **OpenVR**, not OpenXR)
  - `librendersystemvulkan.so` → **`libxcb.so.1`** (X11 window), loads Vulkan
    dynamically (0 direct `vk*` imports)
- Bundled Vulkan driver: `libvulkan_freedreno_hlvr.so` + ICD
  `freedreno_hlvr_icd.aarch64.json` (Turnip/Adreno, API 1.4). **Useless on Apple** →
  replaced by MoltenVK by pointing the loader at another ICD.
- Scripting: V8 (`libv8*.so`) and `libvscript.so`.

### Foveation and engine settings (binary strings)
The renderer already implements foveation with:
- `VK_EXT_fragment_density_map` and `VK_EXT_fragment_density_map_offset`
  ("Using VK_EXT_fragment_density_map_offset for eyetracking support")
- Flag `-vulkan_disable_ext_fragment_density_map`

Useful ConVars found:
```
vr_foveation_disable            vr_foveated_boundary
vr_foveated_inner_scalar        vr_foveated_outer_scalar
vr_foveated_overlap             vr_fdm_offset (+ _debug, _flip_y)
vr_msaa                         vr_msaa_submit
vr_alternating_msaa_2x          vr_force_native_resolution
vr_reprojection_cpu_auto        vr_vulkan_wait_fence_between_eyes
r_texture_stream_*              (texture streaming)
```

### Memory (gameinfo.gi + binaries)
- `RenderSystem` in `game/hlvr/gameinfo.gi`: `DeckardTexturePoolSizeMB 2816` (Steam Frame =
  "Deckard": ~2.75 GB of textures), `MinStreamingPoolSizeMB 1536`,
  `SetInitialStreamingPoolSizeFromBudget 1`, `VulkanUseStreamingTextureManager 1`.
- Dynamic budget via `VK_EXT_memory_budget` (`r_texture_budget_dynamic`,
  `r_texture_budget_threshold`), `-vr_gpu_memory_reserve_mb`, and
  `CRenderDeviceVulkan::OnLowMemoryNotification` (evicts textures).
- `Vr/FilterFidelityLevelsByGPUMemoryRatio 1`: drops fidelity levels that don't fit.
- Estimate (not measured) for the process on Frame: ~6–7.5 GB.
- **Vision Pro with increased memory limit: 8133 MB available to the app (measured on
  device)**. This is the whole process budget, GPU included; if exceeded, jetsam kills
  the app. Plan:
  - Default texture pool = Steam Frame value (2816 MB); can be lowered in the menu
    (texture quality). The game is known to fit in this budget even at high settings:
    memory is **not** the bottleneck, **framerate** is.
  - MoltenVK must report the memory **available to the process**
    (`os_proc_available_memory`) in `VK_EXT_memory_budget`, not total RAM.
  - visionOS memory warning → the engine's `OnLowMemoryNotification`.
  - Account for our own usage (MoltenVK, intermediate foveated texture, MetalFX, runtime).

### Language (in the ARM64 binaries)
- Launch parameters: `-language`, `-textlanguage` / `-textsublanguage`; keys
  `AudioLanguage` / `AudioSubLanguage`, convar `cl_language`, search path `game_language`.
- The engine also queries `ISteamApps::GetCurrentGameLanguage` and
  `GetAvailableGameLanguages` → the **Steam shim** must return the language picked in the
  menu and the available list.
- 28 text/subtitle languages; **voice-over in English only**. A single selector (text);
  audio is fixed to English. List: Steam app info and/or downloaded files.

### Dynamic resolution: Auto-Fidelity System (in the ARM64 binaries)
- `vr_fidelity_level` = a level from a table (each level = resolution scale + MSAA;
  log: "Level %d: Scale = %.3f Resolution = %d x %d").
- `vr_fidelity_level_auto` adjusts the level from per-frame GPU time (CRITICAL /
  PREDICTIVE / MAX DROP, MIN INCREASE).
- Settings: `vr_fidelity_threshold_frame_percent_{min,max,critical,extrapolation}`,
  `vr_fidelity_target_extra_ms`, `vr_fidelity_target_half_rate`,
  `vr_perf_mode_max_fidelity_level`, `vr_fidelity_memory_threshold`,
  `vr_fidelity_visualizer`, `vr_spew_fidelity_data`.
- Flags: `-autofidelityconfig`, `-forcefidelitylevel`, `-noautofidelity`.
- Requirements for AVP: the OpenVR runtime must provide **real per-frame GPU times**
  (Metal/Compositor Services); the table is chosen by GPU vendor (with MoltenVK = Apple) →
  create an **M2-specific level table** via `-autofidelityconfig`.
- Pairs with MetalFX Spatial: variable internal resolution, fixed output.

---

## 3. Platform constraints

- **Native visionOS app.** AVP is always its own native app. No LiveContainer or any other
  container/host is used; at most, techniques are taken as reference.
- **No JIT, ever.** visionOS only runs signed code. There are two ways to load the adapted
  engine without JIT, and Phase 0 decides which one is used:
  - **Option 2 (preferred): on-device signing.** The app downloads the ARM64 binaries,
    adapts them and **signs them on the Vision Pro itself with the free development
    certificate SideStore generates for the user's Apple ID** (imported once into the app
    from SideStore) before loading them. Valve-free IPA, everything from the app.
    Not confirmed that visionOS accepts this → Phase 0.
  - **Installation:** IPAs are installed with **SideStore** (free Apple ID, no paid
    developer account). Implications:
    - SideStore **refreshes AVP every 7 days** like any app (what expires is the
      **provisioning profile**, not the certificate). If the certificate doesn't change,
      the `.dylib`s signed on device remain valid. If SideStore issues a new one
      (revocation, re-login, expiry), AVP detects it on launch, imports it and **re-signs**
      (seconds; no re-download or re-conversion).
    - On-device signing only needs certificate + private key and an open-source signer
      (zsign/ldid, check licence). SideStore code is **not** reused and Apple is not
      contacted.
    - Free account limits: **3 active apps** (SideStore counts as one) and
      **10 App IDs / 7 days**. AVP must cost only **1 app + 1 App ID**: design it
      **without app extensions** (each one uses an extra App ID). Signing and re-signing
      `.dylib`s on device creates no new App IDs or apps.
    - What matters is the **App ID**: while it stays registered, the user can freely
      uninstall and install apps to switch between them. AVP **does not need StikDebug**
      (no JIT).
    - Option 1 is compatible too: SideStore signs the IPA with everything inside it.
  - **Option 1 (fallback): adapted engine inside the IPA** (Klepton's way). Conversion at
    build time, code ships signed in the app. Guaranteed to work, but the IPA contains
    Valve code: it is generated from the user's copy and is never shared or published.
    Content (546561) is still downloaded from the app.
  - Everything else (OpenVR runtime, foveation, menu, content download, shaders) is
    identical in both options.
- **No gaze.** visionOS doesn't expose gaze to apps. Foveation will be **fixed, centred**
  (doesn't follow the eyes). `vr_fdm_offset` stays unused.
- **Compositor Services default foveation** for immersive Metal apps = static, mild map.
  That's why we use our own map (see §5.3).
- **Copyright:** the IPA and the repo **contain nothing from Valve**. All game files are
  downloaded by the user with their own account on their own device.

---

## 4. Architecture

```
[GitHub Actions macOS, manual or [build] only]
  builds ONLY the project's code (loader, runtime, MoltenVK, UI)
  -> Valve-free IPA (Option 2) / with the adapted engine (Option 1, private)

[Vision Pro, all inside the app]
  1. Steam login (2FA)
  2. download depots 546561 + 546564 (manifests pinned to a tested version)
     -> user-accessible folder (Files app: "On My Apple Vision Pro > AVP")
  3. preparation: symlinks, ELF->Mach-O + on-device signing (Option 2), shader pre-cache
  4. launch menu -> game
```

### User folder
- The app exposes its data folder in **Files** (`UIFileSharingEnabled` +
  `LSSupportsOpeningDocumentsInPlace`).
- Downloaded files are installed there, and the user can **place their own legally
  obtained, already adapted files** there to launch with this project (alternative to the
  automatic download/adaptation). The app detects what is present and only does what's
  missing.
- Proposed layout:
  ```
  AVP/
    game/            # depots as-is (content + ARM64)
    adapted/         # converted and signed binaries (generated or provided)
    cache/shaders/   # compiled MSL + MTLBinaryArchive
    config/          # menu settings + generated game cfg
    logs/
  ```
- Manifests are **pinned** to a tested version so a Valve update can't break the game;
  updating to a new version is an explicit action.

### Components
1. **Loader** — Klepton fork with a Linux/glibc "personality": ELF→Mach-O (runs
   **on device**), `ld-linux`, `libc`/`libm`/`libstdc++`/`libuuid` shims, TLS, `x18`
   (Darwin zeroes it on every exception: check whether Valve's code uses it).
2. **On-device signing** (Option 2 only) — import the SideStore certificate and sign the
   generated Mach-Os (and re-sign them when the certificate changes), inside AVP.
3. **Vulkan** — MoltenVK (also evaluate KosmicKrisp if mature). `libxcb` stub.
4. **Custom OpenVR runtime** (`libopenvr_api` replacement) on **Compositor Services + ARKit**:
   - `VR_InitInternal`, `VR_GetGenericInterface`, `VR_ShutdownInternal`, etc.
   - `IVRSystem` (projections, `GetRecommendedRenderTargetSize` = real resolution lever)
   - `IVRCompositor` (per-eye submit → drawable, timing, pose prediction)
   - `IVRInput` (controllers: PS VR2 Sense / gamepads via GameController; hands via ARKit)
5. **Foveation** — FDM → custom `MTLRasterizationRateMap` translation (§5.3).
6. **Steam shim** — minimal `libsteam_api`, only for the user's own copy.
7. **Swift Steam client** — login (2FA/Steam Guard, refresh token in Keychain),
   licences, manifests, depot keys, CDN, resumable download.
8. **visionOS app** — SwiftUI: login, download, preparation, menu, launch.

---

## 5. App design

### 5.1 Flow
Login → Download (progress, resumable, free-space check ~70 GB+) →
Prepare (adaptation + signing + shaders; may take around 10–15 min) → Menu → Play.

### 5.2 Shader pre-cache
- Walk the content's Vulkan shaders (SPIR-V in VPKs), translate **all** of them to MSL and
  compile them (`MTLLibrary`) after download.
- PSOs (state combinations) can't be fully precomputed: store them in a
  `MTLBinaryArchive` the first time and reuse.
- The content ships `shaders_vulkan_*.vpk` (~1.25 GB) and a Fossilize pipeline cache
  (`vulkan_shader_cache.foz`, referenced in `gameinfo.gi` as
  `VulkanAdditionalShaderCache`) → replay it to precompile PSOs as well.
- Invalidate the cache if the manifest or the MoltenVK version changes.

### 5.3 Foveation (goal: similar to Steam Frame, but fixed)
- Render to an **intermediate texture** with our own `MTLRasterizationRateMap`, then
  composite into the Compositor Services drawable.
- Also feed the `vr_foveated_*` convars so the engine distributes detail the same way.

### 5.4 Launch menu (saved settings, applied on every launch)
| Setting | Options |
|---------|---------|
| **Real resolution** | % of native (via `GetRecommendedRenderTargetSize` + game cfg) |
| **Dynamic resolution** | On/Off · min–max range · headroom target (stable ↔ sharp) |
| **Texture quality** | Streaming pool size (min 1536 MB; default 2816 MB) |
| **Language** | 28 text/subtitle languages (voices always English, the only audio language) |
| **Foveation** | Off / Light / Medium (≈Steam Frame) / Strong / Custom |
| ↳ Custom | Sharp-zone size · Periphery quality · Transition smoothness |
| **Anti-aliasing** | Off / MSAA 2x / Alternating MSAA 2x (`vr_alternating_msaa_2x`) / MSAA 4x |
| **Upscaling** | None / MetalFX Spatial / MetalFX Temporal (*experimental*) |
| **Sharpness** | Slider (MetalFX only) |

- Visual diagram of the per-eye quality distribution and the **estimated cost** of the
  combination.
- MetalFX Temporal needs motion vectors that Alyx doesn't generate (it never had TAA):
  approximate them from depth + head pose → ghosting on moving objects. Off by default.
  When enabled, the menu **turns MSAA off** automatically.
- MSAA + MetalFX Spatial: valid combination (AA first, upscaling after).
- Values are written to the game's own config files + runtime parameters.

---

### 5.6 PS VR2 Sense controllers (input + haptics)
visionOS 26 supports PS VR2 Sense controllers with 6DoF tracking, capacitive finger touch
and vibration (GameController + ARKit accessory tracking). Goal: haptics that feel exact.
- **Haptics path:** the game requests haptics through OpenVR (`IVRInput::TriggerHapticVibrationAction`:
  duration, frequency, amplitude; plus legacy `IVRSystem::TriggerHapticPulse`). The
  runtime maps them to **Core Haptics** on each controller (`GCController.haptics`, one
  engine per hand/locality):
  - amplitude → intensity, frequency → sharpness (calibrated curve), duration → event
    length; continuous events for long rumbles, transients for short pulses.
  - **Low latency:** engines started and kept alive, pre-created
    `CHHapticAdvancedPatternPlayer`s per hand, live updates with `sendParameters`, haptics
    dispatched off the render thread; restart engines on reset/stop callbacks.
  - Test map of the game's haptic events (gravity gloves, weapon fire, reload, damage,
    object contact) to tune each one on device.
- **Capacitive touch** (`GCControllerLiveInput`, `touchedInput`; thumbstick, A/B,
  grip, trigger) → OpenVR skeletal/finger input so Alyx's hand poses follow the fingers.
  Analog proximity is **not** exposed by Apple → touch is binary; smooth the transitions.
  Per-finger mapping: **thumb** ← thumbstick / A / B touch, **index** ← trigger touch +
  analog trigger value, **middle/ring/pinky** ← grip touch + grip press. Index curl blends
  touch (half-curl) with trigger value (full curl).
- **Buttons:** triggers analog via `pressedInput.value`; PS button reserved by the system.
- **Adaptive (resistive) triggers:** no public visionOS API confirmed for Sense controllers,
  and the game's OpenVR path doesn't use them → out of scope unless Apple exposes them.
- **Tracking:** controller pose from ARKit accessory tracking, with prediction aligned
  to the compositor's frame timing.

## 5.5 Priority: framerate
Framerate is goal no. 1. Order of work:
1. **Measure before optimising:** custom HUD with CPU time (main and render threads),
   GPU time, fps and fidelity level. Find out whether it is CPU- or GPU-bound.
2. **If GPU-bound:** custom foveation (§5.3), real/dynamic resolution, alternating MSAA 2x,
   MetalFX Spatial. This is where most is gained.
3. **If CPU-bound:** MoltenVK per-draw-call overhead and on-the-fly shader translation;
   keep `MultiviewInstancing` (enabled in gameinfo) to avoid duplicating draws per eye,
   full shader and PSO pre-cache, review synchronisation
   (`vr_vulkan_wait_fence_between_eyes`).
4. **Reprojection:** pass depth to the visionOS compositor so its reprojection is more
   stable when a frame is late (equivalent to Steam Frame's depth reprojection).

## 6. Phases

### Phase 0 — Verify on-device signing (blocking, cheap)
Minimal native visionOS prototype, installed with SideStore: import the certificate from
SideStore, download a `.dylib`, sign it on the headset and load it with `dlopen`, no JIT.
- **Works** → Option 2 (everything from the app, Valve-free IPA).
- **Doesn't work** → Option 1 (adapted engine inside the IPA, see §3).

### Phase 1 — Boot and play well (priority)
1. Xcode/visionOS project scaffold + CI workflow.
2. Accessible folder in Files; the user places the game files there.
3. Klepton fork + glibc layer + on-device conversion and signing; load
   `libtier0` → `libengine2` → `hlvr`.
4. MoltenVK + `libxcb` stub; first frame.
5. OpenVR runtime on Compositor Services/ARKit; stereo + head pose.
6. Input (controllers and/or hands).
7. Custom foveation (§5.3) and settings menu (§5.4).
8. Testing and profiling on Vision Pro M2.

### Phase 2 — "Download and play" experience
1. Swift Steam client (login + 2FA, Keychain).
2. Download of 546561 + 546564 pinned to the manifest, resumable, into the user folder.
3. Automatic preparation + full shader pre-cache.

---

## 7. Valve content
- **Nothing from Valve** in git, releases or artifacts (see `.gitignore`). With Option 2
  the IPA contains nothing from Valve and the repo could be made public (review history
  first). With Option 1 the IPA is only generated privately.

---

## 8. Open questions
- Does importing the SideStore certificate + on-device signing + `dlopen` without JIT
  work on visionOS? (Phase 0)
- Target controllers: PS VR2 Sense first (see §5.6); hand tracking as fallback.
- Whether visionOS exposes Sense precision haptics beyond basic vibration (frequency range).
- Exact format of the Vulkan shaders in the VPKs and whether the ARM64 build ships its own
  cache.
- Whether upstream Klepton adds glibc or JIT support in the meantime.
- Use of `x18` in Valve's code (built for Linux, may use it as a free register).
- Storage: ~67 GB of content + binaries + shader cache on the Vision Pro.

---

## 9. Technical credits to consider
Klepton · zsign (on-device signing, reference) · MoltenVK · SPIRV-Cross ·
OpenVR (headers) · SteamKit2 / DepotDownloader (protocol reference) ·
Apple Compositor Services / ARKit / MetalFX.
