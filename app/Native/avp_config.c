// AVP: see avp_config.h. Every setter is looked up with dlsym: a VPEngine build without one of them
// still gets the rest, and the log says which were missing.
#include "avp_config.h"

#include <dlfcn.h>
#include <stdio.h>

// Same layout as vpvk/config.h (VPEngine); kept local so the app builds without the header.
typedef struct { int32_t mode; float sharp_zone, periphery, height; } vpvk_foveation;
typedef struct { int enabled; float percent, sharpness; } vpvk_vpktaa;

static avp_gfx_config g_cfg;
static int g_have;

#define SYM(type, name) ((type)dlsym(RTLD_DEFAULT, name))

int avp_gfx_config_forward(void) {
    if (!g_have) return 0;
    void (*set_fov)(const vpvk_foveation *) = SYM(void (*)(const vpvk_foveation *), "vpvk_config_set_foveation");
    void (*set_taa)(const vpvk_vpktaa *) = SYM(void (*)(const vpvk_vpktaa *), "vpvk_config_set_vpktaa");
    void (*set_scale)(float) = SYM(void (*)(float), "vpvk_config_set_render_scale");
    void (*set_aniso)(int) = SYM(void (*)(int), "vpvk_config_set_anisotropy");
    void (*set_1x)(int) = SYM(void (*)(int), "vpvk_config_set_force_single_sample");
    void (*set_asw)(int) = SYM(void (*)(int), "vpvk_config_set_asw_disabled");
    void (*set_q3)(int) = SYM(void (*)(int), "vpvk_config_set_quest3_profile");
    void (*set_mfx)(int) = SYM(void (*)(int), "vpvk_config_set_metalfx");
    void (*set_tcap)(int) = SYM(void (*)(int), "vpvk_config_set_texture_cap");
    if (!set_fov || !set_taa) {
        fprintf(stderr, "avp.gfx config stored; VPVulkan not loaded (MoltenVK path): foveation/VPKTAA not applied\n");
        return 0;
    }
    vpvk_foveation f = { g_cfg.foveation_mode, g_cfg.sharp_zone, g_cfg.periphery, 0.0f };
    vpvk_vpktaa t = { g_cfg.vpktaa_enabled, g_cfg.vpktaa_percent, g_cfg.vpktaa_sharpness };
    set_fov(&f);
    set_taa(&t);
    if (set_scale) set_scale(g_cfg.render_scale);
    if (set_aniso) set_aniso(g_cfg.anisotropy);
    if (set_1x) set_1x(g_cfg.force_single_sample);
    if (set_asw) set_asw(1);   // OpenVR has no SpaceWarp: every frame is real
    if (set_q3) set_q3(0);     // no Quest identity for a PC VR game
    if (set_mfx) set_mfx(g_cfg.metalfx);
    if (set_tcap) set_tcap(g_cfg.texture_cap);
    fprintf(stderr, "avp.gfx config forwarded to VPVulkan (metalfx setter %s, texture cap setter %s)\n",
            set_mfx ? "yes" : "missing", set_tcap ? "yes" : "missing");
    return 1;
}

int avp_gfx_config_apply(const avp_gfx_config *c) {
    if (!c) return 0;
    g_cfg = *c;
    g_have = 1;
    static const char *const names[] = { "off", "m2", "m5", "custom" };
    int m = (c->foveation_mode >= 0 && c->foveation_mode <= 3) ? c->foveation_mode : 0;
    fprintf(stderr, "avp.gfx settings foveation=%s sharp=%.2f periphery=%.2f transition=%.2f vpktaa=%d %.0f%% "
            "sharp=%.2f scale=%.2f aniso=%d 1x=%d metalfx=%d texcap=%d\n",
            names[m], c->sharp_zone, c->periphery, c->transition, c->vpktaa_enabled, c->vpktaa_percent,
            c->vpktaa_sharpness, c->render_scale, c->anisotropy, c->force_single_sample, c->metalfx, c->texture_cap);
    return avp_gfx_config_forward();
}
