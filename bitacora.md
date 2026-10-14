# Bitácora — AVP

Half-Life: Alyx (build ARM64 Linux de Steam) nativo en Apple Vision Pro. Todo en el visor: Steam oficial → descarga →
conversión ELF→Mach-O (`klepton_ld` en proceso) → firma on-device (`vp_codesign` + .p12) → precompilado de pipelines →
juego. Gráficos: **solo VPKEngine** (repo `escojoncio/VPKEngine` = `vpkengine.ref` + `vpkengine-patches/` 0011–0035).
MoltenVK solo como referencia de diagnóstico. Sin MetalFX (no sirve en VR). Plan: `PLAN.md`. Historial completo:
`git log -p bitacora.md`. IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: B40).

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

## Logs_Alyx_25 (B32) — medido
- MSAA en tile (`0034`): FALSA PREMISA. `gpu.enc ... mem=c0:Persistent,d:Persistent` y ninguna línea `gpu.msaa rejected`:
  el store de la escena es `R` (= solo Resolve: el juego pide storeOp DONT_CARE + resolve), no StoreAndResolve, así que
  `0034` nunca entra y las muestras NUNCA se escribían a memoria. Los 58 MB de `store_mb` son los destinos del
  resolve (color RG11B10F + depth, 2 capas). `Persistent` solo significa "no memoryless" (memoria, no ancho de banda).
  `0034`/`0035` quedan (inocuos). No hay ganancia posible ahí.
- Sin instrumentación: tramos a 50 fps reales (~1,5 min seguidos; regulador: GPU 11,9–14,6 ms por frame de 50) y
  caídas a 33 en zonas densas (24–33 ms/frame). Ritmo final: 33 la mayor parte del tiempo. La diferencia entre zona
  ligera y densa es ~2x: geometría (vtx) sigue siendo el límite.

## B33 — cambios
1. Dedos reales: `KleptonControllers.fingerCurls/publishFingers` (ángulos sumados por cadena de articulaciones ARKit →
   curl 0..1 por dedo) → `kl_ovrp_set_finger_curls` / `kl_ovrp_finger_curls` (frescura 0,3 s) → `klvr_plat_finger_curls`
   → `klvr_input.cpp curls_for` (máximo entre botones y manos) en `GetSkeletalBoneData`/`GetSkeletalSummaryData`.
   Ajuste «Dedos reales» (`avp.handFingers`, ON) = `KL_HANDS=1` (pide permiso de manos). Log cada 30 s:
   `[input] fingers with a Sense controller in hand: left tracked N/M, right N/M` → dice si visionOS da manos con el
   mando sujeto (VisionQuestPro observó que NO en versiones anteriores).
2. Ajuste de prueba de amplificación de vértices (sustituido en B34, ver abajo).

## Logs_Alyx_26 / 2_8 / 2_9 (B33) — medido
- Dedos reales: `[input] fingers with a Sense controller in hand: left tracked 0/N, right 0/N` toda la partida →
  visionOS NO da manos trackeadas con el Sense sujeto. La función solo actúa con las manos libres (pie del ajuste).
- Amplificación de vértices (`VPVK_AMPLIFY=1`): CORRECTA. Capturas 1200/2400/3600: los dos ojos bien, foveado centrado
  donde toca en cada ojo (ojo 0 nítido al 63 %, ojo 1 al 37 %); 0 cuelgues, 0 `gpu.hunt`, 0 `metal_faulted`. Escena
  MSAA: `vtx_ms` 8–12 → **~4 ms** (668 draws, excl 10 ms frente a 13–18). Lo que B29 vio roto no se reproduce
  (los fallos de entonces venían de `KL_VRR_PHYS=1`).
- Los 20 fps del final del test 2 NO son la amplificación: **el compositor midió el panel a 50 Hz al arrancar**
  (`display rate SETTLED at 50.005 Hz`: los 120 fotogramas de cebado se mostraron 2 refrescos cada uno y pasaron por
  "cadencia estable"; la sesión 26 midió 100). Con 50 latcheado: refrescos saltados a 20 ms, pacer `1/1 of 50 Hz` →
  `1/2 of 57.3` → `1/1 of 40.8 Hz` (dividía la tasa de publicación de la última ventana, que baja cuando el juego va
  tarde), plan del regulador "base 50, sin fallback" (50/2 = 25 < 32): sin escalón de 33; en zonas densas el juego
  cae a la mitad (compositor: 20 imágenes nuevas/s con el juego a 40). Más tarde en la sesión hubo huecos de 10 ms
  (`display rate 100 Hz (min gap 10.00 ms)`): el panel era de 100 Hz.
