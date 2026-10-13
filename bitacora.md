# Bitácora — AVP

Half-Life: Alyx (build ARM64 Linux de Steam) nativo en Apple Vision Pro. Todo en el visor: Steam oficial → descarga →
conversión ELF→Mach-O (`klepton_ld` en proceso) → firma on-device (`vp_codesign` + .p12) → precompilado de pipelines →
juego. Gráficos: VPEngine (por defecto) o MoltenVK (motor de diagnóstico). Plan: `PLAN.md`.
Historial completo: `git log -p bitacora.md`.

## Estado tras la build 6 (`6c86550`, release `visionos`, AVP.ipa — compila, CI OK)
Enlace: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa

### 100 % funcional en el visor (pruebas 1–3, MoltenVK)
- Login Steam (contraseña + Steam Guard email), propiedad (paquete 134870), descarga build 25487405 (~54 GB en 18 min,
  background), Steam Cloud (bajadas 16).
- Import .p12 (lector del sistema falla -26275 → lector de VPEngine OK). Firma `req4k` aceptada por el sistema.
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
  `scripts/build-{luajit,sdl,fossilize}.sh`; VPEngine = `vpengine.ref` (19a1f44) + `vpengine-patches/0001..0010`.
  Fixes CI: LuaJIT `MACOSX_DEPLOYMENT_TARGET=14.0`; `dismissWindow` duplicado en BootView.
  Arranque: `AVPLaunch.configure()` → `kl_app_configure_alyx(resources, game, dylibs, config, data)`; BootView
  (`KleptonApp.swift`) hace `kl_app_boot` y abre la inmersiva. `kl_app.c` stall dump → `kl_sample_snapshot`.
- **B2** logs: todo en `Documents/Logs Alyx/` (`AVPLog.directory`); `AVPLog.start()` fija `KL_ALYX_LOG_DIR` antes de
  cualquier configure; `kl_app.c` `g_logdir` (boot, crash, alyx-error). Copia en `<carpeta AVP>/Logs Alyx/`.
- **B3** `AVPPrepare.sources`: el ELF más grande por stem dentro de cada carpeta (libavcodec.so vs .so.58…); prewarm
  devuelve rc y se registra con `kl_app_status()`.
- **B4** prueba 2 (MoltenVK con VPKTAA=1, vr_msaa 0, KL_VK_CLEAR_NEW): primer frame → `Lost VkDevice … GPU Hang` →
  SIGSEGV en librendersystemvulkan+0x21f9c0. Fix: `AVPSettings.taaActive = vpktaa && engine == .vpengine`; con MoltenVK
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
  píxel, desoclusión) + `KleptonTAA.swift` (prefiere MV de VPEngine, `KL_VPKTAA_MV_SRC=auto|appsw|vpengine`);
  jitter OpenVR `kl_vpktaa_jitter_tangents` en `GetProjectionRaw`; MV nativos en VPEngine (parche 0009/0010,
  `vpvk_motion_get`, RG16F por ojo, doble posición con datos del frame anterior; draws opacos multiview).
- Solo se activa con motor VPEngine (`taaActive`). Con MoltenVK + VPKTAA + MSAA 0 hubo GPU hang (B4): sin aislar si fue
  el VPKTAA (depth SAMPLED/STORE + copias en la cola del juego) o el MSAA 0.
- Opción pendiente si VPEngine aún no arranca: ajuste experimental VPKTAA con MoltenVK (solo profundidad) para bisectar.

## Siguiente: el usuario envía los logs de la build 6
Pedido: (1) partida corta con MoltenVK (comprobar idioma español), (2) partida con VPEngine; carpeta `Logs Alyx`
(app.txt, klepton-boot.log, klepton-crash.log, census.txt, console.log, prewarm.log).
Revisar:
- `census.txt`: versión/extensiones/features pedidas en vkCreateDevice, capacidades SPIR-V por módulo (int64/16-bit,
  MS reads, subgroup), teselación, depth bounds → lista de huecos de VPEngine. Del log B5: 0 índices dinámicos,
  0 timeline, 0 vkQueueSubmit2, 8 query pools (tipos 0 y 2), 0 render passes (dynamic rendering).
- `console.log`: líneas `AVPFORCE` (si el juego cambió convars forzados) y errores del juego.
- Con VPEngine: `vk.feature`, `vk.err what=shader`, `vk.unimpl`, `vk.motion`, `[taa] inputs/stats`, `gpu.hold`.
- Rendimiento: `[gputime]` y `[openvr] frames:` (MoltenVK dio ~33 fps).

## Pendiente
- VPEngine: int64/16-bit en shaders, teselación, depth bounds, foveado (`MTLRasterizationRateMap`), MetalFX, bindless
  (no necesario para Alyx: todos los descriptores count 1).
- Rendimiento a 45 fps (foveado, resolución, VPEngine).
- QR de Steam; `vpvk_config_set_metalfx` / `_texture_cap` no existen aún (la app solo los registra).
- Píldoras de batería: verificar mano (vendorName trae "(Left)/(Right)").
