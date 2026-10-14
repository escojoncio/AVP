# Bitácora — AVP

Half-Life: Alyx (build ARM64 Linux de Steam) nativo en Apple Vision Pro. Todo en el visor: Steam oficial → descarga →
conversión ELF→Mach-O (`klepton_ld` en proceso) → firma on-device (`vp_codesign` + .p12) → precompilado de pipelines →
juego. Gráficos: **solo VPKEngine** (repo `escojoncio/VPKEngine` = `vpkengine.ref` + `vpkengine-patches/` 0011–0033).
MoltenVK solo como referencia de diagnóstico. Sin MetalFX (no sirve en VR). Plan: `PLAN.md`. Historial completo:
`git log -p bitacora.md`. IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: B30).

## 100 % funcional en el visor
- Steam (login + Guard, propiedad paquete 134870, descarga build 25487405, Cloud), .p12 como primer paso, firma on-device.
- Preparación: .deb → 90 libs convertidas y firmadas, `pipelines.foz`, prewarm ~3600 pipelines que ESPERA a la caché de
  shaders del SO (`kl_fossilize.cpp` → `vpvk_device_wait_compiles`).
- Juego con VPKEngine: 0 cuelgues de GPU desde B17, imagen correcta con MSAA 4x, 33 fps estables (governor 1/3 de
  100 Hz), sin explosiones de vértices (B24, `0029`). OpenVR (cabeza + 2 Sense), idioma, pausa (PS izq./Menu 1 s),
  ajustes en vivo (`AVPSettings.applyLive`), logs en `Logs Alyx/` (+ copia en carpeta AVP cada 20 s).
- Diagnóstico integrado: capturas PNG de ojos (frames 2/30/120/600/1200/2400/3600), L3+R3 = captura + volcado por pase
  de 12 command buffers (`0028`/`0029`), `gpu.order`, `gpu.hunt`, `[gputime]`, `[openvr] frames`.

## Historial resumido (detalle: `git log -p bitacora.md`)
- B11–B16: prewarm/log, cuarentena, traductor v2, archives Metal off (`VP_PIPELINE_ARCHIVE=0`).
- B17 (`0021`): cuelgues = resolve Metal desde depth 1x → copia (`resolveAsCopy`); cazador de cuelgues; colas del
  compositor/TAA se renuevan tras error propio.
- B18 (`0022`–`0024`): negro = chunks suspend/resume limpiaban (RESUMING→Load); traductor v3 (`0023`); 12 command
  buffers en vuelo, cola Metal exportada, adjuntos por vista de formato.
- B19 (`0025`): prewarm espera la caché del SO; holds a 15 ms tras timeout.
- B20 (`0026`): renderArea → renderTargetWidth/Height.
- B21: juego siempre a MSAA 4x; foveado Klepton (rate map) con VPKEngine; presets M2/M5 (`KL_VRR_MAP=wide`); VPKTAA
  periferia fase 1 (filtro espacial en el unwarp, `kl_reproject.c` `kl_eye_recon`).
- B22 (`0027`): multiview escribe `[[viewport_array_index]]` + viewport/scissor por vista (regla fija en la bitácora
  de VPKEngine: la capa del rate map la elige el índice de viewport).
- B23 (`0028`): A/B cola GPU 3/12 + L3+R3. Con 3: sin explosiones pero CPU y GPU en serie (18-20 fps).
- B24 (`0029`): CAUSA de las explosiones: solo el 1.er encoder de cada command buffer esperaba al anterior (recursos sin
  hazard tracking) → encoder `vpgpu.join` que espera toda la cola anterior, todos lo esperan; slots reutilizados solo
  cuando su frame terminó. Cola 12 por defecto (`avp.gpuQueueDepth24`). Ajuste "Zona nítida" 30-70° (`KL_VRR_WIDE_DEG`).
  Medido (Logs_Alyx_17): `gpu.order overlapped=0 out_of_order=0 slot_busy=0`, 33 fps.
