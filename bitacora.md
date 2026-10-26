# Bitácora — AVP

Half-Life: Alyx (ARM64 Linux de Steam) nativo en Apple Vision Pro (M2). Steam oficial → descarga → ELF→Mach-O
(`klepton_ld`) → firma on-device (`vp_codesign` + .p12) → prewarm de pipelines → juego. Gráficos: **solo VPKEngine**
(`escojoncio/VPKEngine` @ `vpkengine.ref` = rama `avp-port-main`, **sin parches**: `vpkengine-patches/` vacío; cambios del
motor se hacen en VPKEngine, mapa en su bitácora). Plan: `PLAN.md`.
IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: **B70**, sin verificar en visor).
Builds: solo con `[build]` en el mensaje o dispatch manual; docs con `[skip ci]`.

## Últimos hechos
- B70: motor `8e262a2` (unpack nativo de vértices, kill-exit, buffers inmutables, `VP_KNOCK`; detalle en bitácora de
  VPKEngine). `AVPSettings.swift`: `VPVK_FETCH_NATIVE=3` (~509; cambia translator id → retraducción + prewarm en 1.er
  arranque); ajuste «Diagnóstico de coste por shader» (`shaderKnock`, `avp.shaderKnock`) → `VP_KNOCK=auto` + fuerza
  `VP_EXCL_TIMING=1`; toggle en `AVPSettingsView.swift` ~301. Siguiente: leer `gpu.knock.top` y atacar los shaders top.
- Logs_Alyx_13 (B69, MSAA4/65°, nominal, 100 Hz, ~1,5 min): `overlap on nspt 1.0/1.0`; comp corregido med. 1,2 ms
  (raw 3,7); juego med. 16,3 (7–19,9); 50 fps 17 s y caída rápida (21,09 ms, 13/14 late); variante compositor lista
  167 ms; wide par 33/s; 0 errores; RAM pico 6,2 GB. Sin API pública para elegir Hz (solo `minimumFrameRepeatCount`).
- Archivo_12 (B69, MSAA4/65°, 5m27s): térmico nominal→fair 2:03→serious 4:38; juego sube 16,6→19,5 ms por minuto
  (sin cambio de zona = throttling); comp 1,2 (raw 3–7); ~17 s a 50 fps, resto 33; ventanas avg 18,5–19,6 vs barra
  18,4, distribución unimodal (sin frames alternos; pase MSAA ~965 draws, vtx 5,4/frag 10,1 ms cada frame); 1 stall 5 s.
- Descartado quitar stencil: escena = VK 129 D24S8 (→ Metal D32FS8), stencil usado (máscara VR, separate stencil usage
  0xa3, input attachment). `GetHiddenAreaMesh` vacío a propósito (`klvr_system.cpp:97`, reproyección puede mostrar
  todo el ojo); periferia ya al 10 % por VRR → ganancia de máscara pequeña (unverified).
- B69: motor `6151f72` (export `vpgpu_metal2_cb_busy_intervals`; HeavyGeometry sin doble conteo en multiview por
  instancing — Alyx usa amplificación y NO estaba afectado; `verts=` en `gpu.frame`).
  - Regulador (`klvr_platform_klepton.c` `pace_up_frac` ~237, promoción ~346): sube a la base si avg < min(`KL_PACE_UP_PCT`
    (92 %), 0,95·presupuesto − comp·(1−fb/base)) con ≤5 % late; log `pace.gov ... need=<barra> comp=`.
  - `kl_gpu_time.m`: compositor sin solape con el juego (anillo 2048 intervalos del motor, resta perezosa en
    `kl_gpu_time_frame_ms`, en ticks; guarda nspt ±5 %); `KL_COMP_OVERLAP=0` off; logs `[gputime] overlap on/off nspt`,
    `comp_raw=` en `[gputime]`.
  - Compositor: `kl_reproject_f` con function constants 0–5 (recon, srgb, rcas, round, lod0, chroma; variantes async,
    genérico hasta listo; `KL_CP_SPECIALIZE=0` off); funciones del lib reproject creadas con constantValues vacío
    (`reprojFn`, `kl_view_mtl.m` ~68); `level(0)` en taps del ojo si 1 mip; wide/recon en par con 2 texturas
    (`kl_wide2t_f`, 4→2 encoders por composite; `KL_CP_WIDE2=0` off). MSL/Swift sin compilar fuera de CI.
