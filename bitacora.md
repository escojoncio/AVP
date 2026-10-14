# Bitácora — AVP

Half-Life: Alyx (build ARM64 Linux de Steam) nativo en Apple Vision Pro. Todo en el visor: Steam oficial → descarga →
conversión ELF→Mach-O (`klepton_ld` en proceso) → firma on-device (`vp_codesign` + .p12) → precompilado de pipelines →
juego. Gráficos: **solo VPKEngine** (repo `escojoncio/VPKEngine` = `vpkengine.ref` + `vpkengine-patches/` 0011–0030).
MoltenVK solo como referencia de diagnóstico. Sin MetalFX (no sirve en VR). Plan: `PLAN.md`. Historial completo:
`git log -p bitacora.md`. IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: B25).

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

## Estado del foveado (para el siguiente log)
- Usuario (B25, por sus ojos): **rendimiento fatal, el foveado no funciona como en P.T. y no gana nada de rendimiento.**
- Lo que hay: el "M2" del launcher es un mapa de Klepton (`MTLRasterizationRateMap`, `kl_gpu_time.m` `vrr_fov_map`,
  KL_VRR_MAP=wide) inyectado por hook a los render passes del juego con target MSAA ≥4x o (B25) 1x con 2 capas y depth;
  NO es el foveado del sistema (el de CompositorServices: `[cp] ... max render quality 0.4`, intocable).
- Medidas previas: B21 mapa wide 60° = 49 % de píxeles, GPU juego 23 ms; sin foveado (B23/B24) 30-37 ms. Ganancia
  real ~30 %, muy lejos de P.T. Motivos conocidos: (a) mapa separable = rectángulo/cruz (≈49 % a 60°, ≈20 % a 40°);
  (b) solo se fovean los pases con el mapa: sombras (D32F 4096², RGBA16F 2048x1024), post/bloom, compute y el
  tonemap van a resolución completa; (c) MSAA 4x a 2784x2208 por ojo; (d) P.T. usa quad views (vista ancha al 10 % +
  inset nítido dibujados por su motor), que aquí exigiría repetir el fotograma del juego con otra proyección.
- Governor: 50 fps exige GPU total < 20 ms (juego + compositor); por encima cae a 33,3 (1/3 de 100 Hz).

## Siguiente (al llegar el log de B25)
1. Leer entero: `[vrr] foveated map (wide N deg, Z zones) ... (N% of the pixels)`, líneas `[vrr] foveating 1x` /
   `NOT foveated`, `[gputime] game avg` y compositor, `[openvr] frames` (render/wait/after), `gpu.order`, crash.
2. Antes de tocar nada (X-Y): medir DÓNDE va la GPU por pase — `VP_PASS_TIMING` existe en VPKEngine (`gpu.passtime`
   por encoder); exponerlo como ajuste de diagnóstico en la app (no .txt) y comparar foveado off / M2 60° / M2 40°.
   Sin ese desglose no se decide entre: bajar MSAA (2x) con foveado, resolución del juego + foveado, foveado de
   sombras/post, o quad views en VPKEngine.
3. Comprobar en capturas que menú/manos salen iguales en ambos ojos y el borde nítido donde en P.T.
4. Renombrar "M2/M5" en el launcher (p. ej. "P.T. 60°") para no confundirlo con el foveado del sistema.
5. Pendiente gráfico: "algún efecto o sombra" (linterna sin sombra visible, captura 3600 de Logs_Alyx_2_4); volcar con
   L3+R3 (incluye el pase D32F 4096² de sombras).
6. VPKTAA periferia fase 2 (temporal: jitter + depth linealizada z = 0.95 - 0.0375/d + pose).

## Pendiente menor
- Ajustes en vivo que faltan: resolución/texturas (convars), anisotrópico; activar/desactivar foveado requiere reiniciar.
- Botón PS no capturable (solo "Button Menu"); mitigado por la pausa. QR de Steam. Subir 0011–0030 al repo VPKEngine.
- Investigaciones abiertas de B18: modo polígono LINE ignorado; vistas de aspecto stencil devuelven depth;
  `vkCopyMemoryToImageEXT` espera la GPU por región.