- B25 (`0030` + `kl_gpu_time.m`): (1) el pase de overlays tras el resolve (menú, manos, UI 3D: RGBA8 sRGB 2784x2208,
  112 draws, 1x con depth resuelto) no se foveaba → ojo/UI mal; ahora el hook fovea todo pase de ojo con 2 capas y
  depth 2D-array también a 1x (log `[vrr] foveating a 1x layered pass with depth` / `... NOT foveated`). (2) mapa wide
  a 32 zonas evaluadas en su centro (antes 16 y "punto más cercano": zona nítida +~13° por lado); zonas por mapa en
  `g_vrr_maps[].zones`. (3) crash `Impl::texture()` bajo submit: `tableMutex` (metal2) + `resMutex_` (core).
  **Confirmado por el usuario (Logs_Alyx_18): el renderizado de los ojos ya es correcto.**
- B26: (1) compositor: si la última imagen completa del juego (`kl_ovrp_last_complete_stage` + serial) es la misma
  que mostró el último composite, el refresco se abandona ANTES de `queryDrawables` (visionOS reproyecta el último
  drawable); la pose se sigue publicando cada refresco (pacing del juego intacto); máx. 3 saltos seguidos
  (`skipMax`, `KL_CP_SKIP_MAX`); nunca con panel de carga ni vídeo de carga. `KL_CP_SKIP_SAME`, ajuste «Componer solo
  imágenes nuevas» (`avp.cpSkipSame`, por defecto sí, en vivo). `noteCadence(refreshes:)` divide el hueco; línea
  `alive` añade `skipped(same picture)=N`; HUD "Comp N/s". (2) `KL_GPU_PASSES=t75,t110,t150,t200,t260,t330`,
  `KL_GPU_PASSES_N=40` siempre con VPKEngine (instrumentación TEMPORAL: quitar cuando se decida el siguiente paso);
  `prof_report` promedia sobre los frames realmente perfilados (`nf`) y espera 8 frames antes de resolver.

- B26 FALLÓ: abandonar un frame tras `queryNextFrame`+`startUpdate/endUpdate` sin submit → el siguiente
  `queryNextFrame` aborta (`BUG IN CLIENT`, Logs_Alyx_19). REGLA: todo frame consultado se presenta.
- B27: (1) compositor: un refresco con la misma imagen NO consulta frame: `skipRefreshIfSame()` espera al input
  extrapolado (`predictTiming` del último frame real + k·`displayPeriod`), publica la pose al juego y vuelve; máx. 3
  seguidos (`KL_CP_SKIP_MAX` 1–3); `owedRefresh` mantiene 1 publicación por refresco; el command buffer se crea
  ANTES de `queryNextFrame` (pipeline nulo ya no abandona; `primeDisplay/clearAndPresent` igual). (2) Zona nítida
  REDONDA tipo P.T. en el composite (`kl_eye_sample_round`, uniforms `fov_*` en `KLReproj`, 288 B): círculo de
  `wideDegrees` centrado 10° bajo el eje (matemática de `inset_fragment` de P.T., borde 15 %); fuera, "vista ancha"
  (`buildWideView`, rgba16F, ojo filtrado a la densidad de la periferia, 1 vez por imagen nueva) con `kl_eye_recon`.
  `KL_CP_ROUND=0` = A/B. P.T. también dibuja el inset rectangular y compone un círculo: misma técnica. (3)
  `KL_VRR_PHYS=1`: pases foveados con `renderTargetWidth/Height` = tamaño físico del mapa (el 1.er pase de cada
  textura a área completa, `NSHashTable`); `KL_VRR_PHYS_POST` (post sin mapa) OFF. (4) Perfilador `[passes]` por
  escena (`g<s>` desde `FadeGrid(out)`, `t<s>`), cubre compute/blit con descriptor, sample buffer en el 1.er índice
  libre (VPKEngine usa el 0), guarda de reentrada, se apaga solo si Metal lo rechaza; ajuste «Medir GPU por pase».
  (5) Convars de efectos M2 (`effectsConvars`): `r_ssao` = ajuste «SSAO» (B28: ON por defecto en todos; la fidelidad no se recorta), tabla de fidelidad ahora coherente
  (`sc_disable_spotlight_shadows 0`); Lua con `pcall`, `AVPMISSING/AVPSTUCK`; `KLPERF` vuelca ~34 convars por spawn.
  (6) VPKEngine `0031`: `gpu.excl` (tiempo EXCLUSIVO por encoder, vtx/frag, load/store MB, cada 5 s),
  `VP_CB_ORDER=2` (espera solo por dependencias reales entre command buffers), `VPVK_AMPLIFY=1` (multiview por
  amplificación de vértices de Metal en vez de instancias x2), `VPVK_FETCH_NATIVE=1` (half nativo). Ajustes en app
  «Amplificación de vértices» y «Orden de GPU por recursos», ambos ON (cambiar amplificación = retraducción única).

