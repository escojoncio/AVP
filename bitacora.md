# Bitácora — AVP

Half-Life: Alyx (build ARM64 Linux de Steam) nativo en Apple Vision Pro (M2). Todo en el visor: Steam oficial →
descarga → conversión ELF→Mach-O (`klepton_ld`) → firma on-device (`vp_codesign` + .p12) → precompilado de pipelines →
juego. Gráficos: **solo VPKEngine** = `escojoncio/VPKEngine` en el commit de `vpkengine.ref` + `vpkengine-patches/`
0011–0038 (CI: `scripts/apply-vpkengine-patches.sh`; un parche nuevo = fichero `00NN-*.patch` en esa carpeta, generado
con `git format-patch` sobre ref+parches). Sin MetalFX, sin MoltenVK (solo referencia), sin LOD/cull que cambie lo
visible, sin bajar fidelidad: el rendimiento sale de resolución y de optimización pura del motor.
Plan: `PLAN.md`. Historial completo: `git log -p bitacora.md`.
IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: **B46**, compilada OK).
Builds: solo con `[build]` en el mensaje o dispatch manual; docs con `[skip ci]`.

## 100 % funcional (validado en el visor)
- Steam (login + Guard, propiedad 134870, build 25487405, Cloud), .p12, firma on-device, 90 libs, prewarm ~4150
  pipelines que espera a la caché del SO; `.foz` extra importables desde Ajustes.
- VPKEngine: 0 cuelgues desde B17, MSAA 4x correcto, amplificación de vértices (B34), occlusion culling medido (B39,
  `0037`: escena 3,6–10 ms, draws 1 813 → 183), orden de GPU por recursos (`VP_CB_ORDER=2`).
- Foveado VRR (rate map Klepton, zona redonda tipo P.T., periferia 10 %, VPKTAA en periferia): escena MSAA + pases 1x de
  ojo + subtítulos foveados. Físico ≈ 50 % de los píxeles del ojo. Post (tonemap/bloom) NO foveado.
- Compositor: compone solo imágenes nuevas (`skipRefreshIfSame`, REGLA: todo frame consultado a CompositorServices
  se presenta), panel 100 Hz latcheado bien (B34), recon de periferia precalculada (B41).
- Regulador (`klvr_platform_klepton.c` `pace_governor`): 50 fps (1/2 de 100 Hz) o 33 (1/3), con tiempo de GPU
  EXCLUSIVO (`0036` + `kl_gpu_time.m`). Ojo: el borrado del atlas de sombras no tiene timestamps y no se cuenta.
- Reloj del juego (B44): `klvr_game_hz` reporta a Alyx el ritmo real del regulador (50/33), 50 durante cargas (el tick
  del mapa = 1/Hz al cargarlo), la tasa medida si va por debajo del ritmo. Sondas `KLTIME` (consola) y
  `[openvr] clock` lo verifican. Validado por el usuario con «Fija 50».
- OpenVR (cabeza + 2 Sense), dedos con manos libres (con Sense en la mano visionOS no da manos), altura del jugador,
  subtítulos a la altura de la vista, idioma, pausa, logs en `Logs Alyx/`.

## Lecciones (no repetir)
- `Window(id:)` en el launcher mata la app al tocarla: usar `WindowGroup`.
- `KL_VRR_PHYS=1` (render area = físico del mapa) rompe la imagen; `VPVK_AMPLIFY` solo es seguro con PHYS=0.
- Ojos al compositor sin copia (`eyeDirect`) da parpadeo: Alyx usa UNA imagen de ojo para las 3 etapas.
- MSAA "en tile" (`0034`) era falsa premisa: el juego ya pide DONT_CARE + resolve.
- Nunca abandonar un frame tras `queryNextFrame` (aborta `BUG IN CLIENT`).
- Medir con «Medir GPU por pase» ON añade coste (`VP_EXCL_TIMING` en todos los frames): comparar A/B con el mismo valor.
- El usuario no tiene Mac y nunca obtiene `.ips`: todo diagnóstico va al log de la app.
- B45 (arranque anticipado 6 ms) no reduce el hueco inicial: el juego no estaba esperando al pacer.
- Nada de volcados/capturas pesadas automáticas en mitad del juego: congelan 0,25–1,5 s.

## Estado del rendimiento (Logs_Alyx_34 = 80 %, 2_12 = 50 %, menú con UI, mismo sitio)
`[passes]` W4: span 25,3 → 18,5 ms, ocupado 21,6 → 13,4, GPU parada 3,7 → 5,1. Solo ~4 ms escalan con píxeles.
Reparto del fijo a 50 % (modelo 14,4 fijo + 4,2 escalable = 18,6 vs 18,5 medido):

