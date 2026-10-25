# Bitácora — AVP

Half-Life: Alyx (ARM64 Linux de Steam) nativo en Apple Vision Pro (M2). Steam oficial → descarga → ELF→Mach-O
(`klepton_ld`) → firma on-device (`vp_codesign` + .p12) → prewarm de pipelines → juego. Gráficos: **solo VPKEngine**
(`escojoncio/VPKEngine` @ `vpkengine.ref` + `vpkengine-patches/` 0011–0052; parche nuevo = `00NN-*.patch` con
`git format-patch` sobre ref+parches; CI `scripts/apply-vpkengine-patches.sh`). Plan: `PLAN.md`.
IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: **B62**, compilada OK).
Builds: solo con `[build]` en el mensaje o dispatch manual; docs con `[skip ci]`.

## Últimos hechos
- B62 VPKEngine 0052: `VPVK_RELAXED_F16=1` → pase `vpir::demoteRelaxed` (`gpu/shader/ir/src/relaxed.cpp`, marcado en
  `spirv/src/lower.cpp`): solo fragment, ops float RelaxedPrecision en `half`; taint hacia atrás excluye coords de imagen,
  derivadas, interp, direcciones, builtins, enteros, condiciones; Dot/Length/Normalize/Rsq/Div/Rcp/Pow/Exp2 solo con operandos
  acotados (sample/saturate/clamp/const/ya degradados); constantes no half-normales excluyen. Bit 2 de `translatorId`.
  Log `vpvk.f16 shaders= decorated= demoted= excluded=` (1.º y cada 200); `gpu.time ... t=<ms>` (ms desde arranque).
  Lab «Requieren reiniciar»: `avp.lab.relaxedF16` (def. OFF), en `sigKeys` solo si ON. Tests Linux 144/144 (`gpu_spirv.relaxed_f16`).
  Sesión A/B (logs_A, fov OFF): `KL_DISPLAY_HZ` fuerza 90 con panel 100 Hz, invitado a 90/45 (boot:91-93,477) — revisar (unverified).
  B62 al validar: arranque OK con ON, `vpvk.f16` demoted>0, scene-msaa frag ON vs OFF (misma zona, fov ON), bandas/manchas.
- B61 VPKEngine 0051 (= main `454f7cc`): elisión de stores MSAA muertos (`VPVK_MSAA_DEAD_STORE=1`); `gpu.frame stores_elided=
  elide_miss=`, `gpu.msaa elide_miss`, `msaa_materialized ... load= store=`. Port: `Use::firstAttach` añadido al árbol AVP.
- B61 Laboratorio: «Nitidez en la composición» fusionada/pase aparte EN CALIENTE (`KleptonCompositor.setSharpFused`, latch
  `sharpFusedFrame` por frame, ventana p50 de `[cp] gpu composite` se reinicia al cambiar, `avp.lab.sharpFused`); sección
  «Requieren reiniciar»: `avp.lab.binaryArchive` (def. OFF; ON = sin `VP_PIPELINE_ARCHIVE=0`, no borra `.metalar`,
  `checkArchiveInflight` → `archive.off` tras 2 cierres) y `avp.lab.msaaDeadStore` (def. ON, en `sigKeys`).
- B61 segundo plano (`KleptonApp.swift`): `.background` con inmersivo → `kl_guest_set_paused(1)` (`Lifecycle.pausedByBackground`),
  reanuda solo en `.active` si no lo pausó el usuario; compositor sigue presentando (regla watchdog); stale-hide no salta.
- B61 `kl_vulkan.c`: log `[vkmem]` dice qué limita (OS / `KL_VK_HEAP_MB` / heap anunciado). Valores sin cambio.
- Shaders VPKEngine (main 07bd8fa): traductor propio SPIR-V→vpir (`gpu/shader/spirv/src/lower.cpp`)→MSL (`gpu/shader/msl/src/msl.cpp`);
  `MTLMathModeFast` ya activo (`gpu/metal2/src/metal_backend.mm:1566`); `RelaxedPrecision` IGNORADO (todo fp32, sin `half`);
  sample shading no se usa. Palanca candidata: honrar RelaxedPrecision → `half` (unverified, ganancia desconocida).
- Reparto real B61 (ventanas estables `[passes]` busy≈suma by-kind, sin idle oculto): fov ON busy 21,5 ms = scene-msaa 16,6
  (vtx 4,0/frag 12,6; 2112x1728 s4 ld2 st2+r, z f260 s4) + eye-1x 3,4 + blit 1,0; fov OFF busy 30 = scene-msaa 23,7 (frag 19,2).
  W1–W3 son carga, no usar. `gpu.time` = juego+compositor con EMA (`klvr_compositor.cpp:761-770`, unverified).
- Logs B61 A/B foveado (misma zona): OFF `gpu.time` p50 22,97/p90 26,0 ms; ON (luego OFF en vivo, mezclado) p50 17,60/p90
  21,1; W1 scene-msaa 5,29→3,79, eye-1x 2,50→1,90; regulador 33 en ambos (>17 ms). `gpu.time` sin timestamp ni estado fov.
- Logs B61 (Logs_Alyx_3): `gpu.time` p50 17,75 ms (B60 17,02; sin mejora), regulador 33 fps; `msaa_materialized` 252 (B60 286)
  pero NO aparece ningún `stores_elided`/`elide_miss` → 0051 sin efecto visible o sin log (unverified); compositor p50 6,4 ms
  (rcas fused); RAM pico 5,6 GB, mín. libre 2,6 GB, 0 avisos; archivo ON: `archive_memory` +378 MB, 1 `archive_save
  Failed_to_generate_machO`, shaders compilados 276 (vs 2132); fondo: `[guest] paused`, 0 `gpu.err code 7` (arreglo OK).
- Logs B60: memoryless activo pero 286 `msaa_materialized why=None` (= store del cliente); footprint 5,9 GB con 2,2 GB libres
  (límite real ~8,1 GB; los 6144 MB = heap fijo de VPVulkan `physical_device.cpp:152`, no limita: Metal usó ~3 GB); GPU juego
  20,7–22,6 ms; compositor 5–9 ms (antes 2,4–6: posible regresión del RCAS fusionado, unverified); A/B Lab: ALL −1,78 ms,
  ningún bit > umbral; 14 `gpu.err code 7` + 34 `gpu.hang.enc` tras `scene phase -> background`.
- B60 y anteriores: `notas/builds.md` (sección B60).

## Estado actual
- 100 % funcional (visor): Steam (login+Guard, Cloud), firma, 90 libs, prewarm ~4150 pipelines; VPKEngine 0 cuelgues
  desde B17, MSAA 4x, amplificación de vértices, occlusion culling medido, `VP_CB_ORDER=2`; foveado VRR (periferia 10 %,
  VPKTAA en periferia; post NO foveado); compositor skip-same; regulador 50/33 (100 Hz) o 45/30 (90 Hz) con tiempo de
  GPU exclusivo; reloj del juego `klvr_game_hz`; OpenVR cabeza + 2 Sense, dedos, altura, subtítulos, idioma, pausa.
- Pendiente de validar: B58 (altura real, `vk.fail`), B59/B60 (RCAS fusionado sin costura).
- B61 al validar: `stores_elided`/`elide_miss` y `msaa_materialized` (¿baja de 286?, ¿frames corruptos?); `[cp] gpu composite`
  fusionada vs pase aparte (misma zona); arranque y footprint con archivo ON vs OFF; volver de segundo plano sin
  `gpu.err code 7` del guest ni flash negro; si visionOS mata la app en fondo (unverified).
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
