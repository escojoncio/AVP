# Bitácora — AVP

Half-Life: Alyx (build ARM64 Linux de Steam) nativo en Apple Vision Pro. Todo en el visor: Steam oficial → descarga →
conversión ELF→Mach-O (`klepton_ld` en proceso) → firma on-device (`vp_codesign` + .p12) → precompilado de pipelines →
juego. Gráficos: **solo VPKEngine** (repo `escojoncio/VPKEngine` = `vpkengine.ref` + `vpkengine-patches/`). MoltenVK
queda como referencia de diagnóstico (no se usa para jugar ni se arregla nada en él). Sin MetalFX (no sirve en VR). Plan: `PLAN.md`. Historial completo: `git log -p bitacora.md`.
IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última OK en CI: build 20).

## 100 % funcional en el visor
- Steam: login (contraseña + Steam Guard), propiedad (paquete 134870), descarga build 25487405 en background, Cloud.
- .p12 como primer paso del launcher (`AVPCertificateGate`); lector PKCS#12 de VPKEngine; firma `req4k` aceptada.
- Preparación: .deb → libs, 90 libs convertidas y firmadas, `pipelines.foz` (1218 shaders), prewarm de 3038 pipelines.
- **Referencia (MoltenVK, solo diagnóstico): Alyx arranca y se juega** — el pipeline completo está probado: OpenVR (cabeza + 2 Sense), idioma del sistema (`-language`), overrides
  (env, convars forzados vía `alyx-convars.lua`→`game/gameinit.lua`, `video2.txt`, tabla de fidelidad).
  Ritmo: 50/33,3 fps a 100 Hz (governor). El rendimiento que cuenta es el de VPKEngine.
- Launcher (arte de Steam, batería de los Sense), logs en `Documents/Logs Alyx/` (+ copia en la carpeta AVP),
  uno por motor (`klepton-boot-<motor>.log`, `KL_LOG_TAG`), censo Vulkan `census.txt`.

## Hecho, sin validar aún en el visor (build 10)
- VPKEngine `0011` (traductor SPIR-V→MSL: 0 errores en los 3038 pipelines de Alyx), `0012` (tests 149/149),
  `0013` (formatos BC que faltaban → causa probable del "Error in Init() of RenderDeviceMgr001"; vertex 3 comp.,
  structs Features2/Properties2 rellenos, IFP correctos, `vk.format unsupported=N`).
- Klepton: WSI propio cuando el driver no tiene VK_KHR_surface (`g_own_wsi`, superficie/swapchain sintéticas, SDL
  enrutado por el loader de Klepton); diagnóstico Vulkan siempre activo (`kl_vk_diag.inc`, generador
  `klepton/tools/gen_vk_diag.py`: VkResult≠SUCCESS, handles nulos, ring de 64 llamadas volcado en el message box;
  `KL_VK_DIAG=0` lo apaga); consola del juego (últimos 8 KB de `hlvr/console.log`) al boot log en el message box.
- VPKTAA consciente del foveado (`VPKTAACore` + rate map decoder; foveado 1x en pases multiview con depth).
- Pausa: PS izquierdo/Menu 1 s → `AVPPausedView` (Volver / Ajustes / Salir), guest retenido en `guest_pace_wait`
  (`kl_guest_set_paused`). Home/PS/Corona: el guest se conserva (`Lifecycle.keepGuestOnSpaceLoss`,
  `KleptonCompositor.guestKeptAlive`) y "Volver al juego" reabre el espacio (`AlyxBoot.reopenSpace`).
  Ajustes en vivo sin setenv (`AVPSettings.applyLive`): forma del foveado (`kl_vrr_set`), VPKTAA, FPS, config VPKEngine.
- Ritmo: pacer `ceil(rate/(hz*1.15))`, `pace_plan` con la tasa medida (100 Hz → 50 con fallback 33,3).

## Herramientas
- `scripts/shader-harness.sh <pipelines.foz>`: VPKEngine en Linux (backend null) + fossilize-replay → mismos
  `vk.err` que el visor en segundos. `VPVK_DUMP_DIR` vuelca IR/SPIR-V de los fallos. El .foz nunca va al repo.