| Coste | ms | Dónde |
|---|---|---|
| GPU parada entre #003 y #004 (CPU del juego construyendo el frame tras ser soltado) | ~5 | `kl_app.c` pacer → **B45** |
| UI Panorama en serie al final: ~12 blits 0,1–0,4 ms intercalados (¿mips por `vkCmdBlitImage` nivel a nivel?) + 37 pases ui-2d + burbujas | ~3,5 | VPKEngine |
| vtx escena + parte fija del frag | ~3,2 | legítimo |
| compute `vk.comp31` (niebla/binning) | 1,37 | legítimo |
| cadena de bloom: ~0,08 ms por encoder diminuto + espera ~0,4 en E/8 | ~0,9 | `waitFrontier` |
| borrado del atlas D32F 4096² (`R 0x0 L0 z 4096x4096 f252 ld2 st1`, sin draws, sin timestamps); en el menú nadie lo usa después | 2–3,6 (oculto en el hueco) | VPKEngine |
| copias de ojos a tamaño lógico completo (#076/#078) + compositor (1,2 ms/composición + vista ancha 0,21x2) | ~1,5 | app |

## B46 — en la IPA, PENDIENTE DE VALIDAR (test A/B automático)
Logs_Alyx_2_13 (B45, 80 %, menú): **B45 descartado**: el hueco de GPU parada sigue en 5,7 ms con el arranque anticipado.
**Caída a 0 fps ~1,5 s = el volcado de pases `VP_DUMP_FRAME=6000`** (lectura de ~300 MB; `GPU finish worst 1523 ms`
justo en ese frame, repetido en el log anterior): eliminado (el volcado L3+R3 sigue). Timeline W4: la UI de Panorama
(~12 blits + pases 1058²) empieza a 7,7 ms pero espera hasta ~19,8 ms porque `waitFrontier` espera a TODO (escena y
ojos incluidos) → se serializa al final. El hueco inicial coincide con el borrado sin timestamps del atlas 4096².
- `vpkengine-patches/0038-*`: interruptores en caliente `vpgpu::gRuntimeOpts` (`vpgpu_metal2_set_opts`):
  bit0 esperas solo a productores (`CompileOptions::producerWaits` → `Barrier::producers`, sin `covered()`; backend
  `encFences`/`waitProducers`; un productor sin encoder Metal → espera todo; las fences propias se quedan en el frontier
  = cola para el join; solo con `cbOrder`); bit1 borrado de profundidad redundante → blit vacío que conserva las fences
  (`cleanDepth`, cualquier escritura lo invalida, un cb con error lo vacía vía `gCleanEpoch`). Además knockout de un
  pipeline (`vpgpu_metal2_set_knockout`), censo de pipelines, contadores (`vpgpu_metal2_opt_counters`: cbs, esperas
  de fence, clears saltados, draws indirect-count codificados vs reales leídos del kernel de fix-up, palabra 3).
  Test `producers` en `gpu/core/tests` (3000 frames aleatorios, 0 violaciones; detecta la mutación).
- Klepton `kl_gpu_time.m` (`KL_ABTEST=1`, ajuste «Test automático de rendimiento», `avp.abTest`, off por defecto):
  espera 25 s fuera de cargas → censo 3 s → 3 rondas × 5 máscaras (OFF, ALL, ALL−bit) 0,6 s + 2 s → knockout de 26
  pipelines (20 render + 6 compute, ≥ 80 % de frames) con línea base cada 5 → `[abtest] VERDICT` y aplica la máscara
  ganadora. Métrica: span UNIÓN del frame (busy[0]). Bit2 = recorte de la copia de ojos al área física del mapa
  (`klvr_plat_eye_trim`, `kl_vrr_phys_extent`, +2 texels; se desactiva solo si hay pases que leen el ojo entero).
  HUD: línea amarilla con la fase y «TEST TERMINADO» (desaparece 60 s después). Capturas solo hasta el frame 120.
- Validar con el log: `grep "\[abtest\]"`: ventanas, VERDICT (SAVES/NO EFFECT/WORSE/INACTIVE/BREAKS), top knockout,
  sobre-codificación indirect-count. Preguntar al usuario si vio fallos visuales y en qué fase del HUD.

## SIGUIENTES PASOS
1. Leer el VERDICT de B46. Lo que AHORRA → por defecto (sin test). Si el knockout señala un shader dominante → mirar su
   MSL/coste. Si indirect-count codificado ≫ real → `MTLIndirectCommandBuffer` / compactar en el fix-up.
2. Si bit0 ahorra pero hay artefactos: algún acceso no declarado en VPVulkan (bindless/descriptor arrays).
3. Pendientes de antes (no hechos en B46): blits de Panorama en un encoder, `vkCmdClearAttachments` como quad dentro
   del pase, timestamps reducidos fuera de ventanas, join solo a `needJoin`, vista ancha del compositor desde la recon,
   `KL_VRR_PHYS_POST`, tiempo de presentación predicho a Klepton, regulador que arranca en 33, 90 vs 100 Hz.

## No tocar (decisión del usuario)
- `vr_expand_cull_frustum`, LOD, cull, SSAO off, sombras, MSAA: nada que cambie lo visible.
- MetalFX y MoltenVK.
