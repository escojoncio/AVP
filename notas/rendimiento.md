# Rendimiento — mediciones e historial (Logs_Alyx_34–47)

## Reparto del frame (Logs_34 = 80 %, 2_12 = 50 %, menú con UI)
`[passes]` W4: span 25,3 → 18,5 ms, ocupado 21,6 → 13,4. Solo ~4 ms escalan con píxeles (modelo 14,4 fijo + 4,2).
| Coste | ms | Dónde |
|---|---|---|
| UI Panorama en serie (~12 blits 1058² + 37 pases ui-2d) | ~3,5 | VPKEngine |
| vtx escena + parte fija del frag | ~3,2 | legítimo |
| compute `vk.comp31` (niebla/binning) | 1,37 | legítimo |
| cadena de bloom (encoders diminutos + espera en E/8) | ~0,9 | `waitFrontier` |
| borrado atlas D32F 4096² sin timestamps | 2–3,6 (oculto) | VPKEngine |
| copias de ojos + compositor | ~1,5 | app |

## Hallazgos por log
- 35/36: esperas a productores (0038 bit0) ≈ −0,2 ms excl (−1,5 unión en 35, ruido); clear skip (bit1) empeora 2,5 ms
  de unión → retirado; recorte de ojos (bit2) sin efecto. Span UNIÓN bimodal (~20,3/22,4) → knockouts por unión
  poco fiables; usar mediana EXCLUSIVA. Ningún shader > 0,8 ms excl. vk.comp15 (niebla volumétrica) el mayor.
- Panel 90 Hz de día / 100 Hz de noche (lo elige visionOS) → 45 o 50 fps con el mismo trabajo.
- 2_14 + corpus .foz (1675 shaders, harness VPVulkan null + fossilize-replay, `VPVK_DUMP_MSL`): 0 RelaxedPrecision,
  fast math activo, guardas de bucle no impiden desenrollar, 37 shaders con tablas constantes privadas → `0040`
  `planConstTables` (`VPMSL_CONST_TABLES=0` lo apaga).
- 37 (B50 `[gap]`): hueco de 5 ms ya no existe; GPU juego ~19,7 + compositor ~3,2 > 22,2 → baile 30/45.
- 38 (B51): baile del menú resuelto (refreshes 2:248–250). Nivel: juego 25–30 ms + compositor 5–8.
- 39: térmico nominal→fair 5 min→serious 7 min 45 s. Juego en nivel 25–33 ms (objeto delante de la cara).
- 40: explosión 29→41 ms ~15 s. Sombras tarde = del propio juego (no oclusión, no bit0).
- 41: a 70 % la GPU cabe pero el compositor recibe ~36 imágenes/s (GPU ociosa dentro del frame: CPU/orden).
- 42/43: térmico critical duplica GPU (13–18 → 28–32 ms). Comparar siempre con visor frío, misma zona, mismo tiempo.
- 45 (B54): 33,3 fps fijos a 100 Hz, GPU juego 12–17 ms + comp ~3, nunca volvía a 50 (regla demasiado estricta → B55).
- 46/47: memoria footprint 6,0–6,65 GB (Metal 3,6–3,8 + resto 2,7–2,8), sin fuga, presión «critical» casi continua;
  cierre de 46 = SIGABRT en `librendersystemvulkan.so` (no jetsam).

## Conclusión (no repetir)
La resolución NO es palanca principal: ~14 ms fijos que no escalan con píxeles. Objetivo: coste fijo (UI Panorama,
vértices, compute, copias de ojos, compositor 3–6 ms por imagen nueva: composición + vista ancha `kl_wide_f`).
Ideas pendientes: blits de Panorama en un encoder, `vkCmdClearAttachments` como quad, join solo a `needJoin`, vista
ancha desde la recon/mip, `packed_float4` en VS, tiempo de presentación predicho a Klepton.