## Historial resumido (detalle: `git log -p bitacora.md`)
- B11: log propio del prewarm + `kl_fault_install`; guardia anti-bucle `prewarm.inflight`; icono.
- B12 (`0014`): sin variante de movimiento con dual-source blending; `buildRender` devuelve error en vez de abortar.
- B13 (`0015`–`0017`): indirect leído en GPU (inocuo), `gpu.recover` cola nueva, caché `vpcache` + `warm.stamp`.
- B14 (`0018`–`0019`): informe `gpu.hang.enc`, cuarentena, traductor v2 (OpKill, `vp_budget`), presupuesto de archives;
  pantalla de carga inmersiva; Ajustes › Diagnóstico › restablecer cuarentena.
- B15: archivos binarios Metal desactivados para siempre (`VP_PIPELINE_ARCHIVE=0`), sin prewarm de recetas.
- B16 (`0020`): vectores de movimiento off tras el 1.er cuelgue (`motion.off`) — refutado en B17.

## Build 17 (validada: 0 cuelgues, primera imagen; 16-19 fps, casi todo negro): causa de los cuelgues + crash
- Logs_Alyx_11 (build 16): los cuelgues siguen tras `vk.motion disabled` (y el 1.º, f=462, fue con 0 draws de movimiento):
  los vectores de movimiento son inocentes. Todo encoder "stuck" es un pase de ojo 2784x2208x2 con depth
  Depth32Float_Stencil8; el censo da `depth[... resolve 0x1] stencil[... resolve 0x1]` con imágenes 1x (vr_msaa 0, ninguna
  `vk.msaa forced`): Source 2 "resuelve" su depth 1x a otra imagen y VPVulkan lo traducía a
  `StoreAndMultisampleResolve` sobre una textura 1x (UB en Metal → cuelgue; el compositor/TAA que lee ese depth daba
  PageFault). Crash: la cola del compositor quedó `SubmissionsIgnored` tras 2 PageFault (201 composites fallidos) →
  CompositorServices sin frames → visionOS cierra la app (sin crash log propio).
- VPKEngine `0021`: `resolveAsCopy` (fuente 1x o forzada) → Store + copia `vk.forced_resolve` tras la instancia de pase
  (no tras un chunk SUSPENDING), también en render passes y `vkCmdResolveImage`; `resolveCopyUsable` (formato/muestras;
  `vk.resolve as_copy|dropped`); metal2 rechaza cualquier resolve desde 1x (`what=resolve_refused`, debe salir 0);
  `gpu.hang.enc ... resolve=`. Cazador de cuelgues (`VP_HANG_HUNT=0` lo apaga): tras un cuelgue, paso 0 salta TODOS
  los pipelines del frame colgado (si sigue colgando → `gpu.hunt verdict=not_a_pipeline`), luego bisección (cuelgue =
  culpable en la otra mitad; 12 frames limpios con saltos = en la mitad saltada) → `gpu.hunt culprit` a quarantine.txt y
  su MSL en el log (`gpu.hunt.msl`). Cuarentena ya no culpa a encoders "affected" (víctimas). Tope de colas 64.
  Movimiento ya no se apaga en un cuelgue (`VPVK_MOTION_OFF_ON_HANG=1` para volver a ello). Test `resolve_1x`.
- AVP: `KleptonCompositor` y `KleptonTAA` cambian de cola tras un error propio (no víctima) (`[cp]/[taa] queue
  replaced`); limpieza única `quarantine.v3` (quarantine/suspects/motion.off); app.txt resume cuelgues y veredictos
  `gpu.hunt`/`resolve_refused` de la sesión anterior.
- Linux: ctest 149/149, vpvk_tests OK (incl. `resolve_1x`). Metal/Swift revisados (Sonnet).

## Build 18 (log Logs_Alyx_13: 0 cuelgues, 0,7 fps, negro: caché de shaders del SO fría): imagen negra, rendimiento, shaders (3 agentes sobre Logs_Alyx_13)
- Negro: Source 2 parte el pase de ojo en chunks suspend/resume (flags 0x2/0x6/0x4) repitiendo loadOp CLEAR; VPVulkan
  limpiaba en cada chunk → solo sobrevivía el último. `0022`: chunk RESUMING → Load, SUSPENDING → Store sin resolve,
  copia del depth 1x solo al final (`vk.rendering suspend_resume`). Test `suspend_resume`.
- `0023` (traductor v3, recetas se retraducen): OpKill fuera de bucles = demote (derivadas tras clip()), ClipDistance →
  `[[clip_distance]]`, Invariant → `[[position, invariant]]` + preserveInvariance (`VPVK_INVARIANT_ALL=1` todo),
  offsets en texel fetch, A2C a 1x como alpha test (`VP_A2C1`; A2C hardware solo con >1 muestra), acceso de storage
  textures según uso. Test `gpu_spirv.correctness` (.spvasm).
