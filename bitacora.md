# Bitácora — AVP

Half-Life: Alyx (build ARM64 Linux de Steam) nativo en Apple Vision Pro (M2). Todo en el visor: Steam oficial →
descarga → conversión ELF→Mach-O (`klepton_ld`) → firma on-device (`vp_codesign` + .p12) → precompilado de pipelines →
juego. Gráficos: **solo VPKEngine** = `escojoncio/VPKEngine` en el commit de `vpkengine.ref` + `vpkengine-patches/`
0011–0037 (CI: `scripts/apply-vpkengine-patches.sh`; un parche nuevo = fichero `00NN-*.patch` en esa carpeta, generado
con `git format-patch` sobre ref+parches). Sin MetalFX, sin MoltenVK (solo referencia), sin LOD/cull que cambie lo
visible, sin bajar fidelidad: el rendimiento sale de resolución y de optimización pura del motor.
Plan: `PLAN.md`. Historial completo: `git log -p bitacora.md`.
IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: **B45**, compilada OK).
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

## B45 — en la IPA actual, PENDIENTE DE VALIDAR
- `klepton/visionos/Sources/kl_app.c` `guest_pace_wait`: con `KL_GUEST_PACE_LEAD_MS` (> 0) espera eff−1 publicaciones
  y suelta al juego `lead` ms antes del refresco que completa su turno (`g_guest.pub_t` = hora de la última
  publicación; `owed` = la publicación siguiente ya pertenece al frame soltado). Log `[guest] running start: ...`.
- App: ajuste «Arranque anticipado del frame (CPU en paralelo con la GPU)» en Diagnóstico, `avp.runStart`, ON → 6 ms,
  OFF → 0 (= B44). `resetToDefaults` repone `reportedHz` y `runningStart`.

## SIGUIENTES PASOS (en este orden; no saltar la validación)

### Paso 1 — Validar B45 con el log del usuario (sin build)
Pedido al usuario: menú al 50 % y al 80 %, mismo sitio, «Medir el tiempo de GPU por pase» ON, y una tanda con
«Arranque anticipado» OFF para A/B. Mirar en `klepton-boot-vpkengine.log`:
1. `[guest] running start: frames released 6.0 ms before their refresh` presente.
2. `[passes] W3/W4 ...: GPU idle inside the span` debe bajar de ~5 ms a < 1 ms; en el timeline `[passes] W4 f<N> #004
   at` debe estar < 1,5 ms (antes 5,1–5,3).
3. `[openvr] frames: ... render` NO debe crecer (≈ 4–5 ms); que `wait` baje ~6 ms es normal.
4. `[cp] refreshes per composited picture (last 250)`: a 50 % casi todo en `2:` (antes `2:184 3:66`).
5. `[openvr] clock` y `KLTIME`: siguen al 100 % (el reloj no debe cambiar).
6. Si el hueco NO baja: las fences propias de Source 2 serializan → relanzar con `KL_VK_FENCESTATS=1` (env) y mirar
   qué espera el juego entre su primer y segundo submit.
7. Si baja: el borrado del atlas 4096² ya no queda oculto y aparecerá como nuevo hueco tras #001 → Paso 3.3.

### Paso 2 — Diagnóstico de draws indirectos (VPKEngine, parche 0038, solo log)
Sospecha (sin verificar): `vkCmdDrawIndexedIndirectCount`/`vkCmdDrawIndirectCount` codifican `maxDrawCount` draws de
Metal aunque el contador de GPU diga menos (`gpu/metal2/src/metal_backend.mm` ~3112–3138; `gpu/vulkan/src/
commands.cpp:703` `in.drawCount = indirectCount`). Añadir a la línea `vk.submit`/`gpu.frame`: número de llamadas
indirect-count, suma de `maxDrawCount` codificada y, leyendo el buffer de contador tras completar el command buffer,
suma real. Si codificado ≫ real: siguiente parche = `MTLIndirectCommandBuffer` + `executeCommandsInBuffer:
indirectBuffer:` (el rango sale del contador), o compactar en el kernel de fix-up y limitar al contador.

