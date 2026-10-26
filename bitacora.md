# Bitácora — AVP

Half-Life: Alyx (ARM64 Linux de Steam) nativo en Apple Vision Pro (M2). Steam oficial → descarga → ELF→Mach-O
(`klepton_ld`) → firma on-device (`vp_codesign` + .p12) → prewarm de pipelines → juego. Gráficos: **solo VPKEngine**
(`escojoncio/VPKEngine` @ `vpkengine.ref` + `vpkengine-patches/` 0011–0054; parche nuevo = `00NN-*.patch` con
`git format-patch` sobre ref+parches; CI `scripts/apply-vpkengine-patches.sh`). Plan: `PLAN.md`.
IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: **B65**).
Builds: solo con `[build]` en el mensaje o dispatch manual; docs con `[skip ci]`.

## Últimos hechos
- B65 (`3c982fc`, sin verificar en visor):
  - `KleptonCompositor.swift`: tiempo GPU por command buffer (gpuEnd−gpuStart, completion handler), label
    `comp.<new|same|black>(fxaa,layer,wide,recon,comp,sharp,mfx,mip)`; línea 1/s `[cp] cb n= frames= skipped= bad= <label>=<n>x<ms>`
    (gate `KL_GPU_PASSES`/`VP_EXCL_TIMING`; `cpPassTag` ~4503, `noteCompositeCb` ~4511, handler ~3324). Desconectados sin borrar:
    `cpProfClaim`, `cpProfAttach`, `noteCompositePasses`, `CpProfSlot`.
  - Ritmo: quitados `KL_DISPLAY_HZ=90`/`KL_GUEST_PACE_HZ=45` (`AVPSettings.swift`). `klvr_plat_pace_base()` (`klvr_platform_klepton.c`
    ~196); pacer `kl_app.c` ~1503/1563 usa esa base (45/30 a 90 Hz, 50/33,3 a 100 Hz) salvo `KL_GUEST_PACE_HZ` manual.
    Panel sin medir → 90 (`pace_plan` ~184, weak `kl_guest_pace_fps`). El juego ve ya la frecuencia medida (antes 90 fijo).
  - `VP_PIPELINE_ARCHIVE_BUDGET_MB=1280` (`AVPSettings.swift` ~571): abre pipelines-19 (+725 entradas, ~+440 MB, unverified).
  - 0053: `gpu.pso.miss n= kind= label= key= ms=` (20 primeras compilaciones completas). 0054: tras un save bueno, un fallo de
    `archive_save` va directo al split (2 serializaciones en vez de ~9).
- Logs_Alyx_4 (B64, 45 s en a1_intro_world, térmico fair): 33 Hz fijo; GPU juego 17,5–19,6 + comp 5,4–7,7 ms. B64 `bad=100%`,
  `first resolve` zeroIdx=[0,1] → MTLCounterSampleBuffer por encoder no sirve en visor. ~100 cmdbufs/s p50 1,8 ms = frames
  black/loading; ~34/s p50 7 ms = composites nuevos. 234 compilaciones en juego (1,35 s; stalls 849/166/124 ms).
  `archive_save` 64 entradas falla ("expecting 'fragment' stage in pipeline no. 32", empaquetador de Apple); split recupera todo.
  Panel medido 100 Hz con juego informado 90. Steam en guest: `steamclient.so` no encontrado (logros/cloud guest off).
- `gpu.shader.lib hit=0` en Alyx = contador sin función (índice solo de precompileDir/VisionQuestPro).
- `prewarm=0` (`avp_config.c:42`) → no se emite `gpu.pso.recipe game hits=` → recorded.foz/recetas nunca invalidan `warm.stamp`.
- B63 regulador (`klvr_platform_klepton.c:348`): línea `[openvr] pace.gov fallback avg= late= need= streak=` cada 10 s en fallback.
  Sin bug: mide juego+comp (`per = game + comp*fb/base`, l.281); subir a 50 exige avg < 17 ms 10–120 s; juego 15–19 + comp 4–8.