- Logs_Alyx_11/12 (B68, 100 Hz): freno de CPU resuelto (submit 1,2 ms). MSAA2/60°: juego 13,5–15 + comp 3,9 →
  ventanas avg 17,3–17,9 con 0 % late NO subían (barra 17,0). MSAA4/65° (térmico fair): juego 18,1, comp 8,9 inflado
  por contención (wide 202x163: 0,19→2,7 ms); real ≈ juego + 3,9. Escena MSAA4: 1 encoder Clear+Resolve, sin store de
  muestras, HeavyGeometry real (>3M vértices ×2 vistas, memBacked); stencil sin uso (census `stencil 0`).
- B68 (`939f447`): motor `6b6fe91` (elisión de estado por draw `VP_STATE_ELIDE`; revertidos blit merge y `VPVK_REPORT_ADRENO`).
  `VPVK_MAX_PENDING_CHUNKS=6` (defecto 2 bloqueaba ~13 ms/frame en vkQueueSubmit), `VP_FRAMES_IN_FLIGHT=16` (cambia `sigKeys`:
  1.er arranque re-prewarm). Ajuste «Identidad GPU Adreno» quitado.
- Logs_Alyx_8/9/10 (B67): presupuesto 2048 OK (pico RAM 5,9–6,4 GB, avail mín. ~2 GB, 4 archivos saltados, 0 compilaciones extra);
  Adreno sin efecto; blit merge 0 fusiones. CUELLO REAL = CPU del motor: render del juego 25–30 ms/frame, 88 % dentro de
  vkQueueSubmit (Σ backend 22–27 ms, ~13 de espera de chunks), GPU ociosa ~10 ms/frame; bajar calidad (MSAA 2x, aniso 8, 60°)
  bajó GPU 18,8→14,5 ms sin subir fps. Estimación tras quitar freno: con MSAA 2x 45 fps a 90 Hz probable, 50 al límite (unverified).
  MSAA 2x sin variantes en caché → compila en juego la 1.ª vez (prewarm no incluye MSAA en firma).
- B67 (`a20b4e4`): motor `4ce51d8`. Presupuesto de archivos corregido en motor
  (B66 abría 29 archivos: filtro de ruido >4×bytes ignoraba el coste real ~13×; +1,2–1,4 GB) → `VP_PIPELINE_ARCHIVE_BUDGET_MB=2048`
  (B65 usaba ~1973), orden más reciente primero. Fusión de blits sin hazard (`gpu.frame blit_barriers= blits_merged=`,
  `VP_BLIT_MERGE=0` off). `VPVK_ZERO_NEW_IMAGES=0` (B65 no ponía a cero). Ajuste «Identidad GPU Adreno» (`reportAdreno`,
  `VPVK_REPORT_ADRENO`): solo vendor/nombre Adreno; B65 tenía identidad Adreno completa (límites Adreno) → A/B no idéntico.
- Logs_Alyx_6/7 (B66 frío/caliente, misma zona): juego `[gputime]` 18,8 ms = B65 (sin regresión; el «15,5» de B62 era `gpu.time`,
  otra métrica); escena 15,9 (vtx 5,7 vs 4,1 en B65, frag 10,1 vs 11,3); compositor 5,1 (B65 8,1); pace.gov 22–24 vs need 17 →
  33 fps. Prewarm frío 211 s (traductor nuevo), caliente 5,6 s; compilación en juego caliente 0,3 s. RAM pico 7,5 GB / avail
  mín. 616 MB (causa: presupuesto de archivos roto, ver B67). Coste por shader ya medido antes (logs 35/36): plano, ninguno >0,8 ms.
