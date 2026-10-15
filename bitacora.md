# Bitácora — AVP

Half-Life: Alyx (build ARM64 Linux de Steam) nativo en Apple Vision Pro (M2). Todo en el visor: Steam oficial →
descarga → conversión ELF→Mach-O (`klepton_ld`) → firma on-device (`vp_codesign` + .p12) → precompilado de pipelines →
juego. Gráficos: **solo VPKEngine** = `escojoncio/VPKEngine` en el commit de `vpkengine.ref` + `vpkengine-patches/`
0011–0040 (CI: `scripts/apply-vpkengine-patches.sh`; un parche nuevo = fichero `00NN-*.patch` en esa carpeta, generado
con `git format-patch` sobre ref+parches). Sin MetalFX, MoltenVK solo como motor de prueba (B53), sin LOD/cull que cambie lo
visible, sin bajar fidelidad: el rendimiento sale de resolución y de optimización pura del motor.
Plan: `PLAN.md`. Historial completo: `git log -p bitacora.md`.
IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: **B52**, compilada OK).
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
  espera ≥ 25 s, fuera de cargas y hasta ver el MENÚ (frames reales con ≥ 50 encoders 5 s seguidos; el logo de Valve
  tiene ~28, el menú ~80; `vpgpu_metal2_last_real_encoders`, 0 si no hay frame real en 500 ms; a los 180 s arranca
  igualmente) → censo 3 s → 3 rondas × 5 máscaras (OFF, ALL, ALL−bit) 0,6 s + 2 s → knockout de 26
  pipelines (20 render + 6 compute, ≥ 80 % de frames) con línea base cada 5 → `[abtest] VERDICT` y aplica la máscara
  ganadora. Métrica: span UNIÓN del frame (busy[0]). Bit2 = recorte de la copia de ojos al área física del mapa
  (`klvr_plat_eye_trim`, `kl_vrr_phys_extent`, +2 texels; se desactiva solo si hay pases que leen el ojo entero).
  HUD: línea amarilla con la fase y «TEST TERMINADO» (desaparece 60 s después). Capturas solo hasta el frame 120.
- Validar con el log: `grep "\[abtest\]"`: ventanas, VERDICT (SAVES/NO EFFECT/WORSE/INACTIVE/BREAKS), top knockout,
  sobre-codificación indirect-count. Preguntar al usuario si vio fallos visuales y en qué fase del HUD.

## Logs_Alyx_35 (B46b, 80 %, menú, 45 fps, panel 90 Hz) — primer test A/B
- Esperas solo a productores (bit0): OFF 22,1/22,6/22,5 ms de span unión vs ALL 20,8/21,0/20,9 → **−1,5 ms**, sin
  cuelgues. Ruido bimodal entre ventanas (~20,8 vs ~22,2) y paso a «thermal fair» a mitad: atribución por bit ruidosa.
- Clear skip (bit1): 0 candidatos → bug: el atlas tiene render area 4096x4096 (Vulkan siempre la da) y se exigía 0.
- Recorte de ojos (bit2): activo (182 copias/ventana) sin efecto medible.
- Knockout (mask 0, 14/22: el usuario salió antes): **vk.pipe6857** (key 9c3c6a1c73ab3fe1, 12 draws/frame) **2,31 ms**
  y **vk.pipe6965** (key b7bf7501c33cbd71, 15 draws/frame) **1,78 ms** = ~18 % del frame. El resto < 0,4 ms.
- Indirect-count: 0 llamadas en el menú.

## B47 — en la IPA, PENDIENTE DE VALIDAR
- `0039`: clear skip acepta render area ≥ mip; censo con detalle (vs/fs/cs, encoder destino, verts·inst/frame) →
  `vpgpu_metal2_census_detail`; `vpgpu_metal2_dump_pipeline_msl(key, dir)` escribe `shader-<key>-vs|fs|cs.metal`;
  `VPVK_RUNTIME_OPTS` = máscara inicial.
- App: `VPVK_RUNTIME_OPTS=1` siempre (esperas a productores por defecto).
- Test: máscara por defecto (1) en pausa/knockout/final; final = defecto + SAVES − WORSE/BREAKS; veredicto de opts
  impreso al acabar esa fase; ventanas 0,6 + 1,6 s; tras el knockout `[abtest] detail` de cada candidato y MSL de los
  3 que más ahorran (≥ 0,5 ms) en la carpeta de logs (requiere «Capturas»); HUD con tiempo restante.
