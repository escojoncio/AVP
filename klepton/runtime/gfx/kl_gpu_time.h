// GPU time per guest frame, read from Metal (kl_gpu_time.m).
#ifndef KL_GPU_TIME_H
#define KL_GPU_TIME_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// Time every command buffer committed on this MTLCommandQueue: the guest's (the
// Vulkan layer hands over each queue it submits on) or our compositor's.
void kl_gpu_time_watch(void *mtl_queue);
void kl_gpu_time_watch_compositor(void *mtl_queue);
// The game has submitted both eyes: buffers committed from now on are the next frame's.
void kl_gpu_time_frame_end(void);
// The guest's GPU ms of a finished frame (and the compositor's in *compositor).
float kl_gpu_time_frame_ms(unsigned frames_ago, float *compositor, unsigned *frame);
// Foveated scene passes (KL_VRR=1): the compositor's unwarp grid asks for a per-eye screen->physical callback
// context for the published eye rate map (NULL when KL_VRR is off); kl_vrr_s2p is the callback. The eye
// image is stored top-down (Vulkan), which the callback accounts for.
void *kl_vrr_grid_ctx(int eye, void *map, float tex_h);
void *kl_vrr_map_for(int w, int h);
// Live foveation settings: rebuild the maps from the current KL_VRR_* environment.
void kl_vrr_reload(void);
// Live foveation shape without touching the environment: soft (1) or centre (0) map, inner/outer/edge
// (< 0: that preset's default). Rebuilds the maps.
void kl_vrr_set(int mode, float inner, float outer, float edge);   // mode: 0 centre, 1 soft, 2 wide (KL_VRR_MAP)
void kl_vrr_s2p(void *ctx, float sx, float sy, float *px, float *py);
// The frame the guest is recording now (counts from 1; 0 before GPU timing is on).
unsigned kl_gpu_time_frame(void);
// The OpenVR shim: the game faded the grid in (to_grid = 1: a level load starts) or out (0: a scene is shown).
// Per-pass profiling windows "g<s>" (KL_GPU_PASSES) are timed from each scene start.
void kl_gpu_time_scene(int to_grid);
// The physical extent of the foveation map the eye image of this size (the submit's crop, w x h) was rendered through:
// the largest over the map's layers. 0 when KL_VRR is off or no map was built for that size.
int kl_vrr_phys_extent(unsigned w, unsigned h, unsigned *pw, unsigned *ph);

// AVP's automatic A/B performance test (KL_ABTEST=1, driven from kl_gpu_time_frame_end): VPKEngine's runtime
// optimisations (patch 0038) and the eye-copy trim, each measured against the others, then a one-shader-out probe.
// kl_abtest_hud: 0 when the test is off (no KL_ABTEST=1, none started on demand) or ended (done/failed) 60+ s ago; else copies the HUD line for it (Spanish) into buf and returns 1. buf NULL
// or n <= 0 only asks whether there is a line. Any thread.
int kl_abtest_hud(char *buf, int n);
// Whether the eye copy may be trimmed to the rate map's physical area right now: bit 2 of the mask in force (KL_EYE_TRIM=1
// at start, then kl_engine_set_opts, the test's while it runs and its verdict after). Always 0 when a compositor path that reads the whole eye is on.
int kl_abtest_eye_trim(void);
void kl_abtest_note_trim(void);   // the OpenVR shim trimmed one eye copy (the test's counter)
// 1 when a compositor path that reads the whole eye image is on (VPKTAA / eye FX): the trim cannot act. Known once the first eye
// copy asked (0 before). Any thread.
int kl_abtest_eye_trim_blocked(void);

// AVP's "Laboratorio del motor" (kl_gpu_time.m). The mask has one bit per switch: 0 VPKEngine producer-only fence waits, 2 eye-copy
// trim (host), 3 gather copies, 4 fuse clears, 5 state elision (bits 3-5: VPKEngine 0043-0046). Bit 1 (clear skip) is
// never accepted or applied, and every other bit is ignored.
// kl_engine_set_opts: any thread; the engine takes it at the next guest frame (the eye trim at the next eye copy), no
// restart. While the A/B test measures, the mask is only stored (the test drives the engine and puts the winner back).
// kl_engine_get_opts: the mask in force (the last set, or the winner of the last test; at start VPVK_RUNTIME_OPTS & 0x39
// | 4 with KL_EYE_TRIM=1). kl_engine_available: 1 when the loaded VPKEngine has the runtime switches (patch 0038).
void kl_engine_set_opts(uint32_t mask);
uint32_t kl_engine_get_opts(void);
int kl_engine_available(void);
// The A/B test on demand, at any time outside a load (KL_ABTEST=1 is only the automatic start at boot). Only the switches are
// measured (no census, no knockout, ~50 s). The request is taken by the next guest frame, so with the game paused the test
// starts when it resumes (4 s later, 3 s after a load; a new pause while it waits restarts the 4 s).
// Returns 1 requested, 0 a test is already running or waiting, -1 the engine has no switches. Any thread.
int kl_abtest_start(void);
// Aborts a requested or running test at any phase (taken by the next guest frame; the phase reads IDLE at once) and puts the
// mask in force before it back. Any thread.
void kl_abtest_cancel(void);
#define KL_ABTEST_IDLE 0
#define KL_ABTEST_WAIT 1      // requested: waiting for frames / the end of a load
#define KL_ABTEST_CENSUS 2    // 1/3
#define KL_ABTEST_OPTS 3      // the switches (2/3 of the boot test; all of an on-demand one)
#define KL_ABTEST_KNOCK 4     // 3/3: the shaders
#define KL_ABTEST_DONE 5
#define KL_ABTEST_FAILED 6
#define KL_ABTEST_PAUSED 7    // a load (or the game paused) discarded a step; it resumes by itself
int kl_abtest_phase(void);
int kl_abtest_seconds_left(void);      // estimate for the phases above (0 when none)
unsigned kl_abtest_result_serial(void);   // +1 each time a test ends DONE (0 = none yet)
uint32_t kl_abtest_result_mask(void);     // the winner: mask at the start + SAVES - WORSE/BREAKS (valid once the serial moved)
#define KL_ABV_NONE 0         // not measured
#define KL_ABV_SAVES 1
#define KL_ABV_NO_EFFECT 2
#define KL_ABV_WORSE 3
#define KL_ABV_BREAKS 4
#define KL_ABV_INACTIVE 5     // the switch never acted in the windows
// Verdict of one bit (0, 2, 3, 4, 5) of the last test, and its gain in ms: *gpu_ms = exclusive GPU frame time saved,
// *cpu_ms = encoding CPU ms per submit saved (< 0 = worse; 0 when not measured). Either pointer may be NULL.
int kl_abtest_result(int bit, double *gpu_ms, double *cpu_ms);

#ifdef __cplusplus
}
#endif
#endif

// KL_CP_DEPTH: an R32Float texture view over a linear MTLBuffer (retained, release with kl_mtl_release).
void *kl_mtl_buffer_texture_r32f(void *mtl_buffer, unsigned w, unsigned h, unsigned pitch_bytes);
void kl_mtl_release(void *obj);
void *kl_mtl_retain(void *obj);   // +1 on a Metal object handed over unretained (returns it)