- `0024`: 12 command buffers en vuelo (`VP_FRAMES_IN_FLIGHT`; antes 3 por submit y Source 2 hace ~11/frame → CPU y GPU
  en serie, 17 fps); `vkExportMetalObjectsEXT` exporta la MTLCommandQueue (Klepton mide GPU del juego y aplica el
  foveado KL_VRR a los pases de ojo de VPKEngine; colas retiradas vivas); adjuntos de color con formato de vista
  distinto (imagen sRGB 43 dibujada con vista UNORM 37) se renderizan por una vista Metal (`Attachment::viewFormat`,
  `formatView`, también en resolve y clears; `vk.attachment view_format`, `gpu.attachment view`).
- AVP: re-export de la cola cada 2 s (`kl_vulkan.c` `klvk_gpu_watch`), `kMaxQueues` 96; governor: sin fallback hasta
  medir GPU del juego y panel = máximo medido de la sesión; VPKTAA: jitter/record emparejados al Submit
  (`kl_ovrp_frame_close_external`), tag de depth en `klvr_plat_end_stage`; con VPKTAA `VPVK_MOTION=0` y
  `KL_VPKTAA_DEPTH=0` (vectores de VPKEngine a cero/basura, depth sin linealización Source 2: TAA solo rotación);
  `KL_VK_MERGE=0` con VPKEngine; logs copiados a la carpeta AVP cada 20 s y al abrir la app.
- Pendiente de estas investigaciones: modo polígono LINE ignorado; vistas de aspecto stencil devuelven depth;
  `vkCopyMemoryToImageEXT` espera la GPU por región; copia del depth (aliasar); mapa VRR usa tamaño de textura (no
  renderArea); parche de arenas de movimiento (agents/perf/03) para cuando vuelvan los vectores.
- Linux: ctest 152/152, vpvk_tests OK, shim 311/311. Metal/Swift revisados (Sonnet).

## Build 19 (validada: juego visible ~25 fps; geometría y efectos destrozados): caché de shaders fría
- Logs_Alyx_13 (build 18): traductor v3 → todo el MSL nuevo; el prewarm se saltaba la espera al driver con archives
  off, así que el juego compilaba en frío y `gpu.hold` retenía cada frame 1,5 s (`timeouts`), draws sin pipeline
  (`missing_pipelines=49`) → 0,7 fps y negro. GPU del juego 28 ms/frame (`[gputime]` ya mide), foveado aplicado
  (`[vrr] foveating 1x`), `suspend_resume` y `gpu.attachment view` activos. Imagen aún sin juzgar.
- `kl_fossilize.cpp`: el prewarm SIEMPRE espera `vpvk_device_wait_compiles` (llena la caché del SO antes de jugar).
  `AVPPrepare.prewarm`: texto "Compilando shaders en la GPU… N s — no cierres la app" cuando el replay llega al total.
- VPKEngine `0025`: tras un hold que agota el tiempo, los holds bajan a 15 ms durante 3 s (`Device::submit`).

## Build 20 (sin validar): foveado de Klepton fuera con VPKEngine + capturas
- Logs_Alyx_14 (build 19, usuario al 100 %: ojo 3072x2496): 0 cuelgues, ~25 fps, GPU juego 39-45 ms, "explosiones de
  vértices" y efectos rotos. Desde la build 18 el hook KL_VRR (kl_gpu_time.m) actúa sobre VPKEngine: a 1x solo
  foveaba pases con capas + depth; los pases de ojo solo-color (partículas/efectos, census `viewMask 0x3: c0[...]`
  sin depth) y el compute caían en layout de pantalla sobre una imagen en layout físico que el compositor desdobla.
- `AVPSettings`: con VPKEngine el foveado de Klepton va siempre off (KL_VRR=0) hasta foveado nativo en VPKEngine;
  capturas siempre activas con VPKEngine (KL_CAPTURE, PNG de los ojos en frames 120/600/1200) y volcado por pase
  `VP_DUMP_FRAME=6000` (~35 s tras la 1.ª imagen) en la carpeta de logs.
- VPKEngine `0026`: `RenderPassDesc::renderWidth/Height` (renderArea) → `renderTargetWidth/Height` (máximo de los
  pases fusionados, nunca mayor que el adjunto); volcado por pase limitado a 512 MB.