- B47b: cada línea `[abtest]` también en `Logs Alyx/abtest-result.txt` (`ab_out`, fsync al terminar): en Logs_Alyx_35 el
  usuario vio «TEST TERMINADO» pero la copia del log acababa ~10 s antes (sin veredicto).
- Validar: `[abtest] detail`/`msl` de pipe6857/pipe6965 → leer su MSL y su encoder destino para optimizarlos.

## Logs_Alyx_36 (B47b, 80 %, menú) — test v2
- **Panel 90 Hz de día / 100 Hz de noche** (anti-parpadeo de luz de 50 Hz, lo elige visionOS): B45 de noche 100 Hz → 50 fps;
  B46b/B47b de día 90 Hz → 45 fps con el mismo trabajo de GPU (~19,7 ms excl). No es regresión.
- El span UNIÓN es bimodal por ventana (~20,3 / ~22,4 ms según la fase con el compositor) → los «shaders caros» de
  Logs_35 (pipe6858 2,3 ms, pipe6966 1,8 ms) eran falsos: en 36 ahorran 0,09 / −0,40. El exclusivo es estable (19,6–19,9).
- Clear skip (bit1) ya actúa (73/73) pero **empeora 2,5 ms de unión** (excl igual) → retirado del test y de cualquier máscara.
- Esperas a productores: ≈ −0,2 ms excl (sin efecto); recorte de ojos ≈ +0,5 unión, no significativo.
- Knockout (unión, poco fiable): ningún shader > 0,8 ms. Top: vk.comp15 (cs 27a976ed39a2e805, niebla volumétrica 3D,
  tabla de 32 float2 inicializada en memoria privada por hilo + índice dinámico, 6 bucles anidados con contadores
  `vp_guard`/`vp_budget`) 0,78 ms. MSL guardado.
- Detalle del censo: pipe6707 (2f0796fd…) 830 k verts·inst/frame y pipe6966 528 k en la escena MSAA (enc 3).

## B48 — en la IPA, PENDIENTE DE VALIDAR
- Test v3: decide con la MEDIANA EXCLUSIVA por ventana (`xs`), unión solo informativa; ventana con < 8 frames con
  exclusivo = no usada. Configs OFF/ALL(5)/ALL−bit0(4)/ALL−bit2(1); bit1 nunca se aplica. Knockout 0,4 + 1,6 s,
  ranking por ahorro exclusivo, MSL de los ≥ 0,3 ms.
- Ideas de traductor (pendientes de datos): arrays privados de solo constantes → `constant` LUT; quitar guardas de
  bucle con contador acotado.

## Logs_Alyx_2_14 (B47b otra vez, no B48) y análisis del corpus de shaders
- Knockout (unión): vk.comp15 (niebla volumétrica) 2,16 ms, pipe6950 (escena MSAA, 3 draws) 1,53, pipe6692 (pase de
  ojo, 4 draws) 0,91; MSL de los tres en los logs.
- Corpus: `steamapp_pipeline_cache.foz` del PC (A:\SteamLibrary\steamapps\shadercache\546560\fozpipelinesv6, 2539
  gráficos + 22 compute → 1675 shaders únicos). Harness local: VPVulkan null + fossilize-replay (Valve, 556da9f),
  `VPVK_DUMP_MSL=<dir>` (0040) vuelca cada MSL (y SPIR-V si `VPVK_DUMP_DIR` también está). 0 errores de traducción.
- Hallazgos: 0 decoraciones RelaxedPrecision (nada de fp16 automático); fast math ya activo; guardas de bucle NO
  impiden desenrollar (probado con clang -O2: los bucles de 4 iteraciones se desenrollan igual con vp_guard/vp_budget);
  91 shaders con arrays privados, 37 de ellos solo tablas constantes (discos de Poisson, kernels, jitter de la niebla:
  256–512 B escritos por píxel/hilo en memoria de pila).
- `0040`: `planConstTables` (msl.cpp) → `constant uint4 vp_k<slot>[]` de programa; `VPMSL_CONST_TABLES=0` lo apaga.
  Revisado: semántica igual (todas las cargas dentro del bloque B tras su último store). Riesgo menor: índice
  divergente por hilo en `constant` (la niebla) — medir en el knockout de B49 (vk.comp15 debería bajar).
- Pendiente/ideas: copias de 1058² de Panorama (13 copias/frame, ~2,7 ms en «blit»); `packed_float4` en lecturas de
  vértices desde buffers (584 VS); `preserveInvariance=YES` global (no tocar sin A/B: puntitos prepass/color).

