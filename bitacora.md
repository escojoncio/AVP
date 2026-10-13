# Bitácora — AVP

Half-Life: Alyx (build ARM64 Linux de Steam) nativo en Apple Vision Pro. Todo en el visor: Steam oficial → descarga →
conversión ELF→Mach-O (`klepton_ld` en proceso) → firma on-device (`vp_codesign` + .p12) → precompilado de pipelines →
juego. Gráficos: **solo VPKEngine** (repo `escojoncio/VPKEngine` = `vpkengine.ref` + `vpkengine-patches/`). MoltenVK
queda como referencia de diagnóstico (no se usa para jugar ni se arregla nada en él). Sin MetalFX (no sirve en VR). Plan: `PLAN.md`. Historial completo: `git log -p bitacora.md`.
IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última OK en CI: build 16).

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

## Build 17 (sin validar): causa de los cuelgues de GPU + crash
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

## Siguiente
- Log build 17: ¿0 `Caused_GPU_Hang`? Buscar `vk.resolve as_copy`, `resolve_refused` (=0), `gpu.hunt` (si hubo
  cuelgues: veredicto/culpable + `gpu.hunt.msl`), `[cp] queue replaced`. Con imagen: rendimiento (34 fps en B15).
- Optimización posible: la copia del depth 1x (≈60 MB/frame) podría evitarse aliasando el destino con la fuente.

## Pendiente
- Ajustes en vivo que faltan: resolución/texturas (convars del juego), anisotrópico (solo afecta a samplers nuevos);
  activar/desactivar foveado requiere reiniciar.
- Botón PS: no se puede capturar (solo "Button Menu" en `physicalInputProfile`); queda mitigado por la pausa.
- QR de Steam. Píldoras de batería: verificar mano. Subir 0011–0013 al repo VPKEngine.
