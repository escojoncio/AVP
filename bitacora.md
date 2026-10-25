# Bitácora — AVP

Half-Life: Alyx (ARM64 Linux de Steam) nativo en Apple Vision Pro (M2). Steam oficial → descarga → ELF→Mach-O
(`klepton_ld`) → firma on-device (`vp_codesign` + .p12) → prewarm de pipelines → juego. Gráficos: **solo VPKEngine**
(`escojoncio/VPKEngine` @ `vpkengine.ref` + `vpkengine-patches/` 0011–0041; parche nuevo = `00NN-*.patch` con
`git format-patch` sobre ref+parches; CI `scripts/apply-vpkengine-patches.sh`). Plan: `PLAN.md`.
IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: **B60**, compilada OK).
Builds: solo con `[build]` en el mensaje o dispatch manual; docs con `[skip ci]`.

## Últimos hechos (B60 compilada OK en CI, sin validar en el visor)
- Compositor (`KleptonCompositor.swift`, `kl_reproject.c/.h`): RCAS fusionado en el fragmento de composición (zona de
  tasa completa; sin mapa 882/2016 × 861/1632; `KL_CP_SHARP_FUSED=0` = pase aparte); 1 command buffer por imagen nueva
  (prep+wide+composite en `cmd`, tras el wait del guest); vista ancha y recon en 1 pase de 2 instancias; log
  `[cp] gpu composite p50/p95/max`; GPU perdida (código 11 o cola no sustituible juzgada → negro + `Lifecycle.quit(why)`
  + `_exit` a 3 s; códigos 2/7 sin gastar presupuesto; 1 rebuild/s limitado; `retiredQueues` ≤ 8); guest congelado
  > `KL_CP_STALE_HIDE_S` (10 s) → negro, nunca en carga (`kl_guest_loading()` = FadeGrid) ni pausa.
- VPKEngine 0042–0046 (bits en caliente, OFF por defecto): 0042 `enc_ms`/`wait_ms`/`opt_counters2[16]`/`reorderable`;
  0043 bit4 fuse clears; 0044 genMips declara la cadena (fix); 0045 bit3 gather copies; 0046 bit5 state elide (CPU).
- VPKEngine 0047–0050: port a mano del MSAA memoryless de upstream (9f5867b, sobre fb5829a/662a70b): todo attachment
  diferido/memoryless, materializa al Load/Store/Sample (`gpu.metal.info what=msaa_materialized why=`), ban por encoder
  culpable, HeavyGeometry (`VPVK_TILE_MAX_DRAWS`/`_VERTICES`) conserva Resolve de 0034, `vpvk_mark_eye_image`.
  `kl_vulkan.c` marca el ojo persistente (alloc + publish). `KL_VK_MSAA_STORE` no está activo en Alyx.
- App: «Laboratorio del motor» (`AVPEngineLabView.swift`, `avp.lab.*`): toggles en caliente bits 0/2/3/4/5, «Probar todo»
  (A/B en caliente ~50 s, `kl_abtest_start/cancel`, final = inicio + SAVES − WORSE/BREAKS); textos claros en todos los
  ajustes, Diagnóstico plegado.
- Logs_Alyx_48: foveado baja GPU juego 3–7 ms y compositor ~2,4 ms; fps cuantizados (100 Hz: 50/33; 90 Hz: 45/30;
  visionOS elige Hz, sin API). Zona pesada juego ~23 ms.

## Estado actual
- 100 % funcional (visor): Steam (login+Guard, Cloud), firma, 90 libs, prewarm ~4150 pipelines; VPKEngine 0 cuelgues
  desde B17, MSAA 4x, amplificación de vértices, occlusion culling medido, `VP_CB_ORDER=2`; foveado VRR (periferia 10 %,
  VPKTAA en periferia; post NO foveado); compositor skip-same; regulador 50/33 (100 Hz) o 45/30 (90 Hz) con tiempo de
  GPU exclusivo; reloj del juego `klvr_game_hz`; OpenVR cabeza + 2 Sense, dedos, altura, subtítulos, idioma, pausa.
- Pendiente de validar: B58 (altura real, `vk.fail`), B59/B60 (RCAS fusionado sin costura).
- B60 al validar: `[cp] gpu`, `gpu.frame enc_ms/wait_ms`, `gpu.mem_tex` (msaa_memoryless, ledger),
  `what=msaa_materialized why=`, `memoryless_banned`, `[abtest]` del Laboratorio; preguntar fallos visuales por bit.
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

- Bits del motor: 1 PROHIBIDO; 3/4/5 OFF hasta A/B en visor; HUD/Laboratorio decide.

## Ficheros en juego
- `klepton/.../klvr_platform_klepton.c` (`pace_plan`, `pace_governor`), `kl_app.c` (pacer), `kl_gpu_time.m`.
- `klepton/visionos/Sources/KleptonCompositor.swift`, `klepton/runtime/gfx/kl_reproject.c`, `kl_gpu_time.m`,
  `kl_vulkan.c`; `app/Sources/AVPSettings*.swift`, `AVPEngineLabView.swift`, `AVPLauncher.swift`.
- `vpkengine-patches/0042–0050`.

## Índice de notas
- `notas/rendimiento.md`: reparto del frame, hallazgos Logs_34–47, conclusión e ideas pendientes de rendimiento.
- `notas/builds.md`: qué hace cada mecanismo de B46–B59 (VPKEngine 0038–0041, regulador, compositor, app).