## Conclusión tras B46–B49 (para no repetir)
- La resolución NO es palanca: 80 %→50 % solo baja el span 25,3→18,5 ms; ~14 ms son FIJOS (no escalan con píxeles).
  Los shaders de fragmento escalan con píxeles → optimizarlos rinde poco. El objetivo es el coste fijo:
  hueco de GPU parada ~5 ms al inicio del frame (causa desconocida: ni running start B45 ni esperas a productores
  0038 lo mueven; el clear skip lo empeora), UI Panorama ~3,5 ms (menú), vértices ~3,2, compute ~1,4, copias ojos ~1,5.
- B50 (en la IPA): `kl_gpu_time.m` `gap_tick/gap_print` (KL_GPU_GAP, on): cada 15 s, 8 frames: líneas `[gap]` por cb
  (commit/start/end) y `[gap] f=… GPU idle = CPU + GPU-WAIT; compositor alone`, `[gap] SUMMARY`. Diagnóstico del hueco: por command buffer, hora de commit en CPU, GPUStartTime/EndTime y en qué
  fence/encoder espera el primer encoder que arranca tarde; ver si es CPU del juego (submit tarde), una fence (join /
  cola anterior) o el compositor ocupando la GPU.

## Logs_Alyx_37 (B50, menú, 90 Hz) — causa del «baile» de fps
- `[gap]`: el hueco de 5 ms ya no existe; GPU parada ~1–1,5 ms/frame (≈1 CPU tarde + 0,4 espera). Frames malos
  (~30 %): el cb principal (cb1, 17–20 ms de GPU) se entrega ~3 ms tarde → 2–3 ms de GPU parada → frame > 22,2 ms.
- GPU total por frame = juego ~19,7 + compositor ~3,2 ms ≈ 23 > 22,2 (45 fps a 90 Hz) → `[cp] refreshes per picture`
  2:~100 3:~140 de 250: la mayoría de imágenes se ven 3 refrescos (~30 fps) → baile 30/45 aunque el juego dé 45.
- Compositor: `kl_wide_f` (vista ancha 250x202 rgba16F) ~1 ms por pase x ~1,5/frame; composición 1856x1760x2 1,8 ms;
  `kl_widerecon_f` 750x606 0,22 ms.
- B51: running start 6→9 ms (y un lead ≥ periodo se limita al 90 % en vez de desactivarse; kl_app.c); `KL_EYE_TRIM=1`
  por defecto; `kl_wide_f` máx. 2x2 taps. Validar: `[gap] SUMMARY` idle CPU ≈ 0 y `refreshes per composited picture`
  con mayoría en `2:`.

## Logs_Alyx_38 (B51, menú + nivel)
- Menú: `refreshes per picture` 2:248–250 → baile del menú RESUELTO; `[gap]` idle CPU 0–0,3 ms.
- Nivel: juego 25–30 ms + compositor 5–8 ms; `thermal fair` a los ~2,5 min (14:41:04) justo cuando el juego pasa de
  21 a 28 ms y el compositor de 3,8 a 7 ms (coincidencia: «fair» NO baja la GPU, solo «serious»; ninguna sesión ha llegado a serious). El empeoramiento es
  el nivel más pesado (juego 21→28–30 ms); el compositor por frame sube porque cada imagen se mantiene más refrescos.
  Memoria 6,8 GB de 8,1 (vigilar streaming de texturas).
- El regulador no podía bajar a 30 a 90 Hz (`pace_plan`: fallback solo si ≥ 32 fps) → alternancia 2/3 refrescos.
- Sombras que «salen tarde» en el nivel: sospecha de las esperas a productores (0038 bit0).
- B52: fallback a 90 Hz = 30 fps (umbral 29,5; klvr_platform_klepton.c `pace_plan`); `VPVK_RUNTIME_OPTS=0`.
- Pendiente: con la GPU al 100 %; sin bajar carga (resolución/MSAA) solo queda elegir entre 45
  con baile o 30 estable. Validar sombras con bit0 off.

## Logs_Alyx_39 (B52, 80 %, post al área física ON, medir GPU/capturas OFF)
- Fallback a 30 fps a 90 Hz funciona (pace plan: base 45, fallback 30). Pero el regulador alterna 45↔30 seis veces
  en ~3 min (vuelve a 45 tras 5 s por debajo del 85 %): hacerlo más pegajoso a 90 Hz (p. ej. volver tras 15 s < 80 %).
- Térmico: nominal 16:47:12 → fair 16:52:37 (5 min 25 s) → **serious 16:54:57 (7 min 45 s)**; fin del log 16:55:13.
- Juego en nivel 25–33 ms (picos al tener un objeto delante de la cara: relleno de píxeles), menú/zonas ligeras 13–17.
- Post al área física: sin quejas visuales (sin medida de ahorro: medir GPU OFF).