## Medidas Logs_Alyx_19 / 2_5 (B26)
- 70 % (2112x1728) vs 90 %: juego 19-22 ms vs 22-27 ms → la escena NO escala con píxeles. En el menú el juego pasa de
  ~10 a ~20 ms al aparecer las manos/UI. Pase de escena en juego: un encoder de ~14 ms (span). Compositor 6-17 ms.
- El objetivo 3456x2208 (2592x1728 al 70 %) es el blur de Panorama (eye width x 1,24), sí escala.
- Alyx ARM64 trae foveado propio: FDM (`vr_fdm`, `fove_level`, `fove_square`, `fove_radial_inner/outer/min`,
  subsampled + `unsubsample.vfx_ps`) y radial density masking (`vr_subview_mode` 3 = FixedFoveated2x,
  `vr_foveated_inner/outer_scalar`, `vr_foveated_boundary`). FDM radial no es representable en Metal (rate maps
  separables); VPKEngine no anuncia FDM. Subview stencil es incompatible con nuestro rate map (doble warp).

## Logs_Alyx_20 / 2_6 (B27/B28) — regresiones y arreglo en B29
- Idioma inglés: `kl_driver.c` `argv[40]` (n<39) cortaba `KL_ALYX_PROFILE_ARGS` tras las convars de efectos de B27 →
  `-language spanish` fuera. B29: `argv[160]`, `extra[8192]`; `kl_alyx.c` `args[200]` (era 72).
- Imagen rota (imagen dentro de imagen, bloques negros) + fallo de GPU en el pase overlay 1x: `KL_VRR_PHYS=1` (fuera del
  área física queda un fotograma viejo que post y compositor mezclan). B29: `KL_VRR_PHYS=0`.
- Ojo derecho encogido en una esquina / FOV roto + fallos `metal_faulted` en pipelines `wm4294967280`: `VPVK_AMPLIFY=1`
  (0031). B29: forzado a 0 (toggle quitado de la UI; `vertexAmplification` sin uso). Pendiente: depurar viewMappings
  vs capa/viewport del rate map en VPKEngine antes de reactivarlo.
- `VP_CB_ORDER=2`: sin veredicto (2_6 colgó con él y amplify a la vez). B29: OFF por defecto (clave nueva
  `avp.cbOrder2b`), toggle experimental.
- Real: compositor 6-8 ms → 3,3 ms por frame con `skipRefreshIfSame` (sin crash). La bajada de GPU del juego en menú
  (10-20 → 6-9 ms) NO es válida: el ojo derecho apenas se dibujaba.
- `gpu.excl` (menú, 70 %, con amplify): escena MSAA ~1,0-1,3 ms excl; tonemap RGBA8 2112x1728x2 1,5-1,8 ms (29 MB
  load+store); sombras D32F 4096² ~1 ms; bloom RG11B10F 2048x2048x2 ~1,1 ms; compute vk.comp29 ~0,8 ms. Falta medir
  en juego (ninguna sesión llegó a jugar sin cuelgue).