- Pendiente: si con esto sigue habiendo picos de vértices → mirar las capturas/volcado (pase culpable) — candidatos:
  instancing de multiview/base instance, offsets de vertex buffers dinámicos, `0023` (invariant/clip). Rendimiento:
  foveado nativo en VPKEngine (rate map en todos los pases de ojo + compute), alias de la copia del depth.

## Build 21 (log Logs_Alyx_15: 33 fps estables, GPU 23 ms, 49 % de píxeles; ojo izquierdo deformado): MSAA x4 de referencia + foveado M2 de P.T. + VPKTAA solo en la periferia (fase 1)
- `AVPSettings`: el juego siempre a MSAA 4x (`gameMSAA`, `temporalTAA` = false: `VPVK_FORCE_1X=0`, `VPVK_MOTION=0`,
  `KL_VPKTAA=0`, VPKEngine `vpktaa_enabled=0`, `force_single_sample=0`); foveado de Klepton reactivado con VPKEngine
  (`foveationUsable = gameMSAA >= 4`: con MSAA todos los pases de ojo llevan el mapa, camino validado con MoltenVK).
- Presets M2/M5 = foveado probado en PTVisionPro: `KL_VRR_MAP=wide` (`kl_gpu_time.m` `vrr_mode`/`vrr_rates_near`):
  zona 100 % de 60° (tan 30 / span) alrededor del eje de mirada de cada ojo (tangente 0), centro 10° por debajo
  (cy += 0,1763/span_y), rampa de 1 zona, zona = tasa de su punto más cercano (no corta el centro); periferia =
  `KL_VRR_EDGE` = ajuste "Calidad de la periferia" 10-65 % (`presetPeriphery`, clave `avp.fovPeriphery2`, def. 10 %),
  en vivo (`kl_vrr_set(2, -1, -1, edge)`; primer arg de `kl_vrr_set` = modo 0 centre/1 soft/2 wide). Log: `[vrr]
  foveated map (wide) ... physical WxH (N% of the pixels)`.
- VPKTAA periferia fase 1: `kl_reproject.c` `kl_eye_recon`/`kl_eye_sample_main` (en `kl_reproject_f` y `_depth_f`):
  donde el ojo se magnifica (`mag` = texels/píxel por `fwidth`) por debajo de 0,75×`reconRef` (pleno a 0,45×;
  `reconRef` = ancho de ojo / 3072, así el centro nunca entra): Catmull-Rom 9 taps acotado al 2x2 (sin ringing)
  mezclado con bilineal según nitidez + suavizado a lo largo del borde (gradiente de luma 2x2). Uniformes nuevos
  `recon_on/strength/sharp/ref` (C y MSL, al final del struct). `KleptonCompositor.reconOn/Strength/Sharp/Ref` (env
  `KL_CP_RECON*`, refrescados en `writeConfig` y `applyLive`); HUD "VPKTAA periferia". Defaults VPKTAA 80 %,
  nitidez 100 % (claves nuevas `avp.reconPercent/reconSharp`).
- Riesgo conocido: los pipelines grabados en `klfz` desde la build 9 son de 1x; los de 4x pueden compilarse en frío en
  la 1.ª partida (holds, `0025` los limita) y quedan grabados para la siguiente.
- Revisión adversarial (Sonnet): sin bugs; aplicado su aviso (umbral relativo a la resolución del centro).

## Build 22 (Logs_Alyx_16: explosiones de vértices al mover la cabeza también con foveado y VPKTAA off)
- Logs_Alyx_15 (build 21): capturas `capture-600-*`: las dos texturas de ojo comprimidas igual (rasterizadas con la misma
  capa del rate map), salida izquierda deformada, derecha bien. Causa: Metal elige la capa del rate map por
  `[[viewport_array_index]]`; VPKEngine solo escribía `[[render_target_array_index]]` (regla fija en la bitácora de
  VPKEngine). 0 cuelgues, 33,3 fps estables, GPU juego 23 ms, mapa wide 1808x1664 (49 %).
- VPKEngine `0027`: multiview escribe `[[viewport_array_index]] = vista` (traductor v4: caché fría una vez, el prewarm
  espera) y metal2 fija un viewport/scissor por vista (`passViews`, `setViewports`/`setScissorRects`); volcado por pase
  = primer frame >= `VP_DUMP_FRAME` con >= 8 encoders y un pase con capas (el 6000 de la build 21 salió vacío).
- Capturas también en frames de juego 2400/3600 (`KleptonCompositor` `frames`; 1200 cayó en un fundido a negro).

