# Bitácora — AVP

Half-Life: Alyx (ARM64 Linux de Steam) nativo en Apple Vision Pro (M2). Steam oficial → descarga → ELF→Mach-O
(`klepton_ld`) → firma on-device (`vp_codesign` + .p12) → prewarm de pipelines → juego. Gráficos: **solo VPKEngine**
(`escojoncio/VPKEngine` @ `vpkengine.ref` + `vpkengine-patches/` 0011–0052; parche nuevo = `00NN-*.patch` con
`git format-patch` sobre ref+parches; CI `scripts/apply-vpkengine-patches.sh`). Plan: `PLAN.md`.
IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: **B63**, compilada OK).
Builds: solo con `[build]` en el mensaje o dispatch manual; docs con `[skip ci]`.

## Últimos hechos
- B63 compositor (`KleptonCompositor.swift` ~3184/3255/4488-4575): con `VP_EXCL_TIMING`/`KL_GPU_PASSES` mide GPU por encoder
  del CB de composición (MTLCounterSampleBuffer stage-boundary, pool 4×128, slot 0; exclusivo por orden): línea 1/s
  `[cp] gpu passes eye= layer= wide= recon= comp= other= sum= cb= n= enc= skip= phys= fov= raw= units=`. Blits/MetalFX = cb−sum.
- B63: Laboratorio ELIMINADO (`AVPEngineLabView.swift` borrado; `AVPSettings.swift`, `AVPSettingsView.swift`,
  `AVPLauncher.swift`). Fijo: `VPVK_RUNTIME_OPTS=0`, `KL_EYE_TRIM=1`, nitidez fusionada (`KleptonCompositor.swift:3374` def.),
  `VPVK_MSAA_DEAD_STORE=1`, archivo binario ON (clave caché `archive on` → 1 prewarm completo); sin A/B ni relaxedF16.
  `resetQuarantine` (`AVPPrepare.swift:~638`) borra también `archive.off`/`archive.strikes`. Código muerto sin borrar:
  API abtest/`kl_engine_set_opts` en `kl_gpu_time.h/.m`, `KleptonCompositor.setSharpFused`, `AVPPrepare` `archive:` false+borrado `.metalar`.
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
- B63 al validar: `[cp] gpu passes` (¿recon/wide dominan?, units/raw coherentes), `pace.gov fallback avg=` (¿cerca de 17?), `[gputime]` comp ms, prewarm completo 1.ª vez sin OOM, sin Laboratorio.
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
  `kl_vulkan.c`; `app/Sources/AVPSettings*.swift`, `AVPEngineLabView.swift`, `AVPLauncher.swift`.
- `vpkengine-patches/0042–0050`.

## Índice de notas
- `notas/rendimiento.md`: reparto del frame, hallazgos Logs_34–47, conclusión e ideas pendientes de rendimiento.
- `notas/builds.md`: qué hace cada mecanismo de B46–B59 (VPKEngine 0038–0041, regulador, compositor, app).