- Mapa blanco/vacío al cargar la partida en la sesión 26: sin consola del juego de esa sesión (`console.log` se
  sobrescribe). Pendiente: si vuelve a pasar, zip inmediato con `console.log`.

## B34 — cambios
1. `KleptonCompositor.swift`: el panel nunca va más rápido de lo que es. (a) Latch de arranque: una tasa asentada
   < 55 Hz es una retención ×2/×3 de 120/100/96/90 (`unheldPanelPeriod`; 55–85 se deja: un 60 Hz real existe) → se
   latchea la canónica, log `display rate X Hz is a HELD cadence ... latching Y Hz`. (b) En sesión: `cadenceMinDirect`
   (hueco mínimo SOLO entre presentaciones sin refresco saltado entre medias) → si 3 ventanas seguidas coinciden en
   una canónica > 6 % más rápida que la latcheada: `PANEL RATE RE-LATCHED a -> b Hz`; nunca hacia abajo (una
   cadencia más lenta son retenciones, no un panel más lento; una demotion real a 60 Hz en sesión no se propaga:
   aceptado). (c) `kl_guest_set_panel_hz(hz)` al compositor → `kl_app.c`.
2. `kl_app.c` `guest_pace_wait`: divide la tasa canónica del panel (`g_panel_hz`), no la de publicación de la ventana
   (que solo se usa de respaldo antes del latch y se loguea cada 60 s: `poses published at X Hz (panel Y Hz)`).
   `g_disp_rate` = panel → el plan del regulador (`pace_plan`, pico) ve 100 desde el principio.
3. Amplificación de vértices ON por defecto: clave nueva `avp.amplify` (`AVPSettings.amplify`), toggle «Amplificación
   de vértices» en Diagnóstico (apagar = instanciado, B32); sin capturas forzadas. La firma de cuarentena cambia
   (VPVK_AMPLIFY=1) → la cuarentena anterior se descarta sola.
4. Pie de «Dedos reales»: solo con las manos libres (con Sense en la mano el visor no trackea esa mano).

## Logs_Alyx_27 (B34) — medido
- B34 correcto: `display 100.00 Hz measured`, `[guest] panel rate 100.0 Hz`, pacer `1/2 → 50` / `1/3 → 33`, el
  compositor muestra todas las imágenes del juego.
- Con amplificación, escena 2 (W7/W8, 33 fps): escena MSAA **10,1–10,4 ms = vtx 2,1–2,9 + frag 8,2–8,4**; eye-1x
  3,4–3,6 (tonemap 2112x1728 f70 1,5–1,7 + bloom 528x432 1,35–1,45 + cadena); compute 1,2; blit 0,85 (x11);
  other-rt 1,1–1,2. Busy 17 ms/frame, `gpu.time` p50 14,4 / p90 15,4 en los últimos 2 min. Zona ligera: 12 ms.
- Regulador: oscilaba 50 ↔ 33 cada 2–3 s en escena 2: en la base 17,4–17,6 ms (87 %) con 6–10/50 tardíos (12–20 % >
  19,2 ms) → fallback por la regla del 10 %; en el fallback 14,9–15,7 (< 16) → base; bucle. 33 fps la mayor parte
  del tiempo con la GPU a 14–15 ms.
- `[gputime] compositor avg 6 ms` es span (incluye trabajo del juego intercalado), no exclusivo: pendiente medirlo.

## B35 — cambios
1. Regulador (`klvr_platform_klepton.c`): deja la base solo con media > 95 % o > 30 % tardíos (2 s); vuelve con
   media < 85 % y ≤ 10 % tardíos (3 s). Un frame tardío en la base = un refresco retenido por la reproyección; el
   fallback = todos retenidos.
2. Subtítulos: ajuste «Subtítulos» (`avp.subtitles`, `SubtitlePlacement`, por defecto «A la altura de la vista»).
   Valores por defecto del juego sacados de libclient.so ARM64: `cc_vr_vertical_offset` −6,5 (positivo = arriba,
   unidades del juego), `cc_vr_forward_offset` 30, `cc_vr_font_size` 0/1/2 (defecto 1, archivado), `cc_vr_width`
   0/1/2. Forzados como absolutos en `forcedConvars` (args + Lua cada 5 s): Más arriba = 0, A la altura de la vista
   = 6, Por encima = 12; letra 2 (grande). «Como el juego» no fuerza nada (un "+cvar -6.5" en la línea de comandos
   se leería como switch). KLPERF vuelca ahora `closecaption`, `cc_subtitles`, `cc_vr_*` para verificar.