## Build 23 (Logs_Alyx_2_4: sin explosiones con cola 3, fps hundidos): A/B de la cola de GPU + captura a demanda
- Usuario: con foveado off y VPKTAA off siguen las "explosiones de vértices", solo al mover la cabeza (no son el foveado).
  Hipótesis principal: carrera de datos por 12 command buffers en vuelo (`0024`): con la cabeza quieta dos frames
  llevan los mismos constantes y no se nota. Alternativa: `0023` (clip distance / invariant).
- `AVPSettings.gpuQueueDepth` (clave `avp.gpuQueueDepth`, 12 por defecto | 3) → `VP_FRAMES_IN_FLIGHT`; Ajustes ›
  Diagnóstico "Trabajo en cola para la GPU"; en app.txt "cola GPU N".
- Captura a demanda: L3 + R3 a la vez (`KleptonControllers.stickClick`, solo con KL_CAPTURE) → `FrameCapture.requestManual`
  (PNG de ojos y salida del siguiente frame) + `vpgpu_metal2_request_dump` (VPKEngine `0028`: volcado por pase del
  siguiente frame real, `gpu.dump requested f=N`), encontrado con `dlopen(KL_MVK_DYLIB, RTLD_NOLOAD)`.

## Build 24 (Logs_Alyx_17: 33 fps, sin explosiones; ojo/UI mal con M2): orden entre command buffers (causa de las explosiones) + zona nítida en grados
- Logs_Alyx_2_4 (build 23, cola 3, foveado off, VPKTAA off): sin explosiones de vértices; fps 33 en menú, 18-20 en juego
  y 5-11 en zonas oscuras con linterna (render CPU 20-160 ms: con 3 command buffers en vuelo y ~5 por frame del juego,
  CPU y GPU se serializan). 0 cuelgues. Explosiones ⇔ 12 en vuelo desde la build 14 (logs 14-17 todos con 12).
  Queda "algún efecto o sombra" (captura 3600: estantería iluminada por la linterna sin sombra visible).
- Causa (VPKEngine metal2): recursos sin hazard tracking; el compilador de frames busca hazards por command buffer y
  solo el PRIMER encoder de cada command buffer esperaba la cola del anterior. Los demás encoders sin barrera interna
  podían correr mientras el command buffer anterior aún dibujaba (copia/compute que escribe vértices o constantes que
  un pase del anterior seguía leyendo). En Vulkan la barrera del juego ordena contra TODO lo enviado antes. Con 12 en
  cola la GPU siempre tiene el siguiente a mano → pasaba a menudo; con 3 casi nunca.
- VPKEngine `0029`: encoder "vpgpu.join" al inicio de cada command buffer espera toda la cola del anterior y actualiza
  un fence; todos los encoders lo esperan en la etapa de vértices (`VP_CB_ORDER=0` = regla antigua). Slots reutilizados
  solo cuando su propio frame terminó (el semáforo cuenta, no identifica). Medida `gpu.order` cada 600 command
  buffers: `overlapped` (cota superior), `out_of_order`, `slot_busy`, `carried_waits`. Volcado por pase = 12 command
  buffers seguidos (≈ 2 frames: sombras, escena y post), presupuesto 512 MB.
- App: cola GPU vuelve a 12 por defecto (clave nueva `avp.gpuQueueDepth24`); Foveado M2/M5 › "Zona nítida" 30-70°
  (5°, 60 por defecto) → `KL_VRR_WIDE_DEG` (kl_gpu_time.m, al arrancar; log `[vrr] foveated map (wide N deg)`).

## Build 25 (sin validar): overlays foveados, M2 a su tamaño real, cerrojo de recursos
- Logs_Alyx_17 (B24, M2 60° + VPKTAA periferia, cola 12): 33 fps estables, `gpu.order overlapped=0
  out_of_order=0 slot_busy=0`, sin explosiones. Fallos: (1) ojo mal: volcado L3+R3 f=4606 pase 61 = RGBA8 sRGB
  2784x2208, 112 draws (paneles del menú, manos, UI 3D) dibujado DESPUÉS del resolve a 1x con depth resuelto, sin
  rate map → en coordenadas lógicas sobre imagen foveada (menú del ojo izq. encogido en una esquina). Ya pasaba en
  B22 (capturas Logs_16). (2) M2 más nítido que P.T.: 16 zonas y cada zona con la calidad de su punto más cercano al
  centro → zona nítida +~13° por lado. (3) crash `Impl::texture()` bajo submit (B22 22:37, B24 23:25): tablas de
  recursos sin cerrojo, el juego crea/borra imágenes en hilos de carga.
