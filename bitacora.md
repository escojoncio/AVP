# Bitácora — AVP

Half-Life: Alyx (build ARM64 Linux de Steam) nativo en Apple Vision Pro. Todo en el visor: Steam oficial → descarga →
conversión ELF→Mach-O (`klepton_ld` en proceso) → firma on-device (`vp_codesign` + .p12) → precompilado de pipelines →
juego. Gráficos: **solo VPKEngine** (repo `escojoncio/VPKEngine` = `vpkengine.ref` + `vpkengine-patches/` 0011–0035).
MoltenVK solo como referencia de diagnóstico. Sin MetalFX (no sirve en VR). Plan: `PLAN.md`. Historial completo:
`git log -p bitacora.md`. IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: B32).

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

## B30 (Logs_Alyx_21 / 2_7) — resuelto
- Escena negra = cuarentena heredada (el cazador condenaba sin reproducción; 9 pipelines, incl. el compute del binning
  de luces). `0032`: el cazador confirma al sospechoso (`gpu.hunt confirm/confirmed/indeterminate`). App:
  `vpcache/quarantine.key` (build VPVulkan + toggles del motor + VP_MSAA_TILE); firma distinta/ausente → cuarentena y
  sospechosos borrados. Confirmado por el usuario.
- Bajadas al mirar enemigos = `compileFrame` cuadrático (35-40 ms CPU). `0033`: accesos plegados + índice por recurso.
  Logs 22: `cpu_ms` ≤ 2 ms siempre; hilo de render del juego 3-10 ms. Confirmado ("va mejor al ver al enemigo").

## Logs_Alyx_22 (B30) — reparto real de la GPU en juego (33 fps clavados)
- `[openvr] frames`: wait 20-25 ms (el juego espera al regulador), render 3-10 ms. `gpu.time` p50 21 ms, p90 26 ms.
- `[passes]` W5-W7/W11 (a2, en juego): escena MSAA **12,5-17 ms** = vtx 8-10 + frag 5,7-7,9; eye-1x 2,6-3,7 (x11);
  blit 0,8-3; compute 1,2-1,5; other-rt 0,7-1; depth-only 0,4-1. `gpu.excl` fin de sesión (zona densa): 731-815
  draws, excl 20-29 ms, **vtx 11 ms**, frag 11-19 ms, store 58 MB.
- Regulador: 100 Hz → solo 50 o 33. Bajaba a 33 con 2/51 tardíos (3,9 %) y media 16 ms; subía 5 s después; ciclo.
  Por eso "ni con foveado ni sin": ambos quedan entre 20 y 30 ms → 33.
- Vértices = kernel de tiling de Apple (todos los vértices + binning de todos los triángulos, ×2 por multiview por
  instancias: `vr_multiview_instancing=0` → el juego usa VK_KHR_multiview y el traductor lo instancia). No baja con
  foveado ni resolución. Suelo duro hasta la amplificación.
- Convars (KLPERF): `vr_depth_prepass=0` (correcto en TBDR), `vr_stencil_hidden_pixels=1`, `cl_enable_eye_occlusion=1`,
  `vr_shadow_map_culling=1`. `r_occlusion_culling` no estaba en el volcado (B31 lo vuelca y lo fuerza a 1).
  Convars de LOD/cull existentes en el binario ARM64 (strings): `sc_lod_distance_scale_override`, `sc_force_lod_level`,
  `r_size_cull_threshold[_shadow]`, `r_worldlod`, `sc_perdrawculling`, `sc_bounds_group_cull`, `vr_expand_cull_frustum`,
  `r_stereo_true_multiview`, `r_stereo_multiview_instancing`. DECISIÓN DEL USUARIO: nada de LOD/cull que altere lo
  visible; solo optimización pura.
- Attachments MSAA: `att=c0:CR:Persistent,d:CR:Persistent`, `st2+r`, `tile_local=0` en TODOS los frames: el juego
  pide storeOp STORE + resolve; VPVulkan marca persistent todo lo no transient → Metal escribe las 4 muestras de color
  y D32FS8 (2112x1728x2) a memoria cada frame (~230 MB) y el juego solo lee el resuelto (VK_KHR_depth_stencil_resolve,
  `ld2` = clear al inicio).

## B31 — cambios (sin coste de fidelidad)
1. VPKEngine `0034`: MSAA con StoreAndResolve no leído en el submit → `Resolve` desde tile (sin store de muestras).
   `CompileOptions::msaaResolveOnTile`, `VP_MSAA_TILE=0` lo apaga (log `gpu.msaa resolve_on_tile=`). Detección de
   lectura en submit posterior: `msaa_stale=N` en `gpu.frame` (si aparece > 0 en juego, apagar y revisar). Ajuste
   «MSAA resuelto en tile» (`avp.msaaOnTile`, ON). Solo ancho de banda: la textura persistent sigue asignada.
2. `VPVK_FETCH_NATIVE=1` solo (exacto; B29 lo apagó por ir con amplify). Medir `vtx` en `[passes]`/`gpu.excl`.
3. Regulador: deja la base tras 2 s seguidos > 92 % del presupuesto o > 10 % tardíos; vuelve tras 3 s < 80 % y
   ≤ 2 % tardíos (antes: 1 s / 3 % y 5 s / 0).
4. `r_occlusion_culling 1` forzado (AVPMISSING si no existe); KLPERF vuelca los convars de cull/LOD/multiview.

