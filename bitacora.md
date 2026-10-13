# Bitácora — AVP

## Build 1 (2026-10-13) — COMPILA (e45e0d7, release `visionos`, AVP.ipa), sin probar en el visor
Fixes de CI: LuaJIT necesita `MACOSX_DEPLOYMENT_TARGET` (host tools); `dismissWindow` duplicado en BootView. VPVulkan con los 10 parches compila.
Base: VisionQuestPro `04f7e6a` (app, Klepton propio, CI). Glovebox (MIT) fusionado en el Klepton propio.
- **x18** (`klepton/runtime/kl_x18.c/.h`, `klepton/tools/klepton_ld.c`): veneers de Glovebox (casp x18:x19, blr/adr x18,
  stp/ldp con writeback, límite 12 instr.). Se conserva `KLEPTON_LD_INPROC`, error por setjmp y LC_CODE_SIGNATURE vacío;
  salida con secciones `__klelf/__kltext/__klconst`, LC_FUNCTION_STARTS. API `klepton_ld_run(in, out, err, len)`.
- **Runtime Linux** (`klepton/runtime/linux/**`, `openvr/**`, `gfx/kl_gpu_time.m`, `kl_vk_pipe_hooks.h`): merge a 3 vías
  sobre Klepton `ce74582`. TLS ELF de Glovebox (`kl_elftls`) sustituye al TLS propio también para Quest.
  `kl_vulkan_eye_depth_mtl` corto → `kl_vulkan_taa_depth_mtl`.
- **Arranque**: `kl_app_configure_alyx(resources, game, dylibs, config, data)` (kl_app.c); `AVPLaunch.configure()` lo
  llama desde el hilo de BootView, que luego hace `kl_app_boot` y abre la inmersiva (camino de VQP).
  `AlyxBoot.swift`: `AVPLaunchPaths`, `prewarm`, `pipelineProgress` (su `launch` queda sin uso).
  configDir: `alyx-env.txt` (`@config/ @data/ @game/ @dylibs/`), `alyx-convars.lua` → `gameinit.lua` vía `KL_LUA_INJECT`,
  `video2.txt` + CSV de fidelidad instalados en cada arranque (Vendor/Device del driver; original en `<f>.game`).
  Logs: `<data>/logs/klepton-boot.log`, `klepton-crash.log`, `alyx-error.txt`; `<data>/klfz/` recorded.foz, prewarm.log.
- **Censo Vulkan** `KL_VK_CENSUS=1` (`gfx/kl_vk_census.inc`, tablas de vk.xml): líneas `[census]` únicas + `[census] summary`
  cada 600 frames.
- **VPKTAA jitter OpenVR**: `kl_vpktaa_jitter_tangents` en `GetProjectionRaw` (`klvr_plat_jitter`), tangentes sin jitter
  en el render pose, near/far del submit.
- **Memoria**: `KL_VK_BUDGET_OS` (budget = uso + `os_proc_available_memory` − `KL_VK_BUDGET_RESERVE_MB`=512).
- **Deps** (CI, cacheadas): `scripts/build-luajit.sh` (c6ffc141, GC64, sin JIT), `build-sdl.sh` (SDL3 3.4.16 + sdl2-compat
  2.32.72 + parche), `build-fossilize.sh` (556da9f + miniz) → `build/deps`.
- **App** (`app/Sources/AVP*.swift`): Steam (`app/Steam/`, SteamLauncherKit de Glovebox; descarga ELF ARM64 reales,
  manifests fijos build 25487405), carpeta AVP por bookmark (game/Cache/Logs), firmados en Application Support/AVP/Signed,
  preparación con sellos: debs (`avp_deb.c`, xz por Compression) → conversión (stem `+`→`x`) → firma → `pipelines.foz`
  (`avp_pipelines.c`, idéntico al Python de Glovebox en prueba sintética) → prewarm. Ajustes en `AVPSettings` escritos
  en cada arranque. Recursos: `app/Resources/` (receta, debs JSON, defaults).
- **VPEngine**: `vpengine.ref` = 19a1f44 + `vpengine-patches/0001..0010` (Vulkan 1.3, local_read, sync/timeline/sync2,
  host_image_copy, estado dinámico, memory_budget, timestamps, MS reads + resolve, vectores de movimiento nativos
  `vpvk_motion_get`, MV por defecto con VPKTAA). KleptonTAA prefiere MV de VPEngine (`KL_VPKTAA_MV_SRC=auto|appsw|vpengine`).
  Datos de Alyx: todos los descriptores count 1, sin push constants → bindless no necesario.

### Comprobar en el primer log
- Compila. Login Steam + propiedad + descarga; conversión y firma de ~89 libs; `pipelines.foz` creado.
- Arranque con MoltenVK: líneas `[census]` (lista para VPEngine), `[dl] … unresolved import(s)`.
- Con VPEngine: `vk.feature`, `vk.err what=shader` (int64/16-bit no soportados), `vk.motion`.

## Build 2 (2026-10-13) — logs separados de VisionQuestPro
- Prueba 1 (MoltenVK): la preparación terminó en segundos y el juego no arrancó; logs de Alyx mezclados con VQP (mismo
  contenedor, mismo bundle id) y el boot log en Application Support/AVP/Data/logs (invisible).
- Ahora todo en `Documents/Logs Alyx/`: app.txt, app-previous.txt, klepton-boot.log, klepton-crash.log, alyx-error.txt;
  copia en `<carpeta AVP>/Logs Alyx/` (con prewarm.log). `AVPLog.start()` fija `KL_ALYX_LOG_DIR` antes de cualquier
  `kl_app_configure_alyx` (prewarm o Play); kl_app.c `g_logdir`.

## Pendiente
- VPEngine: int64/16-bit en shaders, teselación, depth bounds, foveado (MTLRasterizationRateMap), MetalFX, bindless.
- QR de Steam; `vpvk_config_set_metalfx`/`_texture_cap` no existen aún (solo se registran).
