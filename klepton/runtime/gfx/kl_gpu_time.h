// GPU time per guest frame, read from Metal (kl_gpu_time.m).
#ifndef KL_GPU_TIME_H
#define KL_GPU_TIME_H
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

#ifdef __cplusplus
}
#endif
#endif

// KL_CP_DEPTH: an R32Float texture view over a linear MTLBuffer (retained, release with kl_mtl_release).
void *kl_mtl_buffer_texture_r32f(void *mtl_buffer, unsigned w, unsigned h, unsigned pitch_bytes);
void kl_mtl_release(void *obj);
