# Bitácora — AVP

Half-Life: Alyx (build ARM64 Linux de Steam) nativo en Apple Vision Pro. Todo en el visor: Steam oficial → descarga →
conversión ELF→Mach-O (`klepton_ld` en proceso) → firma on-device (`vp_codesign` + .p12) → precompilado de pipelines →
juego. Gráficos: **solo VPKEngine** (repo `escojoncio/VPKEngine` = `vpkengine.ref` + `vpkengine-patches/` 0011–0030).
MoltenVK solo como referencia de diagnóstico. Sin MetalFX (no sirve en VR). Plan: `PLAN.md`. Historial completo:
`git log -p bitacora.md`. IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: B26).

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

## Medidas Logs_Alyx_18 (B25, a2_drainage)
- GPU juego 22-27 ms/frame (menú 22,8); compositor 7 ms/frame en menú, 11-19 ms jugando: componía a 100 Hz la misma
  imagen (~2,3-3,5 ms por composite) → suma 42-46 ms → 16-23 fps (`[openvr] render 42-63 ms`, wait 0). Arreglo: B26 (1).
- Foveado activo: mapa wide 60° = 36 % de píxeles (1536x1428 de 2784x2208). Ahorra poco: el coste no está en los
  píxeles de los pases de escena. 6 pases de ojo 1x RG11B10F (post, sin depth) y el tonemap RGBA8 recorren la textura
  ENTERA 2784x2208 aunque solo el 36 % físico tiene datos (candidato: render area = tamaño físico, ver riesgo de
  scissor > render target sin rate map).
- Comparación P.T. M2: zona nítida a ~0,5x del drawable, sin MSAA, VPKTAA al 80 %; Alyx 2784x2208 MSAA 4x ≈ 3-4x de
  trabajo por ojo. Mapa separable = rectángulo 60°x60° (P.T.: inset 60° x ~49°).
- Consola: `Stencil mask reduces rendering area by: 0.00%` (sin hidden area mesh; visionOS no da uno).
- `gpu.time enc_ms` de VPKEngine son spans solapados (no exclusivos): no sirven para repartir el tiempo.

## Siguiente (al llegar el log de B26)
1. `[cp] alive`: iters/s ≈ 100 (si `queryNextFrame` re-ofreciera el mismo frame tras un salto, iters se dispararía)
   y `skipped(same picture)`; `[gputime]` compositor por frame (esperado ~3-4 ms a 33 fps) y fps estables.
2. Leer las 6 ventanas `[passes]`: tiempo exclusivo por pase (escena MSAA, sombras D32F 4096², RGBA16F 2048x1024,
   post 1x eye-size, tonemap, overlays 1x, UI). Con eso decidir: post al tamaño físico, MSAA 2x, sombras, o vistas
   tipo P.T. (inset + vista ancha) en VPKEngine.
3. Si el usuario ve tirones en contenido pegado a la cabeza (HUD), es la reproyección del sistema en los refrescos
   saltados: comparar con el ajuste apagado.
4. Pendiente gráfico: "algún efecto o sombra" (linterna sin sombra visible); volcar con L3+R3.
5. VPKTAA periferia fase 2 (temporal: jitter + depth linealizada z = 0.95 - 0.0375/d + pose).
6. Renombrar "M2/M5" del launcher (p. ej. "P.T. 60°").

## Pendiente menor
- Ajustes en vivo que faltan: resolución/texturas (convars), anisotrópico; activar/desactivar foveado requiere reiniciar.
- Botón PS no capturable (solo "Button Menu"); mitigado por la pausa. QR de Steam. Subir 0011–0030 al repo VPKEngine.
- Investigaciones abiertas de B18: modo polígono LINE ignorado; vistas de aspecto stencil devuelven depth;
  `vkCopyMemoryToImageEXT` espera la GPU por región.