- `kl_gpu_time.m`: hook foveado también para pases de ojo con 2 capas exactas y depth 2D-array a 1x (antes solo con
  KL_VPKTAA=1); log `[vrr] foveating a 1x layered pass with depth` y `[vrr] eye-sized layered pass NOT foveated`
  (medida: solo deberían quedar los post fullscreen). Mapa wide: 32 zonas (16 si Metal lo rechaza), cada zona a la
  calidad de su centro, rampa de 1 zona; zonas guardadas por mapa en `g_vrr_maps[].zones` y publicadas al
  compositor; log `[vrr] foveated map (wide N deg, Z zones)`.
- VPKEngine `0030`: `tableMutex` recursivo en metal2 (create/destroy/views/contents/nativeTexture + submit tras la
  espera de slot hasta commit) y `resMutex_` en `vpgpu::Device` (orden: resMutex_ → tableMutex);
  `Device::textureDesc()` copia bajo cerrojo (motion.cpp).

## Siguiente
- Log build 25: menú y manos iguales en ambos ojos con M2; `[vrr] ... NOT foveated` solo post; borde de zona nítida
  como P.T.; 0 crashes en `texture()`.
- Log build 24: sin explosiones con 12 en vuelo, fps vuelve a ~30; `gpu.order` (overlapped≈0 con cb_order=1).
  Sombras/efectos: volcado L3 + R3 de 12 command buffers (pases de sombra incluidos).
- Log build 21: `[vrr] foveated map (wide)` (% de píxeles), `[vrr] foveated scene passes on`, `[cp] periphery
  reconstruction active`, fps (`[openvr] frames`), `[gputime] game avg`, `gpu.hold`/`missing_pipelines`, cero
  `Caused_GPU_Hang`; capturas PNG (`KL_CAPTURE`) y volcado del frame 6000: imagen correcta con MSAA + foveado.
- Logs de la build 20 (si llegan): capturas sin foveado → si las "explosiones de vértices" siguen, no eran el foveado.
- Fase 2 VPKTAA periferia: acumulación temporal solo en la periferia (jitter + movimiento de cámara por depth + pose,
  profundidad linealizada z = 0.95 - 0.0375/d).

## Plan acordado (siguiente chat)
- Imagen de referencia: MSAA x4 por defecto para Alyx (VPVK_FORCE_1X=0, vr_msaa 4); el hook KL_VRR foveaba bien
  todos los pases con MSAA (camino validado con MoltenVK): reactivarlo con VPKEngine solo en modo MSAA. VPKTAA queda
  como opción experimental hasta tener: profundidad linealizada (z = 0.95 - 0.0375/d, proyección en `[openvr] eye N
  depth`), movimiento de cámara por depth + pose (estilo ASW), rechazo de historial en objetos móviles.
- Foveado agresivo: preset tipo PTVisionPro (zona nítida 60°, periferia 10 %): con mapa separable de Metal ≈ 16-30 %
  de píxeles (actual "soft" 61-67 %). PTVisionPro hace "quad views" (vista ancha al 10 % + inset nítido, dibujadas
  por el motor de P.T., `xr_host_visionos.mm` EyeFactor/CenterTangent): Alyx es binario cerrado, así que aquí va el
  rate map (estándar para juegos sin soporte del motor); quad views en VPKEngine (repetir el fotograma de ojo con
  proyección ampliada + objetivos propios) = investigación posterior.
- Decisión del usuario: el juego se renderiza tal cual con MSAA; el foveado (rate map) baja la periferia; VPKTAA se
  aplica a la periferia foveada (suavizar los bloques): fase 1 (hecha, build 21) filtro espacial de reconstrucción en el unwarp del
  compositor (bicúbico/adaptativo a bordes, sin vectores); fase 2 acumulación temporal solo en periferia con jitter +
  movimiento de cámara (depth + pose). El centro se controla con la resolución del launcher (ya existe).
- Foveado nativo de VPKEngine: rate map en TODOS los pases de ojo (también solo-color y compute que escriben la
  imagen del ojo), no por heurística en el hook de Klepton.

## Pendiente
- Ajustes en vivo que faltan: resolución/texturas (convars del juego), anisotrópico (solo afecta a samplers nuevos);
  activar/desactivar foveado requiere reiniciar.
- Botón PS: no se puede capturar (solo "Button Menu" en `physicalInputProfile`); queda mitigado por la pausa.
- QR de Steam. Píldoras de batería: verificar mano. Subir 0011–0013 al repo VPKEngine.