- Logs_Alyx_5 (B65, 2m15s a1_intro_world, térmico nominal, panel 100 Hz): `[cp] cb` OK (bad=0): comp.new(wide+recon+comp)
  ~7,5 ms, same ~7,1, black ~1,7 → los 3 pases en 1 cmdbuf, falta reparto por pase. Plan y pacer coinciden (50/33,3); gobernador
  casi siempre en 33 (avg 11–26 vs need 17). 0 `gpu.pso.miss` pese a 238 compilaciones `gpu.pso f=` (log 0053 en ruta equivocada).
  0 fallos `archive_save`. Archivo: 14 abiertos, 2 skip budget, used 1973 MB (>1280: revisar qué cuenta). RAM pico 6368 MB, mín.
  libre 1823 MB (B64: 5641/2550). 41 `gpu.err code=7 Insufficient_Permission (background)` al salir. Stall 5 s cargando libmeshsystem.so.
- B66 (`b500edc`): primera build con VPKEngine main (`avp-port-main` `3f7da04` = main `5939c99` + fases 1–3 portadas;
  ctest 254/254; .mm sin compilar hasta CI). No portado a propósito: bits `VPVK_RUNTIME_OPTS` (0038/0043/0045/0046),
  motion (0009/0010/0020), census/knockout/opt_counters/dump_pipeline_msl (0039/0042: A/B de `kl_gpu_time.m` inoperante,
  fallback dlsym), hang hunter/quarantine (0032), `vpvk_config_set_texture_cap` (nunca existió). `VPVK_MOTION`,
  `VPVK_RUNTIME_OPTS`, `VPVK_TEXTURE_CAP` = no-op. Versiones traductor 13/1/1/1 → retraducción y AOT nuevo en 1.er arranque.
  - `KleptonApp.swift` ~111 `VPGpuBackground` (dlsym vía `dlopen(KL_MVK_DYLIB,RTLD_NOLOAD)`); `Lifecycle.scenePhaseChanged`
    ~265: .background → `vpgpu_set_background(1)`, .active → 0. `KleptonCompositor.swift` ~2380: `vpgpu_shutdown_background()`
    antes de `kl_app_guest_stop()` (y antes de `kl_app_lifecycle_report()` en syncGuest); no en guest retenido.
  - `KL_GPU_PASSES`: `cpCb` (~4512) → un cmdbuf por pase (mfx, fxaa, sharp, mip, wide, recon, comp/layer) en orden; `cmd`
    solo fence+capturas+present. Sin flag idéntico. Splits fuera de `maxFenceBacklog`.
  - Motor nuevo por defecto: extras 1.3 nativas ON (NO poner `VPVK_EXTRA_EXTENSIONS=0`: apaga dynamic_rendering, sync2…),
    slot reuse por frame, resolve 1x→copia, indirect GPU → encoder heavy (más memoria MSAA, `heavy_indirect=` en
    `gpu.frame`), presupuesto archivo real (`gpu.pso.cache open/skipped/open_total used_mb=`), `gpu.pso.miss` en ruta real,
    `vk.perf` 1/s.
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
- Verificar B66 en visor: arranque/retraducción, imagen (dual-source, render area, occlusion), `[cp] cb` por pase con
  «Medir GPU por pase», RAM pico vs B65 (6368 MB) y `used_mb` ≤1280, 0 `gpu.err code=7` al salir, `gpu.pso.miss`.
  Después A/B `VPVK_ASYNC_PIPELINES=0` y `VPVK_MSAA_TILE=0`.
- VPKEngine main = `3f7da04` (fast-forward de `avp-port-main`; VisionQuestPro avisado para subir su ref). `avp-port` remoto obsoleto (base vieja).
- Pendiente: Steam en guest (`steamclient.so` no encontrado).
- Próximo objetivo: coste GPU del compositor 4–8 ms (B60 notó subida desde 2,4–6; posible RCAS fusionado, unverified).
- Problema abierto: zona pesada juego ~23 ms > umbral (17 ms a 100 Hz, 18,9 a 90 Hz); térmico.

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
- `notas/builds.md`: qué hace cada mecanismo de B46–B59 (VPKEngine 0038–0041, regulador, compositor, app).
