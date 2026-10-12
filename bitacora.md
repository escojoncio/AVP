# Bitácora — AVP

## Estado (2026-10-13)
- Plan rehecho en `PLAN.md` tras analizar Glovebox (MIT): todo en el visor (Steam oficial con
  comprobación de propiedad, descarga ARM64, conversión `klepton_ld` en proceso, firma `vp_codesign`,
  receta de pipelines), gráficos VPEngine, VPKTAA nativo con vectores de movimiento generados por
  VPEngine (Alyx no tiene SpaceWarp), la app impone sus ajustes en cada arranque.
- Fase 0 (firma on-device) resuelta: ya funciona en VisionQuestPro.
- Sin código aún.

## Siguiente
- Fase 1: scaffold desde VisionQuestPro (copia propia de Klepton, CI solo `[build]`).
- Antes de copiar el VPKTAA, revisar el estado más reciente de VisionQuestPro (se está terminando allí).
- Huecos de VPEngine para Source 2: ver PLAN §5.1.
