// AVP: graphics settings from the app (Settings screen) to VPEngine. Mirrors VPEngine's
// gpu/vulkan/include/vpvk/config.h (same layout); forwarded to libVPVulkan with dlsym when that
// driver is loaded (a no-op on the MoltenVK diagnostic path). Diagnostics: log "avp.gfx".
#pragma once
#include <stdint.h>

typedef struct avp_gfx_config {
    int32_t foveation_mode;   // 0 off, 1 M2, 2 M5, 3 custom (vpvk_foveation_mode)
    float sharp_zone;         // custom: 0.05..1
    float periphery;          // custom: 0.1..1 (rate at the edge)
    float transition;         // custom: 0.02..0.5 (width of the fall-off); sent as vpvk "height" slot = 0
    int32_t vpktaa_enabled;
    float vpktaa_percent;     // 0..100
    float vpktaa_sharpness;   // 0..1
    float render_scale;       // 0.5..1.5 (VPEngine-side scale; the eye size itself is the OpenVR shim's)
    int32_t anisotropy;       // 0 = game's own; 16 = force 16x on mipmapped linear samplers
    int32_t force_single_sample; // 1 = render the game's MSAA targets at 1x (VPKTAA does the AA)
    int32_t metalfx;          // 0 off, 1 spatial upscaling
    int32_t texture_cap;      // max texture edge VPEngine lets through (0 = no cap)
} avp_gfx_config;

// Stores the config and pushes it to VPVulkan if loaded (returns 1 if forwarded).
int avp_gfx_config_apply(const avp_gfx_config *c);
// Re-push the stored config (call after the driver is dlopen'ed).
int avp_gfx_config_forward(void);
