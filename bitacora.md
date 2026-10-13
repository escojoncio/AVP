# Bitácora — AVP

Half-Life: Alyx (build ARM64 Linux de Steam) nativo en Apple Vision Pro. Todo en el visor: Steam oficial → descarga →
conversión ELF→Mach-O (`klepton_ld` en proceso) → firma on-device (`vp_codesign` + .p12) → precompilado de pipelines →
juego. Gráficos: VPKEngine (por defecto) o MoltenVK (motor de diagnóstico). Plan: `PLAN.md`.
Historial completo: `git log -p bitacora.md`.

## Renombrado VPEngine → VPKEngine (2026-10-13)
- Todas las menciones, rutas e identificadores pasan a VPKEngine (repo `escojoncio/VPKEngine`, checkout `vpkengine/`).
- `vpkengine.ref` y `vpkengine-patches/*.patch` conservan su CONTENIDO (commit fijado del árbol antiguo, que aún
  dice VPEngine); solo cambian sus rutas.

## Estado tras la build 6 (`6c86550`, release `visionos`, AVP.ipa — compila, CI OK)
Enlace: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa

### 100 % funcional en el visor (pruebas 1–3, MoltenVK)
- Login Steam (contraseña + Steam Guard email), propiedad (paquete 134870), descarga build 25487405 (~54 GB en 18 min,
  background), Steam Cloud (bajadas 16).
- Import .p12 (lector del sistema falla -26275 → lector de VPKEngine OK). Firma `req4k` aceptada por el sistema.
- Preparación: 17 .deb verificados → 22 libs; 90 libs convertidas (1 s) y firmadas (2 s); `pipelines.foz` 1218 shaders
  (13 s); prewarm 3038 pipelines en 392 s la 1.ª vez, 3–4 s después (caché Metal caliente).
- **Alyx arranca y se juega con MoltenVK** (prueba 3): motor, OpenVR (cabeza, 2 Sense con pose), consola, partida.
  Rendimiento: GPU juego 28–31 ms/frame → ~33 fps (objetivo 45); compositor 100 Hz estable (~9 ms GPU).
- Overrides aplicados (boot log): env completo, args (`vr_msaa 4`, fidelity 0 fijo, texturas tope 2048 / pool 2560 MB),
  `video2.txt` + `vr_fidelity_levels_override.csv` instalados (gpu ids 4203/452984840), `alyx-convars.lua` inyectado como
  `game/gameinit.lua` (`KL_LUA_INJECT`; el original de retail viene vacío).
- Batería de los Sense en el launcher (log: `Batería PlayStation VR2 Sense Controller (L|R) …`).

### Cambios por build (ficheros)
- **B1** base VisionQuestPro `04f7e6a` + Glovebox (MIT) fusionado en Klepton propio (merge 3 vías sobre `ce74582`):
  `klepton/runtime/linux/**`, `openvr/**`, `gfx/kl_gpu_time.m`, `kl_vk_pipe_hooks.h`; x18 de Glovebox en
  `kl_x18.c/.h` + `tools/klepton_ld.c` (INPROC conservado, API `klepton_ld_run(in,out,err,len)`); censo
  `gfx/kl_vk_census.inc`; app `app/Sources/AVP*.swift`, Steam `app/Steam/` (SteamLauncherKit), nativo
  `app/Native/avp_deb.c`, `avp_pipelines.c`, `avp_config.c`; recursos `app/Resources/`; deps CI
  `scripts/build-{luajit,sdl,fossilize}.sh`; VPKEngine = `vpkengine.ref` (19a1f44) + `vpkengine-patches/0001..0010`.
  Fixes CI: LuaJIT `MACOSX_DEPLOYMENT_TARGET=14.0`; `dismissWindow` duplicado en BootView.
  Arranque: `AVPLaunch.configure()` → `kl_app_configure_alyx(resources, game, dylibs, config, data)`; BootView
  (`KleptonApp.swift`) hace `kl_app_boot` y abre la inmersiva. `kl_app.c` stall dump → `kl_sample_snapshot`.
- **B2** logs: todo en `Documents/Logs Alyx/` (`AVPLog.directory`); `AVPLog.start()` fija `KL_ALYX_LOG_DIR` antes de
  cualquier configure; `kl_app.c` `g_logdir` (boot, crash, alyx-error). Copia en `<carpeta AVP>/Logs Alyx/`.
