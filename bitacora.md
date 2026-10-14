# Bitácora — AVP

Half-Life: Alyx (build ARM64 Linux de Steam) nativo en Apple Vision Pro. Todo en el visor: Steam oficial → descarga →
conversión ELF→Mach-O (`klepton_ld` en proceso) → firma on-device (`vp_codesign` + .p12) → precompilado de pipelines →
juego. Gráficos: **solo VPKEngine** (repo `escojoncio/VPKEngine` = `vpkengine.ref` + `vpkengine-patches/` 0011–0030).
MoltenVK solo como referencia de diagnóstico. Sin MetalFX (no sirve en VR). Plan: `PLAN.md`. Historial completo:
`git log -p bitacora.md`. IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: B27).

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
  (5) Convars de efectos M2 (`effectsConvars`): `r_ssao 0` (M5 1), tabla de fidelidad ahora coherente
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

## Siguiente (al llegar el log de B27)
1. Crash/arranque: `[cp] alive` iters/s ≈ panel, `skipped(same picture)` creciendo; `[cp] round sharp zone on`.
2. `gpu.excl`: tipo con mayor share; en la escena `vtx_ms` vs `frag_ms` (¿limitada por vértices?), `store_mb`/`att=`.
3. `[passes] W# sceneN…` + `by kind`; `[vrr] … render area 2784x2208 -> …` y `full-area first pass` estable.
4. Con amplificación: `vk.translator mode=… amplify=1`, sin `gpu.err what=pipeline`; ambos ojos correctos.
5. `[gputime]` vs 19-22 (70 %) / 22-27 (90 %). Si sigue limitado por vértices: LOD/geom (convars), sombras.
6. Siguiente paso grande si hace falta: vistas tipo P.T. (inset + ancha) en VPKEngine (PLAN §5.1-9).

## Pendiente menor
- Ajustes en vivo que faltan: resolución/texturas (convars), anisotrópico; activar/desactivar foveado requiere reiniciar.
- Botón PS no capturable (solo "Button Menu"); mitigado por la pausa. QR de Steam. Subir 0011–0030 al repo VPKEngine.
- Investigaciones abiertas de B18: modo polígono LINE ignorado; vistas de aspecto stencil devuelven depth;
  `vkCopyMemoryToImageEXT` espera la GPU por región.