3. Notificaciones en inmersivo: sin API en visionOS; solución = Modo de concentración con activación automática al
   abrir la app (Ajustes → Concentración → programar por app). Documentado al usuario, no en la app.

## Logs_Alyx 2_10 (B35) — medido
- Subtítulos ROTOS (ojo izq. desplazado/doblado, dcho. cizallado): en `capture-3600-eyetex0/1` el subtítulo está
  dibujado en coordenadas LÓGICAS (hasta x=747 de 1024, fuera del área física 1352x1308 = 64 %x76 % de la textura).
  El juego lo dibuja en un pase propio tras el post: vista sRGB del ojo (`RGBA8sRGB 2112x1728x2 s1 att=c0:LS draws=1`,
  frag 0,1 ms), SIN depth (`cc_vr_depth_test=0`); el hook solo foveaba MSAA y 1x CON depth → quad sin mapa sobre
  imagen comprimida, y el compositor la desenrolla con el mapa. Convars sí aplicados (KLPERF `cc_vr_vertical_offset=6
  cc_vr_font_size=2`); altura real ≈ 30–47 % desde arriba (justo sobre el centro, que está al 54 %).
- Regulador: 50 → 33 a los 2 s de juego y nunca vuelve. Causa: `klvr_plat_gpu_ms` = UNIÓN de spans
  `GPUStartTime→GPUEndTime` de los command buffers; en juego incluye esperas a buffers anteriores y turnos del
  compositor: `[passes]` W5 unión 34 ms vs ocupado 17,4; W14 26 vs 13,5. Ocupado real escena 2: 13,5–16 ms (W7/W8/
  W10/W14: cabían 50 fps) y 20–24 en zona densa (W11–W13). GPU ociosa dentro del span 29 ms/frame a 33 fps.
- Pendiente de entender: command buffer del juego con 1 dispatch de compute a 100/s exactos (por refresco), 0,3–0,6 ms
  excl (`gpu.excl type=1c9d9e5ec8c45b50`, `vk.submit ... dispatches=1`): 3–6 % de la GPU.
- Blits ~1 ms/frame (x11, join/copias). Amplificación OK (vtx 2–7 ms). `gpu.excl busy_ms_per_s` 620–810 a 33 fps.

## B36 — cambios
1. Subtítulos: `kl_gpu_time.m` hook de foveado: también fovea pases de ojo 1x, 2 capas, formato sRGB, loadAction Load,
   sin depth (`srgb1x`; log `[vrr] foveating a 1x layered pass without depth on the sRGB eye view (subtitles)`).
   `KL_VRR_SRGB_1X=0` = comportamiento anterior (A/B). Los pases de post texel a texel usan la vista UNORM (f70).
2. Tiempo de GPU EXCLUSIVO para el regulador:
   - VPKEngine `0036`: en el completed handler, los timestamps de etapa de cada encoder (siempre muestreados) se
     colocan en una línea de tiempo global y el exclusivo del command buffer se guarda en un anillo de 64 por puntero;
     export `vpgpu_metal2_cb_busy_ms(cb, &ms)` (1 conocido / 0 nada muestreado / -1 no está; consume la entrada) y
     `vpgpu_metal2_cb_busy_stats`. Independiente de `VP_EXCL_TIMING`.
   - `kl_gpu_time.m`: `on_complete` recibe el command buffer; rol 0 → lookup en VPVulkan (dlsym vía
     `dlopen(KL_MVK_DYLIB, RTLD_NOLOAD)` al primer commit del juego); rol 1 (compositor) → sample buffer propio
     (`cx_*`: 4 timestamps por render encoder en el hook `kl_rce`, anillo 1024, línea de tiempo propia, calibración
     ticks→ns como VPVulkan sin timebase + comprobación contra el span del buffer). `kl_gpu_time_frame_ms` devuelve el
     exclusivo cuando TODOS los buffers del rol en el frame se contabilizaron, si no la unión; `kl_gpu_time_frame_exclusive()`
     (bits rol 0/1, thread-local). Línea `[gputime]` cada 5 s amplía: `exclusive buffers game N (missed M), compositor
     N (missed M); VPVulkan accounted N (unsampled N); compositor samples N resolved N bad N`. `KL_GPU_TIME_EXCL=0` = unión.
   - Regulador (`klvr_platform_klepton.c`): con exclusivo, "tardío" = trabajo de GPU > presupuesto del frame (20 ms);
     deja la base tras 2 s con media > 95 % o > 25 % tardíos; vuelve tras 3 s con media < 88 % y ≤ 5 % tardíos. Con
     unión (sin VPVulkan) umbrales B35. Log cada 60 s `pace governor: at the base/fallback, GPU x ms (exclusive|union)`.
   - Esperado: 50 fps en zonas con ocupado ≤ ~15 ms (+ compositor), 33 en densas. Si en el log sale `missed` > 0 en
     el juego de forma sistemática, el orden de completed handlers no es el supuesto (VPVulkan antes que klepton):
     entonces se queda en unión y hay que pasar el exclusivo por otra vía (acumulador global en vez de anillo).