- Zona nítida redonda: ajuste «Zona nítida redonda (como P.T.)» (`avp.roundFov`, ON).
- Regulador de ritmo (`klvr_platform_klepton.c` `pace_governor`): sube a la base (50) solo con 5 s seguidos de media
  < 15 ms y 0 frames tardíos (> 18 ms); con picos de streaming no sube nunca → 33 fps aunque haya margen.

## Logs_Alyx_21 / 2_7 (B29) — escena negra y bajadas de fps
- ESCENA NEGRA (solo HUD): no era B29. `vpcache/quarantine.txt` traía 9 pipelines de la sesión B28 con amplify
  (page fault f=2754): el cazador bisecó con `verdict=clean` en TODOS los pasos (el cuelgue nunca se repitió) y aun
  así condenó al primer candidato, `vk.comp17` (compute del binning de luces: tile grid 264x216 y color HDR a 0),
  más 8 `metal_faulted` colaterales. B29 los cargaba y saltaba (4096 draws). Confirmado por el usuario: al
  restablecer la cuarentena vuelve la imagen. Arreglo B30: (1) VPKEngine `0032`: el cazador, con un candidato,
  lo vuelve a dibujar (`gpu.hunt confirm`); cuelgue en 12 frames que lo dibujen → `verdict=confirmed` y cuarentena;
  12 frames limpios → `verdict=indeterminate`, nada se guarda. (2) App: `vpcache/quarantine.key` = build VPVulkan +
  VPVK_AMPLIFY/FETCH_NATIVE/VP_CB_ORDER/KL_VRR/KL_VRR_PHYS/FORCE_1X/MOTION/FRAMES_IN_FLIGHT/msaa; firma distinta o
  ausente → se borran `quarantine.txt` y `suspects.txt` (log "cuarentena de otra configuración del motor descartada").
- BAJADAS DE FPS (mirar a un enemigo y atacar / mirar a una zona): GPU estable ~14 ms; el hilo de render del juego a
  40-150 ms; `gpu.frame … cpu_ms` (= solo `compileFrame`) 35-40 ms en el command buffer de escena (`passes=14,
  merged=12`) frente a 0,4 ms en el resto. Causa: `conflicts(acc, acc_[open_])` cuadrático (todos los bindings de
  todos los draws del pase × todos los acumulados del encoder). Arreglo `0033`: accesos plegados por (recurso, rango,
  write, pixelLocal, attachment) con stages OR-eados; listas por encoder indexadas por recurso y escrituras aparte
  (una lectura solo se compara con escrituras). Sintético (14 pases × 300 draws × 14 bindings): 2667 → 5,2 ms; tests
  de `gpu/core` (14) en verde en Linux. Esperado en Alyx: cpu_ms < 1 ms. Parte menor de las bajadas: streaming de
  texturas (`vkCreateImage` 2048² en ráfagas); pendiente `vkCopyMemoryToImageEXT` por región.

## Siguiente (al llegar el log de B30)
1. Log: línea "cuarentena … descartada" al arrancar; `gpu.frame … cpu_ms` del CB de escena en combate (meta < 1 ms);
   `[openvr] frames` render ms en los mismos momentos (mirar enemigo/atacar). Si siguen picos sin cpu_ms: texturas
   (`vkCreateImage` + `vkCopyMemoryToImageEXT` por región) → subida asíncrona / staging.
2. Regulador de ritmo: con el CPU libre, permitir ≤3 % tardíos para subir a 45/50.
3. Amplify: arreglar el ojo derecho en VPKEngine (viewMappings / `[[render_target_array_index]]` / viewport por vista).

## Pendiente menor
- Ajustes en vivo que faltan: resolución/texturas (convars), anisotrópico; activar/desactivar foveado requiere reiniciar.
- Botón PS no capturable (solo "Button Menu"); mitigado por la pausa. QR de Steam. Subir 0011–0030 al repo VPKEngine.
- Investigaciones abiertas de B18: modo polígono LINE ignorado; vistas de aspecto stencil devuelven depth;
  `vkCopyMemoryToImageEXT` espera la GPU por región.