## Logs_Alyx_40 (B52)
- Explosión: juego 29→41 ms durante ~15 s (partículas que llenan la vista; sin compilaciones de pipelines ni
  anomalías) → 23–27 fps. Sombras siguen 1–2 s tarde con bit0 OFF → sospecha: «oclusión medida» (VPVK_OCCLUSION,
  B39): resultados de consultas que llegan tarde → casters culled. Usuario prueba con la opción OFF (sin build).
- Regulador: bajar a 30 en ~0,3 s (primeros frames tarde) y volver a 45 solo tras ~15 s holgados. La resolución
  dinámica (auto-fidelity de Alyx) se quitó porque rompía el foveado (mapa fijo al lanzar): rehacerla = trabajo grande.

## Logs_Alyx_41 (B52, 70 %) — «a 70 % va peor que a 80 %»
- Sombras tarde: el usuario probó oclusión medida OFF → no es eso, es del propio juego. Oclusión queda ON.
- A 70 % la GPU cabe en la base (juego 12–15 ms de 22,2) → el regulador (solo mira tiempo de GPU) sube a 45, pero el
  compositor recibe 16–20 imágenes nuevas/0,5 s en vez de 22 (~36 fps, alternando 2 y 3 refrescos): `[passes]` W4/W5
  busy 12 ms con span 34 ms (GPU ociosa 21 ms dentro del frame: CPU/orden, no trabajo de GPU). A 80 % la GPU no cabía
  → se quedaba en 30 estable. Causa: el regulador no veía frames entregados tarde por causas ajenas a la GPU.

## B53 (pendiente de compilar/validar)
- `klvr_platform_klepton.c` `pace_governor`:
  - bajada rápida: ≥0,3 s y ≥10 frames con >40 % tarde por GPU **o** >25 % de imágenes entregadas tarde;
  - cadencia real: dt entre llamadas a `klvr_plat_wait_frame` >1,25 periodos base (y <3 periodos; >250 ms ignorado)
    = refresco perdido; >15 % en la ventana de 1 s → fallback;
  - vuelta a la base: `need_s` ventanas seguidas <80 % del presupuesto con ≤3 % tarde (mín. 1 frame); `need_s` =
    15 s, se dobla (máx. 120) si la base falla en <20 s, vuelve a 15 tras 60 s aguantando;
  - log: «N of M pictures missed their refresh; next return to the base after X s».
- `kl_gpu_time.m`: mapa de foveado también con MSAA x2 (≥4, o ≥2 si `renderTargetArrayLength == 2`).
- App (`AVPSettings.swift`, `AVPSettingsView.swift`, `AVPLaunch.swift`):
  - esquema `avp.schema` = 53: borra una vez los `avp.*` salvo `keptKeys` (bookmark, signatureVariant, prepared) y
    los personales (idioma, movimiento, subtítulos, altura, dedos, nube, FPS);
  - presets de imagen M2 / M5 / Personalizado (`preset`, `applyPreset`, `graphicsChanged` pasa a Personalizado al
    tocar a mano). M2 = valores de Logs_Alyx_40 con resolución 70 %: tex 2048, foveado ON 70°/10 %, VPKTAA 100 %/1.0,
    aniso 16, MSAA 4, SSAO ON. **M5 = igual que M2 hasta medirlo en un M5**;
  - MSAA No/x2/x4 (`msaa`, `avp.msaa`, `gameMSAA`); sin MSAA no hay foveado (`foveationUsable` gobierna también recon,
    `applyLive` y `foveation_mode`);
  - motor VPKEngine / MoltenVK (prueba) (`avp.engine`): con MoltenVK `selectDriver` no carga VPVulkan; env
    `KL_VK_MERGE(_VIS)=1`, `KL_VK_CLEAR_NEW=0`, `KL_LOG_TAG=moltenvk`, sin caché de pipelines de VPKEngine. Cambiar de
    motor = cerrar la app del todo. Con MoltenVK el regulador usa tiempo «union» (~2×) → probablemente fijo en 30;
  - Diagnóstico solo: Capturas (OFF), Medir GPU por pase (OFF), Oclusión medida (ON), motor. Quitados del menú con
    valor fijo: orden por recursos ON, amplificación ON, ojos sin copia OFF, arranque anticipado 9 ms, test A/B OFF,
    Hz al juego medido, post al área física **ON**.
- Validar con log: líneas del regulador (sin bailes 45↔30), MSAA x2 con foveado correcto, MoltenVK arranca.

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
