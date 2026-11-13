# Bitácora — AVP

Half-Life: Alyx (ARM64 Linux de Steam) nativo en Apple Vision Pro (M2). Steam oficial → descarga → ELF→Mach-O
(`klepton_ld`) → firma on-device (`vp_codesign` + .p12) → prewarm de pipelines → juego. Gráficos: **solo VPKEngine**
(`escojoncio/VPKEngine` @ `vpkengine.ref` = rama `avp-port-main`, **sin parches**: `vpkengine-patches/` vacío; cambios del
motor se hacen en VPKEngine, mapa en su bitácora). Plan: `PLAN.md`.
IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: **B80**, sin verificar en visor).
Builds: solo con `[build]` en el mensaje o dispatch manual; docs con `[skip ci]`.

## Últimos hechos
- B81 (en curso, sin compilar ni probar): motor `66bb76d` (origin/main, 40 commits desde `ede5a89`; lower 13 / emit 12 /
  driver 1 sin cambios → marker `translator` "l13e12" sin tocar). `vpkengine.ref` actualizado. `AVPSettings.swift`:
  `depthTile` (`avp.depthTile`), ON = motor; solo exporta `VPVK_DEPTH_TILE=0` si se apaga (entra en firma de cuarentena
  y en `warmVariant` como `|dtile0`; el motor lo cachea por proceso: exige reiniciar la app); `AVPLaunch.swift` `unsetenv`;
  `AVPSettingsView.swift` Toggle en Diagnóstico. `VPVK_MSAA_STRICT` solo lo lee `depthTileOn()` (redundante, sin ajuste). Motor nuevo activa por defecto depth-tile y
  MSAA dead-store (sin probar en Alyx; riesgo: regresión visual/PSO). ABI vpvk_* usada por AVP sin cambios (solo
  añadidas `vpvk_texture_budget`, `vpvk_hide_index_count`, no conectadas); `vpvk_motion_get` y
  `vpvk_config_set_texture_cap` no existen en el motor (dlsym tolera; TAA sin vectores, texture_cap sin efecto).
  Pendiente: revisión adversarial Opus, build única.
- B80 (motor sigue `ede5a89`): `AVPSettings.swift` `amplifyClip` ON por defecto (clave `avp.amplifyClip2`) e
  `invariantPos` OFF (`avp.invariantPos2`, = código de vértices de B78); env `VPVK_MSAA_RELEASE_FRAMES=0` (respaldo
  MSAA pegajoso: en Logs_22 se liberó/reasignó 3 veces, 352 MB, 1.ª reasignación `vk.hitch backend_ms=74`);
  `kl_app.c mem_relief_tick`: con avail < 768 MB llama a `vpvk_trim_memory(2)` (dlsym, ≥30 s; antes solo
  `malloc_zone_pressure_relief`, que devolvía 0 MB); `AVPPrepare.swift` `robust.mode` incluye `warmVariant`
  (`|clip`, `|invpos0`): purga recetas/archivos al cambiar esos modos (1.er arranque: prewarm completo).
- Revisión de código y logs (2026-11-11, sin visor), hechos medidos:
  - El coste escala con píxeles físicos: Logs_20 60 % (2,25M px) juego med. 13,3 ms; Logs_19 65 % (2,74M) 16,9;
    Logs_21 85 % + periferia 30 % + zona 70° (6,28M, térmico fair/serious) med. 21,1, p90 30,8.
  - Pase principal (Logs_18/19, 65 %, ~930 draws): excl 12,3–13,1 ms = vtx 3,8–4,1 + frag 8,8–9,0; cadena post
    (16 encoders) 1,56 ms; knockout: vs `6a91ac74` + fs `3f839e3b` (140 draws) = 6,9 ms, su fs trivial solo 1,1.
  - Juego a periodo fijo (20/30 ms), sin correlación con la GPU (no va serializado). Los CB del compositor esperan
    al encoder principal (sin preempción): commit→fin 7–8,7 ms.
  - Samplers: el juego crea 2 estados aniso 16 y 2 aniso 8; `VPVK_ANISO=16` fuerza 16 además en trilineal+wrap sin
    aniso y sube 8→16 (13/64). Con VRR, donde tasa x ≠ tasa y la huella es anisótropa (hasta 1/periferia): coste sin medir.
  - El juego usa queries de oclusión (pool tipo 0) y timestamps (tipo 2).
  - Motor `ede5a89` vs `38d6fef`, sin medir y sin tocar: varyings enteras < 4 comp. salen como uint4 (también
    `vp_view`, loc 63), `bias(sbN)` en cada muestreo, guardas por atributo en el fetch de vértices (no dependen de
    `VPVK_ROBUST`). Main `09a6e9b` activa por defecto depth-tile y dead-store nuevos (sin probar en Alyx): no adoptado.
