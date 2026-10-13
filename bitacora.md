# Bitácora — AVP

Half-Life: Alyx (build ARM64 Linux de Steam) nativo en Apple Vision Pro. Todo en el visor: Steam oficial → descarga →
conversión ELF→Mach-O (`klepton_ld` en proceso) → firma on-device (`vp_codesign` + .p12) → precompilado de pipelines →
juego. Gráficos: **solo VPKEngine** (repo `escojoncio/VPKEngine` = `vpkengine.ref` + `vpkengine-patches/`). MoltenVK
queda como referencia de diagnóstico (no se usa para jugar ni se arregla nada en él). Sin MetalFX (no sirve en VR). Plan: `PLAN.md`. Historial completo: `git log -p bitacora.md`.
IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: build 10, `97d230e`, CI OK).

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

## Build 11 (sin validar): crash en "Precompilar shaders" de la build 10
- Síntoma (Logs_Alyx_5): `app.txt` acaba en "ajustes enviados a VPKEngine", sin "precompilados N/N"; ni boot log
  nuevo ni crash log (el prewarm corría sin `kl_fault_install` y con stdout/stderr a ninguna parte). Única novedad
  en ese camino frente a la build 9: los thunks de `kl_vk_diag.inc` (sospechoso, sin confirmar).
- `kl_app.c` `kl_app_prewarm_alyx`: log propio `Logs Alyx/klepton-prewarm-<motor>.log`, `kl_fault_install()`
  (informe a `klepton-crash-<motor>.log`), heartbeat (fase `prewarm`).
- `kl_vk_diag.inc`: `klvk_diag_suspend()` (contador global, todo `kl_foz_prewarm`) y `t_pipe_replay` → punteros
  crudos; `kl_fossilize.cpp` `start_replay` resuelve sus `Fns` con `klvk_set_replay_thread(1)`.
- Guardia anti-bucle: `AVPPrepare.prewarm` deja `<data>/prewarm.inflight` ("<n> <bundlePath>"); 1 fallo → 1 hilo
  (`kl_app_prewarm_threads` → `kl_foz_set_threads`, también para el replay del juego); 2 → se salta y vuelve a 1.
- Icono: `app/Assets.xcassets/AppIcon.solidimagestack` (Front palanca / Middle hexágono / Back degradado, 1024²,
  diseño original; generador fuera del repo), `ASSETCATALOG_COMPILER_APPICON_NAME`.

## Siguiente (log de la build 10 con VPKEngine)
- Primero: ¿la build 11 pasa el precompilado? Si cae: `klepton-crash-vpkengine.log` + `klepton-prewarm-vpkengine.log`.
- Si arranca: comprobar imagen en ambos ojos, VPKTAA (`[taa] … foveated`), FPS/GPU (`[gputime]`), pausa (PS izq. 1 s),
  Home/PS accidental + "Volver al juego" (segundo CompositorLayer sobre el mismo guest: sin validar).
- Si sigue "RenderDeviceMgr001": leer `[vk] diag` (ring + errores), la consola del juego tras el message box y
  `vk.format unsupported`. Siguiente hipótesis: identidad GPU (VPVulkan dice Adreno 740 / driver 0.1.0, MoltenVK
  Apple) → interruptor A/B `VPVK_GPU_IDENTITY=moltenvk`.

## Pendiente
- Ajustes en vivo que faltan: resolución/texturas (convars del juego), anisotrópico (solo afecta a samplers nuevos);
  activar/desactivar foveado requiere reiniciar.
- Botón PS: no se puede capturar (solo "Button Menu" en `physicalInputProfile`); queda mitigado por la pausa.
- QR de Steam. Píldoras de batería: verificar mano. Subir 0011–0013 al repo VPKEngine.