3. Launcher: `Window(id:)` para launcher y "kbentry" (ya en main desde B35, primera IPA con ello). **La app moría al
   tocarla sin mostrar nada** (usuario, B36): revertido a `WindowGroup` en B36b sin más cambios. Si B36b arranca, el
   culpable es `Window` (no usarlo en AVP; la doble ventana del launcher queda pendiente por otra vía). Si tampoco
   arranca, mirar el `.ips` (dyld / símbolo) de los cambios de `kl_gpu_time.m` (`__thread`, dlopen RTLD_NOLOAD).

## B37 — cambios (en main; build cuando B36b esté confirmada)
1. Ojos sin copia: `klvr_vk_submit.cpp` (`KLVR_EYE_DIRECT`, ajuste «Ojos al compositor sin copia», `avp.eyeDirect`,
   ON): si el submit es la capa entera sin flip, `klvr_plat_eye_publish_guest` → `kl_vulkan_eye_publish_guest`
   exporta el MTLTexture de la imagen del JUEGO (VK_EXT_metal_objects), lo retiene y lo mete en la tabla de ojos
   (`kl_glfb_note_eye_mtl_texture`, slice = capa); el blit se omite, el command buffer vacío con su fence sigue
   (la etapa se completa cuando el render del juego acaba). Si un submit vuelve a copiar (bounds parciales/flip,
   tamaño distinto) `kl_vulkan_eye_unpublish_guest` repone la imagen de la plataforma; al destruir el juego la imagen
   (`klvk_DestroyImage` → `eye_guest_forget`) igual. Texturas soltadas vía `klvk_retire_any` (KLVK_RETIRE_FRAMES).
   Log `[vk] eye N stage M: the compositor samples the guest's image ... directly`; `[glfb] eye ... is MTLTexture`
   limitado a 24 líneas. Ahorro esperado: 2 copias de 14,6 MB por frame (~0,6 ms, gpu.excl tipo 1c9d…: 3 CB/frame
   de 0,3 ms; el tercero queda por identificar).
2. Ajuste de prueba «Post-procesado solo en el área foveada (prueba)» (`avp.postPhys`, OFF) = `KL_VRR_PHYS_POST=1`:
   tonemap y composición del bloom (1,3 + 1,3 ms a área completa) limitados al área física del mapa (~−1,3 ms).
   Fuera del área la imagen del ojo queda negra (tonemap del clear). Si se ve bien → ON por defecto en B38.
3. Compositor: la vista ancha YA se construye a la densidad de la periferia (`buildWideView`, dens = edge, taps 4):
   nada que recortar ahí; medir primero con `cx` (B36).

## Logs_Alyx_3 (B36b) — medido
- B36b arranca: el crash al tocar el icono era `Window(id:)` (no usar en AVP). Subtítulos: foveado correcto
  (`[vrr] ... (subtitles)`), pero letra 2 demasiado grande → B37 letra 1.
- Medida exclusiva FUNCIONA: `missed 0` en juego y compositor toda la sesión, calibración 1,0000 ns/tick, `bad 99`
  solo los frames antes de calibrar. Regulador `(exclusive)`.