- B79: motor `ede5a89` (historial reescrito; traductor lower 13 / emit 12 / driver 1). `AVPPrepare.swift` marcador
  `translator` "l13e12" (subirlo si cambian lower/emit). `VPVK_AMPLIFY_CLIP`: vertex shaders con ClipDistance
  independiente de la vista siguen amplificados. `VPVK_INVARIANT_POS` (motor: ON por defecto, `[[position, invariant]]`);
  `AVPLaunch.swift` ~56 hace `unsetenv` antes de aplicar el env. Logs: `gpu.amp`, `gpu.split`, `vk.query_stats`.
- B78: motor `38d6fef` (`vpvk_dump_pending`, prefijo `vk.pending`). `kl_app.c` stall_dump_thread ~140 lo llama por
  dlsym en los stalls de 5/15 s.
- Logs_Alyx_22 (B77): al abrir el menú de pausa (23:05:01) el juego dejó de enviar frames (stall 5 y 15 s → negro).
  Hilo 0xa963: libengine2→libclient→libpanorama→libresourcesystem→librendersystemvulkan→cond_wait. Causa sin
  confirmar. RAM pico 7,36 GB, avail_min 827 MB (80 % + MSAA 4x).
- B77: re-fase del pacer (`kl_app.c` guest_pace_wait ~1779-1823, `KL_PACE_REPHASE` defecto 1; el regulador ignora el
  intervalo re-fasado, klvr_platform_klepton.c ~318); `[cp] cadence hist`; modo fijo 30/33 alimenta late/miss;
  `[diag] pace n/a(zero)` sin resolver. Detalle de B62–B76: `notas/builds.md`.

## Estado actual
- 100 % funcional (visor): Steam (login+Guard, Cloud), firma, 90 libs, prewarm ~4150 pipelines; VPKEngine 0 cuelgues
  desde B17, MSAA 4x, amplificación de vértices, `VP_CB_ORDER=2`; foveado VRR (VPKTAA en periferia; post NO foveado);
  compositor skip-same; regulador 50/33 (100 Hz) o 45/30 (90 Hz) con tiempo de GPU exclusivo; OpenVR cabeza + 2 Sense.
- B80 sin verificar en visor. Medir con sus logs: `gpu.amp draws_amp= draws_inst= by: clip=` (cuántos draws eran
  instancing por ClipDistance), `vk.query_stats`, `[mem] engine trim`, `[gputime]` en la misma zona que B78/B79.
- Sin hacer: umbral de tile en caliente (`vpgpu_metal2_set_tile_max_vertices`, canario) → respaldo MSAA memoryless
  (−350 MB) con riesgo de tirón al materializar; aniso solo en samplers que el juego marca (cambia lo visible).
- Abierto: negro al pausar (leer `vk.pending` si se repite); `[diag] pace n/a`; Steam en guest (`steamclient.so`).
- Límite medido: a 85 %/periferia 30 % la GPU (21–31 ms) solo da 30/33 fps; 50 fps cabe a 60–65 %/periferia 10 %.

## Decisiones vigentes
- Sin MetalFX; MoltenVK solo fallback automático; nada que cambie lo visible (LOD, cull, `vr_expand_cull_frustum`,
  SSAO on, sombras, MSAA): el rendimiento sale de resolución y optimización pura.
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
- VPKEngine `gpu/metal2/src/metal_backend.mm`, `gpu/vulkan/src/{pipelines,commands,recipes,entry}.cpp` (rama `avp-port-main`).

## Índice de notas
- `notas/rendimiento.md`: reparto del frame, hallazgos Logs_34–47, conclusión e ideas pendientes de rendimiento.
- `notas/builds.md`: qué hace cada mecanismo de B46–B59 e historial de B62–B76 (logs, regulador, compositor, motor).
