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

## Build 7 (`874ea87`, CI OK, AVP.ipa en release `visionos`) — logs B6 analizados
Logs B6 (2 partidas MoltenVK, español OK): panel a **100 Hz** (no 90); pacer `ceil(100/45)=3` → fijo 33,3 fps aunque la
GPU iba a 14 ms al inicio; en partida GPU juego 28–31 ms (foveado off, MSAA 4). Crash 11:39 (misma firma B4,
librendersystemvulkan+0x21f9c0) al SALIR con la corona (confirmado por el usuario): cierre del device en teardown, no en juego; sin boot log (lo pisó la siguiente). Censo: Alyx NO usa int64/16-bit,
teselación, depth bounds ni mesh → no son pendientes de VPKEngine para Alyx.
Cambios B7:
- `kl_app.c` pacer: `N = ceil(rate/(pace_hz*1.15) - 0.05)` (100 Hz→50, 90→45, 120→40); extra del governor si ≥31,5 fps.
  Logs por motor: `KL_LOG_TAG` → `klepton-boot-<motor>.log` / `klepton-crash-<motor>.log` (+ `.prev.log`).
- `klvr_platform_klepton.c` governor: fallback si ≥32 fps (100 Hz: 50↔33,3); umbrales escalados a 1000/base
  (late 0,96/0,90, bajar avg>0,90, subir avg<0,75 durante 5 s).
- `AVPSettings`: `KLVR_PACE_FALLBACK=1` con halfRate, `KL_LOG_TAG=engine`, foveado por defecto `.m2` (clave `avp.fov2`),
  MetalFX forzado off (no implementado en ningún motor; picker quitado de `AVPSettingsView`).
- `AVPLauncher`: `AVPCertificateGate` es lo primero mientras no haya .p12 (antes de carpeta/Steam/descarga);
  `AVPModel.startInstall` exige certificado. `AVPLog.engineLogs` en compartir/espejo.
- VPKTAA + foveado: `kl_gpu_time.m` foveа también pases 1x con VPKTAA (multiview `renderTargetArrayLength>1`, depth
  ≥1024, color no RG16F; log `[vrr] foveating 1x`). `VPKTAACore` kernel con `rasterization_rate_map_decoder`
  (buffer 3 datos del mapa, buffer 4 `uint4` on/capa): reproyecta en pantalla y vuelve a físico para historia/votos;
  reset al cambiar de mapa. `KleptonTAA.makeInput` toma `kl_vrr_map_for` (log `[taa] eye N is foveated`).
Riesgos a mirar en el log: sombras en cascada si son layered (se foveaarían), MV de VPKEngine en layout físico o no.

## Build 8 (`559ff52`, CI OK) — logs B7
- MoltenVK B7: foveado `soft` OK (físico 67 %), GPU 30→24 ms, ~40 fps sin fijar: `pace_plan` usaba 90 Hz (KL_DISPLAY_HZ
  forzado) → sin fallback. Usuario: ojo izquierdo mal con foveado (sin diagnosticar; log de capas añadido).
- VPKEngine (antes VPKEngine) B7: "No se ha podido inicializar Vulkan" antes de vkCreateInstance: VPVulkan no anuncia
  WSI (`instanceExtensions()` sin VK_KHR_surface; device sin VK_KHR_swapchain) y Source 2 lo exige.
Cambios B8:
- `kl_vulkan.c`: `g_own_wsi` (vk_init: driver sin VK_KHR_surface) → `kl_vk_native_wsi=0`; anuncia VK_KHR_surface +
  VK_EXT_headless_surface (instancia) y VK_KHR_swapchain (device); xlib/xcb/wayland/headless → superficie sintética
  (`klvk_CreateAnyLinuxSurface`); ramas native WSI de `ours()` con `&& !g_own_wsi`. CreateInstance/CreateDevice ya
  descartan lo que el driver no tiene.
- `kl_app.c` `kl_guest_display_rate()` (tasa medida) → `pace_plan` en `klvr_platform_klepton.c` (redondeada).
- `kl_gpu_time.m`: log `[vrr] foveated map (...) N layer(s)`. Textos visibles VPKEngine → VPKEngine.