## Logs_Alyx_23 (B31) — medido
- «MSAA resuelto en tile» (`0034`) NO se aplica nunca: `tile_local=0 tile_rejected=2` en todos los frames, escena sigue
  `att=c0:CR:Persistent,d:CR:Persistent store_mb=58.4`; `msaa_stale` ausente solo porque nunca entró. El log no decía el
  veredicto (`gpu.enc` con `mem=` solo salía con `setDetailEvery`, sin env). Imágenes MSAA del juego (census): color
  B10G11R11 s4 usage 0x97 y D32S8 s4 usage 0xa7 (SAMPLED + INPUT_ATTACHMENT + TRANSFER): candidatos `SampledRead`
  (lectura por muestra en el mismo pase) o `Partial`/`OtherEncoder`; sin confirmar.
- `VPVK_FETCH_NATIVE=1`: vtx igual (8,6–11,8 ms en escena). Se deja (exacto).
- `VP_CB_ORDER=2` toda la sesión (el usuario lo activó): 0 cuelgues, 0 explosiones, `out_of_order=0`,
  `overlapped=14746`. Default ON desde B32.
- 33 fps clavados: regulador sube a 50 y cae (GPU 23–26 ms/frame en juego: escena 13–18 = vtx 8–12 + frag 6–8, post 3,4,
  compute 1,6, compositor 3,3). Para 50 fps hacen falta ≤18 ms: faltan 5–8 ms. Fuentes sin tocar fidelidad: MSAA en tile
  real (~2–3 ms), instrumentación (algo), amplificación de vértices (~5 ms, la única que llega).
- La pantalla va SIEMPRE a 100 Hz (medida); el ajuste «90 Hz» solo cambiaba lo que se le decía al juego.

## B32 — cambios
1. VPKEngine `0035`: `CompiledFrame::msaaRejects` + log `gpu.msaa rejected f= enc= slot= why=<TileVerdict> tex= WxHxL sN
   mips= type= layer_count= layer= persistent= transient= load= attached_in= first_read= last_use= multi= sampled=
   elsewhere= bad_fetch=` (12 primeras + las de 1 frame cada `VP_FRAME_DETAIL`, tope 120). `VP_FRAME_DETAIL=N` (env
   nuevo) → `gpu.enc ... tile=c0 mem=d:SampledRead` cada N frames; la app pasa 3000.
2. Limpieza de ajustes (`AVPSettings`/`AVPSettingsView`): quitados res. dinámica, memoria de texturas (ahora derivada del
   tamaño máximo: 1024→1536, 2048→2560, 4096→2816 MB), presets M2/M5/Personalizado (→ `foveationOn`, clave `avp.fovOn`,
   migra de `avp.fov2`), zona redonda (siempre), 90/100 Hz y «dibuja a la mitad» (fijos: guest 90 Hz, pace 45, fallback),
   «componer solo imágenes nuevas» (fijo ON), motor MoltenVK (solo si la build no trae VPVulkan), cola GPU (12),
   «MSAA en tile» (fijo ON), amplificación. Diagnóstico: capturas (default OFF; `KL_CAPTURE`/`VP_DUMP_FRAME` solo con
   ellas), «Medir GPU por pase» (default OFF, clave `avp.gpuPasses2`; `VP_EXCL_TIMING` va con ella), «Orden de GPU por
   recursos» (default ON, clave `avp.cbOrder2c`). Pantalla: Imagen / Foveado / Texturas y efectos / Juego / Diagnóstico.

## Siguiente (al llegar el log de B32)
1. `gpu.msaa rejected ... why=`: arreglar el veredicto en `placeTiles` si es resoluble (p. ej. `Partial` por
   layers/layerCount, `LoadsContents` por stencil). Si es `SampledRead` (el juego lee las muestras en el mismo pase)
   no se puede poner en tile: quitar `0034` del todo. Confirmar en `gpu.frame`: `tile_local=2 saved_mb>0` y
   `store_mb` de la escena bajando de 58.
2. fps con la instrumentación apagada (`[openvr] frames`, regulador): ¿sube a 50 en algún tramo?
3. AMPLIFICACIÓN DE VÉRTICES (vtx 11 → ~6 ms). Bug (B27/B28): ojo derecho encogido en una esquina + page fault en el
   pase overlay 1x con pipeline `wm4294967280` (= variante con write mask c0=0: dibujo solo depth/stencil, p. ej.
   hidden-area/oclusión de ojo). Pistas: viewMappings vs capa del rate map por `[[viewport_array_index]]` (`0027`); los
   VS que escriben Layer/ClipDistance siguen instanciados (`SpirvInterface::amplified=false`): mezcla en el mismo pase.
4. Streaming de texturas (`vkCopyMemoryToImageEXT` espera la GPU por región) → staging asíncrono.
5. Compositor 3,3 ms por imagen nueva: perfilar `kl_reproject` por etapa.
6. Hidden area mesh: comprobar que klvr devuelve malla para la lente del Vision Pro.

## Pendiente menor
- Ajustes en vivo que faltan: resolución/texturas (convars), anisotrópico, zona nítida; activar/desactivar foveado requiere reiniciar.
- Botón PS no capturable (solo "Button Menu"); mitigado por la pausa. QR de Steam. Subir 0011–0030 al repo VPKEngine.
- Investigaciones abiertas de B18: modo polígono LINE ignorado; vistas de aspecto stencil devuelven depth;
  `vkCopyMemoryToImageEXT` espera la GPU por región.
