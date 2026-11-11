# Builds B46–B79 — qué hace cada mecanismo

## VPKEngine
- `0038`: `vpgpu::gRuntimeOpts` (`vpgpu_metal2_set_opts`): bit0 esperas solo a productores (`producerWaits`, solo con
  `cbOrder`), bit1 clear skip de profundidad (NUNCA aplicar), knockout (`vpgpu_metal2_set_knockout`), censo, contadores
  (`vpgpu_metal2_opt_counters`). Test `producers` en `gpu/core/tests`. `VPVK_RUNTIME_OPTS=0` desde B52.
- `0039`: censo con detalle (`vpgpu_metal2_census_detail`), `vpgpu_metal2_dump_pipeline_msl(key, dir)`.
- `0040`: tablas constantes de programa (`constant uint4 vp_k<slot>[]`), `VPVK_DUMP_MSL=<dir>`.
- `0041` (B58): `vk.fail ...` en fallos de alloc/bind/arenas/pipelines/fences/DEVICE_LOST con footprint/avail; bind
  rechazado sigue devolviendo VK_SUCCESS.

## Klepton
- `kl_gpu_time.m`: test A/B (`KL_ABTEST=1`, off; espera menú, censo, máscaras, knockout por mediana exclusiva,
  `Logs Alyx/abtest-result.txt`); `[gap]` (KL_GPU_GAP, cada 15 s, 8 frames); mapa de foveado también con MSAA x2;
  `kl_metal_allocated_bytes`.
- Regulador `klvr_platform_klepton.c`:
  - `pace_plan`: fallback 30 a 90 Hz (umbral 29,5; también en `kl_app.c`, B54).
  - `pace_governor` (B53/B55): bajada ≥0,3 s y ≥10 frames con >40 % tarde por GPU o >25 % imágenes tarde, o >15 %
    refrescos perdidos (dt de `klvr_plat_wait_frame`). Vuelta tras 10 s <85 % con ≤5 % tarde, back-off 10→120 s.
  - `KLVR_PACE_FALLBACK`: 0 siempre base, 1 auto, 2 siempre fallback (selector «Fotogramas», `avp.fps`).
- `kl_app.c`: running start 9 ms; `mem_relief_tick` + `[mem] breakdown` cada 30 s; `keep_previous_console`.
- `kl_fault.c`: últimas 40 líneas de console.log en SIGABRT/SIGTRAP.
- Manos (B56): `klvr_plat_hand_raw` adelanta pose (refrescos−1)/2 periodos (`KLVR_HAND_HOLD_PREDICT`).
- Altura real (B58): `KleptonFloor.swift` + `klvr_plat_set_floor_y`/`klvr_plat_height_shift` (`KLVR_REAL_FLOOR`).
  La altura manual guardada se suma encima.

## Compositor (`KleptonCompositor.swift`)
- skip-same: 1 composición por imagen nueva. Log `[cp] refreshes/s: T = composed new N + recomposed same S ...`.
- `kl_wide_f` máx. 2x2 taps; coste por imagen nueva 3–6 ms (composición 1,7–2,8 + vista ancha 2×0,46–1,52 + recon).
- B59 RCAS «Nitidez del centro» (`KL_CP_SHARP`, `avp.centerSharp`, def. 50 %): solo en la zona de tasa completa medida
  en el `MTLRasterizationRateMap` (`sharpZones`, `fullRateZone`), acepta `.type2DArray`, textura cacheada por slot,
  pipeline fallido no se recompila (`sharpPipeFailedFmt`), caché por mapa/tamaño/capas/bottomUp, cuantizado al 5 %.
  Logs `[cp] centre sharpness ...`, `[cp] eye sharpen (RCAS) first run ...`.

## App
- `avp.schema` = 53 (borra `avp.*` una vez salvo claves guardadas). Presets M2/M5/Personalizado (M2: 70 %, tex 2048,
  foveado 70°/10 %, VPKTAA 100 %/1.0, aniso 16, MSAA 4, SSAO). MSAA No/x2/x4; sin MSAA no hay foveado
  (`foveationUsable`). MoltenVK solo fallback automático. Selectores segmentados con título visible.

## B60 (detalle movido de la bitácora)
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

## B62–B76: historial movido de la bitácora (más reciente primero)
- Logs_Alyx_16 (B73): reparto de shaders plano; coste propio de Alyx (≈30 samples, PCF 4 taps ×3 cascadas, bucle de
  luces); regulador correcto (baja con 2 ventanas >19,0 ms, sube <18,4). Knockout: L3+R3 en partida con
  «Diagnóstico de coste por shader» (`KleptonControllers.swift stickClick` ~574; HUD `KleptonCompositor.swift` drawKnockHud).
- B70: motor `0122e9d` (unpack nativo de vértices, kill-exit, buffers inmutables, `VP_KNOCK`; detalle en bitácora de
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
- B69: motor `5faf1cf` (export `vpgpu_metal2_cb_busy_intervals`; HeavyGeometry sin doble conteo en multiview por
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
- B68 (`5c1733d`): motor `ec0e68d` (elisión de estado por draw `VP_STATE_ELIDE`; revertidos blit merge y `VPVK_REPORT_ADRENO`).
  `VPVK_MAX_PENDING_CHUNKS=6` (defecto 2 bloqueaba ~13 ms/frame en vkQueueSubmit), `VP_FRAMES_IN_FLIGHT=16` (cambia `sigKeys`:
  1.er arranque re-prewarm). Ajuste «Identidad GPU Adreno» quitado.
- Logs_Alyx_8/9/10 (B67): presupuesto 2048 OK (pico RAM 5,9–6,4 GB, avail mín. ~2 GB, 4 archivos saltados, 0 compilaciones extra);
  Adreno sin efecto; blit merge 0 fusiones. CUELLO REAL = CPU del motor: render del juego 25–30 ms/frame, 88 % dentro de
  vkQueueSubmit (Σ backend 22–27 ms, ~13 de espera de chunks), GPU ociosa ~10 ms/frame; bajar calidad (MSAA 2x, aniso 8, 60°)
  bajó GPU 18,8→14,5 ms sin subir fps. Estimación tras quitar freno: con MSAA 2x 45 fps a 90 Hz probable, 50 al límite (unverified).
  MSAA 2x sin variantes en caché → compila en juego la 1.ª vez (prewarm no incluye MSAA en firma).
- B67 (`d9c096d`): motor `76652ac`. Presupuesto de archivos corregido en motor
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
- B66 (`c57d09b`): primera build con VPKEngine main (`avp-port-main` `a74ffba` = main `5cf5c80` + fases 1–3 portadas;
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
- B63 regulador (`klvr_platform_klepton.c:348`): línea `[openvr] pace.gov fallback avg= late= need= streak=` cada 10 s en fallback.
  Sin bug: mide juego+comp (`per = game + comp*fb/base`, l.281); subir a 50 exige avg < 17 ms 10–120 s; juego 15–19 + comp 4–8.
- Logs B62 65 %/65°/edge 0,10: busy juego 15,5 ms (vs 21,6 a 70 %/70°), regulador 33 por compositor 4–8 ms (`[gputime]`).
  RAM pico 6,1 GB, mín. libre 2,1 GB. `KL_DISPLAY_HZ=90` con panel 100 Hz (unverified).
- Reparto GPU (fov ON 70 %): scene-msaa 16,6 (vtx 4,0/frag 12,6) + eye-1x 3,4 + blit 1,0; fov OFF scene-msaa 23,7.
  `MTLMathModeFast` ya activo. Mediciones previas: `notas/rendimiento.md`, `notas/builds.md`.
