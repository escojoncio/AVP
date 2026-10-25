# Bitácora — AVP

Half-Life: Alyx (ARM64 Linux de Steam) nativo en Apple Vision Pro (M2). Steam oficial → descarga → ELF→Mach-O
(`klepton_ld`) → firma on-device (`vp_codesign` + .p12) → prewarm de pipelines → juego. Gráficos: **solo VPKEngine**
(`escojoncio/VPKEngine` @ `vpkengine.ref` + `vpkengine-patches/` 0011–0041; parche nuevo = `00NN-*.patch` con
`git format-patch` sobre ref+parches; CI `scripts/apply-vpkengine-patches.sh`). Plan: `PLAN.md`.
IPA: https://github.com/escojoncio/AVP/releases/download/visionos/AVP.ipa (última: **B59**, compilada OK).
Builds: solo con `[build]` en el mensaje o dispatch manual; docs con `[skip ci]`.

## Últimos hechos
- Bitácora compactada: detalle de mediciones en `notas/rendimiento.md`, mecanismos B46–B59 en `notas/builds.md`.
- Logs_Alyx_48 (no es A/B limpio: ON = modo high/90 Hz → 45 fijos; OFF = auto/100 Hz → 33): foveado SÍ baja GPU juego
  3–7 ms (mapa físico 1120x1088 = 37 %) y compositor 5,8–7,8 → 3,4–4,1. 33 fps = umbral del regulador: vuelve a 50 solo
  si `game + 0,667·comp < 17 ms` (`klvr_platform_klepton.c:281,324-326`); OFF 18,6–28 ms, ON calma ~14–15,8.
  Bug: sin foveado el RCAS se aplica al ojo entero (`KleptonCompositor.swift:1515`, rect ilimitado) → +2,4 ms comp.
- B59: RCAS «Nitidez del centro» solo en la zona de tasa completa (compositor). Sin validar.
- B58: `0041` logs `vk.fail`, `console-previous.log`, altura real por detección de suelo. Sin validar.
- B57: alivio de memoria + `[mem] breakdown`; Logs_47: 14 min sin cierre, sin fuga.
- B55: selector «Fotogramas» (Auto / base / fallback). B54: fallback 30/33 aplicado de verdad.

## Estado actual
- 100 % funcional (visor): Steam (login+Guard, Cloud), firma, 90 libs, prewarm ~4150 pipelines; VPKEngine 0 cuelgues
  desde B17, MSAA 4x, amplificación de vértices, occlusion culling medido, `VP_CB_ORDER=2`; foveado VRR (periferia 10 %,
  VPKTAA en periferia; post NO foveado); compositor skip-same; regulador 50/33 (100 Hz) o 45/30 (90 Hz) con tiempo de
  GPU exclusivo; reloj del juego `klvr_game_hz`; OpenVR cabeza + 2 Sense, dedos, altura, subtítulos, idioma, pausa.
- Pendiente de validar: B58 (altura real, `vk.fail`), B59 (RCAS: rect = zona nítida, sin costura, coste GPU).
- Problema abierto: el foveado no mueve los fps (Logs_48); coste fijo ~14 ms + compositor 3–6 ms; térmico.

## Decisiones vigentes
- Sin MetalFX; MoltenVK solo fallback automático; nada que cambie lo visible (LOD, cull, `vr_expand_cull_frustum`,
  SSAO off, sombras, MSAA): el rendimiento sale de resolución y optimización pura.
- `VPVK_RUNTIME_OPTS=0`; clear skip (0038 bit1) nunca.
- Comparar rendimiento con visor frío, misma zona, mismo tiempo, mismo «Medir GPU por pase».
- Diagnóstico solo al log de la app (el usuario no tiene Mac ni `.ips`); nada de volcados pesados en mitad del juego.
- `Window(id:)` mata el launcher → `WindowGroup`. `KL_VRR_PHYS=1` rompe la imagen. Ojos sin copia parpadea.
- Nunca abandonar un frame tras `queryNextFrame`. Todo frame consultado a CompositorServices se presenta.

## Ficheros en juego
- `klepton/.../klvr_platform_klepton.c` (`pace_plan`, `pace_governor`), `kl_app.c` (pacer), `kl_gpu_time.m`.
- `klepton/visionos/Sources/KleptonCompositor.swift`; `app/Sources/AVPSettings*.swift`.

## Índice de notas
- `notas/rendimiento.md`: reparto del frame, hallazgos Logs_34–47, conclusión e ideas pendientes de rendimiento.
- `notas/builds.md`: qué hace cada mecanismo de B46–B59 (VPKEngine 0038–0041, regulador, compositor, app).