- Cifras REALES por frame (33 fps, juego): juego 14–18 ms (picos 22–26), **compositor 4,5–5,9 ms exclusivos** (luego
  2,8–3,6 en otra zona) → total 18–23 ms: 50 fps no cabe casi nunca; el regulador sube a 50 en zonas ligeras
  (11–16 ms) y cae a los 2 s (32/50 tardíos). El compositor es ~25 % del presupuesto: objetivo principal.
- El compositor compone 1 vez por frame del juego (34/s, `skipped(same picture)` el resto) → ~5 ms POR COMPOSICIÓN.
  Sospechosos: reconstrucción de periferia (`KL_CP_RECON=1`, multi-tap) y el muestreo redondo; B37 saca
  `[gputime] compositor passes (exclusive ms per pass, passes/s)` cada 30 s con la firma de cada pase para repartirlo.

## B38 — cambios (sobre B37, sin log de B37 aún; el usuario reportó sobre B36b)
1. Altura del jugador: `KLVR_HEIGHT_OFFSET` (m) sumado a la Y de cabeza y manos que ve el JUEGO
   (`klvr_platform_klepton.c`: `klvr_plat_head/hand` envuelven `_raw`; `klvr_plat_set_height_offset` en vivo,
   declarado en `kl_app.h`); el compositor sigue con las poses del dispositivo (reproyección rotacional: no afecta).
   Ajuste «Altura del jugador» −60…+30 cm (`avp.heightCm`, 0), pantalla Juego, en vivo desde la pausa. Motivo: el
   usuario juega con el suelo del juego demasiado lejos (no alcanza objetos sin agachar a Alyx).
2. Subtítulos: ajuste «Tamaño de subtítulos» pequeño/medio/grande (`avp.subSize` → `cc_vr_font_size` 0/1/2, por
   defecto pequeño, con cualquier colocación). B35 grande, B37 medio.
3. Parpadeo de menús 2D y subtítulos "a veces" (B36b, sin captura): sin causa clara en el log (un solo mapa, sin
   errores). A/B: ajuste «Foveado del pase de subtítulos» (`avp.subFov` → `KL_VRR_SRGB_1X`, ON) en Diagnóstico.
   Pedido al usuario: probar con él apagado y L3+R3 cuando parpadee. Otra hipótesis: orden entre command buffers
   (VP_CB_ORDER=2) con vista sRGB vs UNORM del mismo ojo (las lecturas muestreadas van por id de vista, las
   attachments por id de imagen) → probar «Orden de GPU por recursos» apagado.

## B39 — occlusion culling medido (VPKEngine `0037`)
- HALLAZGO (idea del usuario: "el juego no usa occlusion culling"): Alyx crea pools de consultas de oclusión y llama
  `vkCmdBeginQuery` (`r_occlusion_culling 1`), pero `queries.cpp` respondía SIEMPRE "1 muestra visible": el juego
  dibujaba todo lo del frustum. Ahora: `Draw::visibility` (un slot de 8 B por draw consultado, nunca compartido:
  robusto a que metal2 parta un pase), `GpuTimings::visibility`, `Device::frameVisibility` (shared_ptr, 64 frames);
  metal2: buffer de 64 KB por slot de frame (`vpgpu.visibility`, memset en CPU antes de codificar), lo liga como
  `visibilityResultBuffer` en todo pase del frame, `MTLVisibilityResultModeCounting` en el draw; slots sin draw
  codificado (skip, pipeline ausente, cuarentena, encoder fallido, CB con error) leen 1 (visible). Vulkan:
  Begin/End marcan los draws grabados (`OpDraw::query`, puesto ANTES de cualquier return temprano), el traductor
  reparte slots (tope 8192 por submit; sin slot = desconocido = visible; secundarios dentro de una consulta =
  desconocido), `stampQueries` deja la consulta no disponible mientras sustituye sus slots y pone frame+written al
  final bajo el mutex del pool; `vkGetQueryPoolResults` suma los contadores, 0 solo para consulta sin draws.
  `VPVK_OCCLUSION=0` = todo visible (ajuste «Occlusion culling medido (consultas de GPU)», `avp.occlusion`, ON).
- Revisión adversarial: 4 hallazgos corregidos (kill switch invertido, tag tras return temprano, secundarios, carrera
  en stampQueries) + vector compartido en vez de copia por consulta.
- Qué mirar en el log de B39: draws por escena en `gpu.excl` (antes 240–1 813) y `[passes] scene-msaa` vtx/frag;
  cualquier geometría que desaparezca indebidamente → apagar el ajuste y reportar.