- **B3** `AVPPrepare.sources`: el ELF más grande por stem dentro de cada carpeta (libavcodec.so vs .so.58…); prewarm
  devuelve rc y se registra con `kl_app_status()`.
- **B4** prueba 2 (MoltenVK con VPKTAA=1, vr_msaa 0, KL_VK_CLEAR_NEW): primer frame → `Lost VkDevice … GPU Hang` →
  SIGSEGV en librendersystemvulkan+0x21f9c0. Fix: `AVPSettings.taaActive = vpktaa && engine == .vpkengine`; con MoltenVK
  config Glovebox (vr_msaa 4, KL_VPKTAA=0, VPVK_FORCE_1X=0, KL_VK_CLEAR_NEW=0) → prueba 3 jugable.
  Launcher: `AVPLauncher.swift` + `AVPArt.swift` (derivado de Glovebox): 60 % arte sin tapar (hero/capturas/logo del CDN
  de Steam en tiempo de ejecución, caché `Library/Caches/AVP/art`, Ken Burns), 40 % columna de control.
  Batería: `AVPModel.senseControllers`, sondeo 20 s.
- **B5** censo también a `<Logs Alyx>/census.txt` (el prewarm crea device y pipelines antes del boot log y esas líneas
  deduplicadas se perdían); `-condebug` → `game/hlvr/console.log`, copiado a Logs Alyx (`AVPLog.all`).
- **B6** idioma: lista fija de idiomas de texto de Alyx en `AVPSettings.gameLanguage` (antes miraba
  `hlvr/resource/*_<lang>.*`, la localización está en los VPK → caía a inglés). `-language spanish|latam|…`;
  ISteamApps es NULL en el shim, el idioma va solo por argumento.

### VPKTAA (estado exacto)
- Código completo, compilado, **sin probar con Alyx**: `VPKTAACore.swift` (de VQP: profundidad, reproyección por
  píxel, desoclusión) + `KleptonTAA.swift` (prefiere MV de VPKEngine, `KL_VPKTAA_MV_SRC=auto|appsw|vpkengine`);
  jitter OpenVR `kl_vpktaa_jitter_tangents` en `GetProjectionRaw`; MV nativos en VPKEngine (parche 0009/0010,
  `vpvk_motion_get`, RG16F por ojo, doble posición con datos del frame anterior; draws opacos multiview).
- Solo se activa con motor VPKEngine (`taaActive`). Con MoltenVK + VPKTAA + MSAA 0 hubo GPU hang (B4): sin aislar si fue
  el VPKTAA (depth SAMPLED/STORE + copias en la cola del juego) o el MSAA 0.
- Opción pendiente si VPKEngine aún no arranca: ajuste experimental VPKTAA con MoltenVK (solo profundidad) para bisectar.

## B7–B9 (resumen; detalle en `git log -p bitacora.md`)
- B7: .p12 primero (`AVPCertificateGate`), MetalFX quitado de la UI, pacer `ceil(rate/(hz*1.15))` (100 Hz→50),
  foveado `.m2` por defecto (`avp.fov2`), VPKTAA consciente del rate map (`VPKTAACore` + `rasterization_rate_map_decoder`),
  foveado 1x en pases multiview con depth si VPKTAA, logs por motor (`KL_LOG_TAG`).
- B8: Klepton sirve WSI propio si el driver no tiene VK_KHR_surface (`g_own_wsi`); `pace_plan` con tasa medida.
- B9: `scripts/shader-harness.sh` (VPKEngine Linux + fossilize-replay sobre el .foz del usuario) y patch 0011:
  0 errores de traducción (CompositeInsert, MS subpass, dual-source, Modf/FrexpStruct, multiDrawIndirect). 0012: tests.
- Log B9 (VPKEngine): 3038+274 pipelines OK, luego "Error in Init() of RenderDeviceMgr001" sin ningún vkCreate tras
  el device (MoltenVK crea texturas por defecto justo ahí).