### Paso 3 — Recortes de coste fijo sin pérdida (VPKEngine 0039+), uno por parche, cada uno con env de A/B
1. **Blits de Panorama**: confirmar con `gpu.dump`/`gpu.enc label=` qué son los ~12 blits (#026–#073 en 2_12 W3).
   Si son mips encadenados (`vkCmdBlitImage` nivel i → i+1 de la misma imagen): agruparlos en un solo encoder de blit
   o `generateMipmapsForTexture`. Ahorro esperado ~1,3 ms en menús.
2. **`waitFrontier` solo a productores** (`metal_backend.mm` ~2429–2438): hoy cada encoder con barrera espera a TODOS
   los fences sin ordenar; guardar en cada `Barrier` las posiciones de los encoders que escriben lo que se lee y esperar
   solo a sus fences. Igual en el fix-up de indirectos (~2587–2590, espera frontier + join). Esperado 1–2 ms.
3. **Borrado redundante**: estado por textura «limpia con valor v» (cualquier escritura lo invalida: attachment con
   Store, storage write de compute, destino de copia/blit, subida de host). Un pase solo-clear sin draws con el mismo
   valor sobre una textura ya limpia se omite. En el menú el atlas no se dibuja → el borrado desaparece desde el 2.º
   frame. Además `vkCmdClearColorImage/DepthStencilImage` crean un pase por mip × capa (`gpu/vulkan/src/commands.cpp`
   ~394–425): agrupar capas con `renderTargetArrayLength`. Riesgo: una escritura no rastreada = sombras viejas → env
   de A/B obligatorio.
4. **`vkCmdClearAttachments`** (`commands.cpp` ~304–446) cierra el pase, borra la textura entera y reabre con Load
   (+ `keepAll` fuerza Store en DontCare, MSAA incluido): sustituir por un quad de clear dentro del pase limitado a los
   rects.
5. **Timestamps**: `0036` muestrea etapas en TODOS los encoders siempre; dejar el muestreo completo solo en las ventanas
   `[passes]` y para el regulador solo el primer y último encoder de cada command buffer (`VP_STAGE_TS`).
6. Encoder `vpgpu.join` por command buffer (~2759–2770): probar que esperen solo los encoders con `needJoin` a los
   fences de `carriedIn`.

### Paso 4 — App (sin VPKEngine)
1. Copias de ojos (`klepton/runtime/openvr/src/klvr_vk_submit.cpp` ~251–259) recortadas al área física del rate map
   (`physicalSizeForLayer`, publicada por `kl_gpu_time.m`); el compositor solo lee esa zona.
2. Vista ancha del compositor (`KleptonCompositor.swift` `buildWideView`) desde la recon ya calculada por imagen o desde
   un mip del ojo (0,72 ms x2 a 80 %).
3. Probar el ajuste existente «Post-procesado solo en el área foveada» (`avp.postPhys`, `KL_VRR_PHYS_POST=1`): −0,8 ms
   en tonemap si la imagen sale bien.

### Paso 5 — Pendientes ajenos al rendimiento
- Pasar a Klepton el tiempo de presentación predicho (`kl_ovrp_set_predicted_display_time` no lo llama nadie: el juego
  predice a "ahora + 1/90" y la pose registrada no coincide con la rendida; con running start la diferencia crece).
- El regulador arranca en el fallback (33) y el menú/primeros segundos van así.
- Averiguar por qué P.T./VisionQuestPro obtienen 90 Hz y AVP 100 (tipo/formato de capa): 45→90 costaría menos GPU.
- Menores: ajustes en vivo de resolución/texturas/aniso/zona nítida; QR de Steam; subir 0011–0037 al repo VPKEngine.

## No tocar (decisión del usuario)
- `vr_expand_cull_frustum`, LOD, cull, SSAO off, sombras, MSAA: nada que cambie lo visible.
- MetalFX y MoltenVK.