- VPKEngine 0052 = solo `gpu.time ... t=<ms>` (ms desde arranque). RelaxedPrecision descartado: Alyx tiene 0 decoraciones (B62).
- Logs B62 65 %/65°/edge 0,10: busy juego 15,5 ms (vs 21,6 a 70 %/70°), regulador 33 por compositor 4–8 ms (`[gputime]`).
  RAM pico 6,1 GB, mín. libre 2,1 GB. `KL_DISPLAY_HZ=90` con panel 100 Hz (unverified).
- Reparto GPU (fov ON 70 %): scene-msaa 16,6 (vtx 4,0/frag 12,6) + eye-1x 3,4 + blit 1,0; fov OFF scene-msaa 23,7.
  `MTLMathModeFast` ya activo. Mediciones previas: `notas/rendimiento.md`, `notas/builds.md`.

## Estado actual
- 100 % funcional (visor): Steam (login+Guard, Cloud), firma, 90 libs, prewarm ~4150 pipelines; VPKEngine 0 cuelgues
  desde B17, MSAA 4x, amplificación de vértices, occlusion culling medido, `VP_CB_ORDER=2`; foveado VRR (periferia 10 %,
  VPKTAA en periferia; post NO foveado); compositor skip-same; regulador 50/33 (100 Hz) o 45/30 (90 Hz) con tiempo de
  GPU exclusivo; reloj del juego `klvr_game_hz`; OpenVR cabeza + 2 Sense, dedos, altura, subtítulos, idioma, pausa.
- B65 al validar: `[cp] cb` (qué label/pases dominan los 5–8 ms), `pace plan` 45/30 a 90 y 50/33 a 100 Hz sin pin,
  `gpu.pso.miss` (qué pipelines faltan y por qué no están en prewarm/archivo), `archive` abiertos/skip por budget, RAM pico.
- Pendiente: Steam en guest (`steamclient.so`); SSAO: decisiones dicen off pero `AVPSettings.swift:403-415` y
  `app-convars.lua:15,41` ponen `r_ssao=1` (log B64 = 1).
- Próximo objetivo: coste GPU del compositor 4–8 ms (B60 notó subida desde 2,4–6; posible RCAS fusionado, unverified).
- Riesgos B60 sin verificar en visor: 0046/0049/0050 (Metal), `vpvk_mark_eye_image` vía dlsym. Parches 0047–0050 se conservan (los reutiliza VisionQuestPro).
- Problema abierto: zona pesada juego ~23 ms > umbral (17 ms a 100 Hz, 18,9 a 90 Hz); térmico.

## Decisiones vigentes
- Sin MetalFX; MoltenVK solo fallback automático; nada que cambie lo visible (LOD, cull, `vr_expand_cull_frustum`,
  SSAO off, sombras, MSAA): el rendimiento sale de resolución y optimización pura.
- `VPVK_RUNTIME_OPTS=0`; clear skip (0038 bit1) nunca.
- Comparar rendimiento con visor frío, misma zona, mismo tiempo, mismo «Medir GPU por pase».
- Diagnóstico solo al log de la app (el usuario no tiene Mac ni `.ips`); nada de volcados pesados en mitad del juego.
- `Window(id:)` mata el launcher → `WindowGroup`. `KL_VRR_PHYS=1` rompe la imagen. Ojos sin copia parpadea.
- Nunca abandonar un frame tras `queryNextFrame`. Todo frame consultado a CompositorServices se presenta.

- Bits del motor: todos OFF fijo (`VPVK_RUNTIME_OPTS=0`); bit 1 PROHIBIDO.

## Ficheros en juego
- `klepton/.../klvr_platform_klepton.c` (`pace_plan`, `pace_governor`), `kl_app.c` (pacer), `kl_gpu_time.m`.
- `klepton/visionos/Sources/KleptonCompositor.swift`, `klepton/runtime/gfx/kl_reproject.c`, `kl_gpu_time.m`,
  `kl_vulkan.c`; `app/Sources/AVPSettings*.swift`, `AVPLauncher.swift`, `app/Native/avp_config.c`.
- `vpkengine-patches/0042–0054` (0053/0054 en `gpu/metal2/src/metal_backend.mm`).

## Índice de notas
- `notas/rendimiento.md`: reparto del frame, hallazgos Logs_34–47, conclusión e ideas pendientes de rendimiento.
- `notas/builds.md`: qué hace cada mecanismo de B46–B59 (VPKEngine 0038–0041, regulador, compositor, app).