## Build 10 (`97d230e`, CI OK) — todo lo pendiente
Causa (7 agentes, 5 independientes coinciden; sondas contra libVPVulkan.so Linux): VPVulkan anunciaba
`textureCompressionBC=TRUE` sin BC1_RGB/BC2/BC4/BC5/BC6H en `kFormats` → FormatProperties 0, IFP -11; Source 2 los
comprueba en Init. Inputs de los agentes: `scratchpad/agents/*` (efímero).
- `vpkengine-patches/0013`: filas BC que faltaban (BC1_RGB→BC1 con alpha=ONE en la vista), VERTEX_BUFFER para formatos
  de 3 componentes, `vk.format unsupported=N` en el log, structs Features2 sin soporte escritos a FALSE
  (memory_priority, BDA, descriptor indexing) y DescriptorIndexingProperties rellenas, IFP: sampleCounts 1x para
  comprimidos/cubo/no renderizables y extent 3D real, `VkSubresourceHostMemcpySizeEXT`. ctest 149/149, harness 0 errores,
  sonda de secuencia Source 2 sin fallos.
- Klepton `kl_vk_diag.inc` + `kl_vk_diag_gen.h` (generador `klepton/tools/gen_vk_diag.py`): todo puntero Vulkan
  devuelto al guest pasa por un thunk que registra VkResult != SUCCESS (una vez por función/resultado + sitio de
  llamada), handles nulos, y un ring de 64 llamadas que `kl_vulkan_diag_dump` vuelca al salir el message box.
  `KL_VK_DIAG=0` lo apaga.
- WSI propio + SDL (`kl_vulkan.c`, `kl_glibc.c`): con `kl_vulkan_own_wsi()`, SDL_CreateWindow sin SDL_WINDOW_VULKAN,
  SDL_Vulkan_CreateSurface/GetInstanceExtensions/GetVkGetInstanceProcAddr por el loader de Klepton; swapchain con
  MUTABLE_FORMAT + format list; SurfaceCaps2/Formats2/PresentRectangles/PresentationSupport implementados.
- Message box del guest: últimos 8 KB de `<game>/hlvr/console.log` al boot log.
- Pausa: PS izquierdo (o Menu) mantenido 1 s → `Lifecycle.pauseToLauncher` (`kl_guest_set_paused`, espera en
  `guest_pace_wait`), launcher `AVPPausedView` (Volver / Ajustes / Salir). Espacio cerrado por el sistema (Home/PS/Corona):
  el compositor NO para el guest (`Lifecycle.keepGuestOnSpaceLoss`, `KleptonCompositor.guestKeptAlive`), se pausa, no se
  sale; al volver, `AlyxBoot.reopenSpace` abre un espacio nuevo que presenta el mismo guest. `KL_PAUSE_ON_SPACE_LOSS=0`
  vuelve a lo anterior. Ajustes en vivo al volver (`AVPSettings.applyLive`, sin setenv): forma del foveado
  (`kl_vrr_set`), VPKTAA (`KleptonTAA.reloadSettings`), FPS (`KleptonCompositor.fpsHudEnabled`), config VPKEngine.
- Logs de nombres viejos borrados al arrancar (`AVPLog.start`).
Riesgos sin validar en visor: segundo CompositorLayer sobre el mismo guest; mapa VRR nulo 1–2 frames al reanudar.

## Siguiente
Log B10 con VPKEngine: si sigue "RenderDeviceMgr001", leer `[vk] diag` (ring + errores) y la consola del juego tras el
message box; buscar `vk.format unsupported`. Probar pausa (PS izq. 1 s), Home/PS con juego abierto y "Volver al juego".

## Pendiente
- Validar en visor la pausa/reapertura de espacio (B10). Ajustes en vivo aún no cubiertos: resolución/texturas (convars
  del juego), aniso (solo samplers nuevos).
- Botón PS: no aparece en `physicalInputProfile` (solo "Button Menu"); el primer press de cada elemento sale en el log
  (`[cp] button element pressed for the first time`). Con B10 un Home/PS accidental pausa en vez de cerrar.
- Si BC no basta: identidad GPU (VPVulkan dice Adreno 740 / driver 0.1.0; MoltenVK Apple) — diff A/B en agentes F/C.
- MetalFX (VPKEngine `vpvk_config_set_metalfx`) y reactivar el ajuste. QR de Steam. Píldoras de batería: verificar mano.
