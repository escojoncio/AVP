# Builds B46–B59 — qué hace cada mecanismo

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