## Build 9 (`4c872ed`, CI OK) — VPKEngine: shaders de Alyx al 100 % offline
Log B8 (VPKEngine): instancia y device OK (WSI de B8 funciona); 125k `vk.err what=msl` + "Error in Init() of
RenderDeviceMgr001". Diagnóstico offline, sin visor:
- `scripts/shader-harness.sh <pipelines.foz>`: VPKEngine (ref + patches) en Linux con backend null + fossilize-replay
  (556da9f, filtro de features desactivado con FZ_NOFILTER) → mismo camino SPIR-V→VPIR→MSL que el visor.
  `VPVK_DUMP_DIR` vuelca IR/SPIR-V de los fallos. El .foz es del usuario (AVP/Cache): nunca al repo.
- Resultado: 1218 módulos, 3030 graphics + 8 compute, 5760 traducciones, **0 errores** (antes 125k).
`vpkengine-patches/0011` (VPVulkan):
- `spirv/lower.cpp` compositeInsert: operandos invertidos (w3 = Object, w4 = Composite) → 117k errores.
- subpassLoad MS: operando Sample (w6) o 0. GLSL ModfStruct/FrexpStruct/MatrixInverse sin `vt()` de struct.
- Dual-source blending: `IoVar.blendIndex` (Decoration Index), verify (solo loc 0), MSL `[[color(0), index(1)]]`,
  `MslShader.dualSource`; BlendFactor Src1*/SrcAlphaSaturate (core + metal + metal2, static_assert); si el FS no
  tiene index(1) o attachment≠0, Src1→Src.
- Features: multiDrawIndirect + drawIndirectFirstInstance (commands.cpp ya expande), maxDrawIndirectCount 1<<30.
- ctest VPKEngine: 129/149, los mismos 20 fallos previos (goldens MSL desactualizados + gpu_spirv.subpass, ajenos).
Hipótesis Init: fallaban pipelines de arranque por los shaders. Sin confirmar hasta el log B9. Pendiente si persiste:
features que MoltenVK daba y VPVulkan no (tessellation, int16/64, largePoints, multiViewport, inheritedQueries).
No validable offline: compilación Metal del MSL (sale en el log del visor).

## Patch 0012 (solo tests, sin efecto en runtime) [skip ci]
- Goldens `gpu/shader/msl/tests/*.metal` regenerados (VPMSL_UPDATE=1): solo cabecera `VP_PSZ` y guardas `VP_NO_FDEPTH`.
- `gpu_spirv.subpass`: el test mapeaba input 1 → color 1 (otra imagen, uvec4); ahora solo {0→0}. VPVulkan nunca
  llama a `toFramebufferFetch` (lee input attachments como textura/copia, patch 0002): no afectaba a Alyx.
- ctest VPKEngine con 0011+0012: 149/149.

## Siguiente
Logs B7: (1) MoltenVK: `[guest] pacing`, `pace governor`, `[vrr] foveated map`, `[gputime]`; (2) VPKEngine:
`klepton-boot-vpkengine.log` + crash; `vk.feature`, `vk.err`, `vk.unimpl`, `[taa]`, `[vrr] foveating 1x`.

## Pendiente
- **Pausa → launcher** (pedido): no cerrar la app al terminar la inmersiva (`KleptonApp.swift` Lifecycle: hoy
  "no window to return to — exiting"); congelar guest (pacer/stop de frames), abrir launcher con "Volver al juego" y
  reabrir la inmersiva. Ajustes en vivo al volver: aniso (vpvk_config gen), foveado (invalidar `g_vrr_maps`),
  VPKTAA pct/sharp (hoy `let` en `KleptonTAA`), FPS HUD; resolución/texturas vía convars del juego (SendToConsole);
  motor y tamaño máx. marcados "al reiniciar".
- **Botón PS**: log B6 "Button Menu=free" y el PS no aparece en `physicalInputProfile` (no capturable igual que en
  VQP, mismo código). Garantizar que PS/corona → fondo = pausa (no salida) + log de elementos/eventos al pulsar PS.
- VPKEngine arrancando Alyx (necesita log B7). MetalFX (VPKEngine `vpvk_config_set_metalfx`) y luego reactivar el ajuste.
- QR de Steam. Píldoras de batería: verificar mano.