## Logs_Alyx_28/29 (B39) — medido
- OCCLUSION CULLING FUNCIONA: escena MSAA 3,6–10,7 ms (antes 8–16), draws máx. 183 (antes 1 813), juego 7–12,8 ms
  de GPU, **50 fps sostenidos** (250 frames/5 s), 0 fallos de GPU. Nada desaparece reportado.
- PARPADEO de subtítulos/menús y TIRONES al mover la cabeza (con y sin foveado de subtítulos): la entrega de ojos
  sin copia. Alyx usa UNA sola imagen de ojo para las 3 etapas (`0x7064c1e880`, capas 0/1): el compositor muestreaba
  la textura en la que el juego dibujaba el frame siguiente. B40: `avp.eyeDirect2` OFF por defecto y
  `kl_vulkan_eye_publish_guest` lo rechaza para siempre en cuanto ve la misma imagen en dos etapas
  (`[vk] eye N: the guest submits one image ... the shim copies from now on`). El toggle «Foveado del pase de
  subtítulos» queda (no era la causa; dejar ON).
- Compositor por pase (exclusivo): composición `1856x1760 L2 f81 z` 1,3–2,4 ms × 37–79/s; **vista ancha `211x173`
  0,33–0,83 ms × 29–93/s (2 ojos por imagen)**: absurdo para 36k píxeles → sospechoso #1 del compositor (¿la malla
  `grid`/overdraw o los 16 taps bilineales sobre 2112x1728?). Compositor total 2,5–3,5 ms/frame.

## Siguiente (al llegar el log de B40)
1. Confirmar sin parpadeo ni tirones con la copia de ojos (B40). Si siguieran: comparar con B36b (no los tenía).
2. Vista ancha: medir por qué 0,6–0,8 ms por ojo (reducir taps a 2 con mips del ojo, o 1 muestra bilineal sobre
   un mip 1/4): −1 ms/frame del compositor.
3. Post foveado (toggle de B37) si el usuario lo prueba limpio → ON.
1. Repartir los ~5 ms del compositor por pase y recortar el mayor (recon / composite): candidatos: recon a menos
   taps, componer la periferia a menor resolución, o `KL_CP_QUALITY` (hoy 0,40).
2. Confirmar `[vk] ... samples the guest's image ... directly` y que la imagen es correcta; `gpu.excl` tipo 1c9d…
   debe bajar de 3 a 1 CB/frame.
3. Probar el ajuste «Post-procesado solo en el área foveada»; si limpio → ON por defecto.

## Siguiente (al llegar el log de B36) — hecho en B37 salvo lo indicado
1. Confirmar `[vrr] ... (subtitles)` y subtítulos correctos en ambos ojos; afinar `cc_vr_vertical_offset` si la altura
   no convence (6 ≈ justo sobre el centro).
2. `[gputime]`: `missed 0` en juego y compositor, `calibrated ~1.0 ns per GPU tick`, sin `sample dropped`; regulador
   `(exclusive)`; contar cambios 50↔33 y % de tiempo a 50.
3. Compute de 100/s en la cola del juego (0,3–0,6 ms): identificar (¿klvr? ¿juego?) y quitar/limitar.
4. Post foveado (tonemap + bloom al área física, con limpieza del área exterior): ~1,5 ms, riesgo medio.
5. Streaming de texturas (`vkCopyMemoryToImageEXT` espera la GPU por región) → staging asíncrono.
6. Hidden area mesh: comprobar que klvr devuelve malla para la lente del Vision Pro.

## No tocar (decisión del usuario)
- `vr_expand_cull_frustum` (2): bajarlo ahorraría algo en exteriores pero puede meter popping en el borde al girar;
  descartado. Frustum culling es de CPU (Source 2) con las tangentes reales del visor (105x95°): no hay nada roto ahí.

## Pendiente menor
- Ajustes en vivo que faltan: resolución/texturas (convars), anisotrópico, zona nítida; activar/desactivar foveado requiere reiniciar.
- Botón PS no capturable (solo "Button Menu"); mitigado por la pausa. QR de Steam. Subir 0011–0030 al repo VPKEngine.
- Investigaciones abiertas de B18: modo polígono LINE ignorado; vistas de aspecto stencil devuelven depth;
  `vkCopyMemoryToImageEXT` espera la GPU por región.
