// GPU time per guest frame, read from Metal itself.
//
// A PC VR game sizes its rendering from the GPU time the compositor reports
// back (SteamVR's Compositor_FrameTiming::m_flTotalRenderGpuMs: Source 2's
// auto-fidelity keeps a ring of it and drops or raises vr_fidelity_level
// against the frame budget). MoltenVK has no timestamp queries worth the name
// on Apple GPUs, but every MTLCommandBuffer knows when the GPU started and
// finished it. So every command buffer committed on a queue the guest submits
// to gets a completed handler, and a frame's GPU time is the UNION of its
// buffers' [GPUStartTime, GPUEndTime] intervals: overlap between neighbouring
// buffers is counted once and the idle gaps between them not at all.
//
// A buffer belongs to the frame that was open when it was committed; the frame
// closes at kl_gpu_time_frame_end (the OpenVR shim calls it on the game's thread
// when both eyes are submitted). A frame is final once every buffer committed
// in it has completed.
//
// The commit hook is a method swizzle of the command buffer class's -commit,
// installed once from the first watched queue's own buffer class; buffers of
// any other queue (the compositor's, ANGLE's) pass straight through.
// KL_GPU_TIME=0 leaves -commit alone.
#include <os/lock.h>
#include <stdio.h>
#include <stdatomic.h>
#include <execinfo.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mach/mach_time.h>
#include <dlfcn.h>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

#include "kl_gpu_time.h"
#include "kl_glfb.h"
#include <math.h>

enum { kRing = 16, kMaxQueues = 96 };   // VPKEngine replaces its queue after a GPU error (up to 64): each is watched
// Role 0 is the guest's queue(s), role 1 our compositor's (on the device it
// draws every panel refresh, so twice per game frame at 120 Hz; SteamVR's
// "total render" time includes the compositor's GPU work too).
typedef struct {
    uint32_t frame;          // which frame this slot holds
    uint32_t committed, completed;
    double busy[2];          // seconds of union GPU time so far, per role
    double last_end[2];      // end of the latest interval already counted, per role
    // Build 36: EXCLUSIVE GPU time (seconds) of the frame's buffers, per role, from the encoders' stage-boundary
    // timestamps (VPVulkan's for the guest, our own for the compositor): the union above holds every wait on an
    // earlier buffer and the time the other queue had the GPU, which in play read twice the work (Logs_Alyx 2_10:
    // union 34 ms against 17 ms busy) and kept the pace governor at the fallback. A frame with every buffer
    // accounted this way reports the exclusive figure; one with a miss keeps the union (excl_miss > 0).
    double excl[2];
    uint32_t excl_n[2], excl_miss[2];
} slot;

static os_unfair_lock g_lk = OS_UNFAIR_LOCK_INIT;
static void *g_queues[kMaxQueues];
static int g_roles[kMaxQueues];
static int g_nqueues;
static uint32_t g_frame = 1;     // the open frame (0 means "none" in a slot)
static slot g_slots[kRing];
static IMP g_commit;             // the original -commit

static slot *slot_of(uint32_t f) {
    slot *s = &g_slots[f % kRing];
    if (s->frame != f) { memset(s, 0, sizeof *s); s->frame = f; }
    return s;
}

// ---- Exclusive GPU time per command buffer (build 36) --------------------------------------------------------------
// The guest's: VPVulkan samples stage-boundary timestamps on every encoder it makes and, in its own completed handler
// (added before ours: it adds it at submit, we add ours inside -commit), places them on one timeline and keeps each
// buffer's exclusive ms in a ring (vpgpu_metal2_cb_busy_ms, consumed by the lookup). Resolved by name: a build
// without it (MoltenVK) keeps the union. KL_GPU_TIME_EXCL=0 keeps the union too (A/B).
static int (*g_vp_busy)(const void *, double *);
static void (*g_vp_busy_stats)(uint64_t *, uint64_t *);
static int g_excl_on = -1;
static unsigned g_excl_hits[2], g_excl_misses[2];   // buffers accounted / not (per role), for the 5 s report
static void excl_init(void) {
    if (g_excl_on >= 0) return;
    const char *e = getenv("KL_GPU_TIME_EXCL");
    g_excl_on = !(e && *e == '0');
    fprintf(stderr, "[gputime] exclusive GPU time per frame: %s\n",
            g_excl_on ? "on (the compositor's from our sample buffers; the guest's once its driver's queue is seen)"
                      : "off (KL_GPU_TIME_EXCL=0): span unions");
}
// The guest's driver is loaded after the compositor's queue is first watched, so its export is looked up at the first
// commit on the guest's queue, not at init.
static void excl_vp_resolve(void) {
    static int tried;
    if (tried || g_excl_on <= 0) return;
    tried = 1;
    // The driver was dlopen'ed RTLD_LOCAL (kl_vulkan.c): RTLD_NOLOAD on its path finds the loaded image.
    const char *path = getenv("KL_MVK_DYLIB");
    void *h = path && *path ? dlopen(path, RTLD_NOW | RTLD_NOLOAD) : NULL;
    g_vp_busy = (int (*)(const void *, double *))dlsym(h ? h : RTLD_DEFAULT, "vpgpu_metal2_cb_busy_ms");
    g_vp_busy_stats = (void (*)(uint64_t *, uint64_t *))dlsym(h ? h : RTLD_DEFAULT, "vpgpu_metal2_cb_busy_stats");
    fprintf(stderr, "[gputime] the guest's exclusive GPU time: %s\n",
            g_vp_busy ? "from VPVulkan's encoder timestamps (vpgpu_metal2_cb_busy_ms)" : "unavailable (no vpgpu_metal2_cb_busy_ms: the union stands)");
}
static double cx_resolve(void *cb, double span_ms);   // the compositor's buffers (below): exclusive ms, or -1

static void on_complete(uint32_t f, int role, double start, double end, void *cb) {
    double excl = -1;
    if (g_excl_on > 0 && cb) {
        if (role == 0 && g_vp_busy) {
            double ms = 0;
            int r = g_vp_busy(cb, &ms);
            if (r == 1) excl = ms / 1e3;
            else if (r == 0) excl = 0;   // completed with nothing sampled: an empty buffer
        } else if (role == 1) {
            double ms = cx_resolve(cb, (end - start) * 1e3);
            if (ms >= 0) excl = ms / 1e3;
        }
    }
    os_unfair_lock_lock(&g_lk);
    slot *s = &g_slots[f % kRing];
    if (s->frame == f) {
        if (end > start && start > 0) {
            double from = start > s->last_end[role] ? start : s->last_end[role];
            if (end > from) s->busy[role] += end - from;
            if (end > s->last_end[role]) s->last_end[role] = end;
        }
        if (excl >= 0) { s->excl[role] += excl; s->excl_n[role]++; g_excl_hits[role]++; }
        else { s->excl_miss[role]++; if (g_excl_on > 0 && (role == 1 || g_vp_busy)) g_excl_misses[role]++; }
        s->completed++;
    }
    os_unfair_lock_unlock(&g_lk);
}

// The queue's role, or -1 when it is not watched.
static int watched(void *q) {
    for (int i = 0; i < g_nqueues; i++) if (g_queues[i] == q) return g_roles[i];
    return -1;
}

// ---- Snapshot of the guest's output image (KL_GPU_SNAP=<frame>:<file.ppm>) -------
// Layer 0 (the left eye) of the first 8-bit RGBA render target at least 1024 wide that the guest
// draws in that frame (the tonemapped eye image), copied out when its command buffer commits:
// the A/B check that a pass change (KL_VK_MERGE) leaves the picture alone.
static uint32_t g_snap_at, g_snap_n = 1, g_snap_every = 1, g_snap_taken;
static char g_snap_path[512];
static void *g_snap_tex, *g_snap_cb;
static int g_snap_done;
static void snap_note(id<MTLCommandBuffer> cb, MTLRenderPassDescriptor *d, uint32_t f) {
    if (!g_snap_at || g_snap_done || g_snap_tex || f != g_snap_at) return;
    id<MTLTexture> t = d.colorAttachments[0].texture;
    // Eye-sized only (asymmetric L0 is 1917 wide). KL_GPU_SNAP_MINW raises the floor: at 3360 wide the game's
    // half-resolution RGBA8 target (1680) passes 1500 and comes first in the frame.
    static int minw = -1;
    if (minw < 0) { const char *e = getenv("KL_GPU_SNAP_MINW"); minw = e && atoi(e) > 0 ? atoi(e) : 1500; }
    if (!t || t.pixelFormat != MTLPixelFormatRGBA8Unorm || (int)t.width < minw || t.height < 1200 || t.sampleCount != 1) return;
    g_snap_tex = (void *)CFBridgingRetain(t);
    g_snap_cb = (__bridge void *)cb;
}
static void snap_take(id<MTLCommandBuffer> cb) {
    if (!g_snap_tex || g_snap_done || (__bridge void *)cb != g_snap_cb) return;
    g_snap_done = 1;
    // A sequence (KL_GPU_SNAP_N frames, KL_GPU_SNAP_EVERY apart): <path>, then <path>.1, <path>.2, ...
    char path[560];
    if (g_snap_taken) snprintf(path, sizeof path, "%s.%u", g_snap_path, g_snap_taken);
    else snprintf(path, sizeof path, "%s", g_snap_path);
    uint32_t at = g_snap_at;
    id<MTLTexture> t = (__bridge id<MTLTexture>)g_snap_tex;
    NSUInteger x0 = 0, y0 = 0, w = t.width, h = t.height;
    // KL_GPU_SNAP_CROP=x,y,w,h: write only that region, so a sequence can take every frame (a flicker hunt)
    const char *cr = getenv("KL_GPU_SNAP_CROP");
    unsigned cx, cy, cw, ch;
    if (cr && sscanf(cr, "%u,%u,%u,%u", &cx, &cy, &cw, &ch) == 4 && cx + cw <= t.width && cy + ch <= t.height && cw && ch) {
        x0 = cx; y0 = cy; w = cw; h = ch;
    }
    NSUInteger bpr = w * 4;
    id<MTLBuffer> buf = [cb.device newBufferWithLength:bpr * h options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x0, y0, 0) sourceSize:MTLSizeMake(w, h, 1)
              toBuffer:buf destinationOffset:0 destinationBytesPerRow:bpr destinationBytesPerImage:bpr * h];
    [b endEncoding];
    NSString *where = [NSString stringWithUTF8String:path];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        (void)done;
        FILE *fp = fopen(where.UTF8String, "wb");
        if (!fp) return;
        fprintf(fp, "P6\n%lu %lu\n255\n", (unsigned long)w, (unsigned long)h);
        const uint8_t *px = buf.contents;
        for (NSUInteger i = 0; i < w * h; i++) fwrite(px + 4 * i, 1, 3, fp);
        fclose(fp);
        fprintf(stderr, "[snap] frame %u: %lux%lu written to %s\n", at, (unsigned long)w, (unsigned long)h, where.UTF8String);
    }];
    CFRelease(g_snap_tex);
    g_snap_tex = NULL;
    if (++g_snap_taken < g_snap_n) { g_snap_at += g_snap_every; g_snap_done = 0; }
}

static void mg_flush(void *cb);
static void kl_commit(id self, SEL sel) {
    mg_flush((__bridge void *)self);
    if (g_snap_tex) snap_take((id<MTLCommandBuffer>)self);
    id<MTLCommandBuffer> cb = (id<MTLCommandBuffer>)self;
    void *q = (__bridge void *)[cb commandQueue];
    os_unfair_lock_lock(&g_lk);
    int role = watched(q);
    uint32_t f = g_frame;
    if (role >= 0) slot_of(f)->committed++;
    os_unfair_lock_unlock(&g_lk);
    if (role >= 0) {
        excl_init();
        if (role == 0) excl_vp_resolve();
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            on_complete(f, role, done.GPUStartTime, done.GPUEndTime, (__bridge void *)done);
        }];
    }
    ((void (*)(id, SEL))g_commit)(self, sel);
}

// ---- Foveation spike (KL_VRR_SPIKE; a Mac measurement, off by default) -----
// Tier 2 foveation means shading the scene passes at a lower rate away from the
// gaze with Metal's variable rasterization rate (VRR). Before building it, this
// measures what it would buy, through the same command buffer class:
//   KL_VRR_SPIKE=census   once, in frame KL_VRR_SPIKE_AT (default 900), log every
//                         render pass the guest opens: attachments, sizes,
//                         formats, samples, layers, load/store actions.
//   KL_VRR_SPIKE=inject[:q]  attach a centred 5x5-zone rate map (rates q, (1+q)/2,
//                         1, (1+q)/2, q per axis; q default 0.25) to every guest
//                         pass whose first attachment has 4 samples and is at
//                         least 1024 wide: the scene passes. Nothing unwarps the
//                         result, so the picture is wrong; [gputime] shows what
//                         the passes would save.
static int g_vrr_mode = -1;          // 0 off, 1 census, 2 inject
static float g_vrr_q = 0.25f;
static uint32_t g_vrr_at = 900;
static double g_vrr_toggle;
static IMP g_rce;                    // the original -renderCommandEncoderWithDescriptor:
static unsigned g_vrr_injected;
static struct { NSUInteger w, h, layers; void *map; int zones; } g_vrr_maps[8];   // zones: per axis (fov maps)

static void vrr_census(MTLRenderPassDescriptor *d, uint32_t f) {
    static unsigned n;
    char line[1024];
    int u = snprintf(line, sizeof line, "[vrr] frame %u pass %u: rt %lux%lu layers %lu", f, n++,
                     (unsigned long)d.renderTargetWidth, (unsigned long)d.renderTargetHeight,
                     (unsigned long)d.renderTargetArrayLength);
    for (int i = 0; i < 8 && u < (int)sizeof line - 128; i++) {
        MTLRenderPassColorAttachmentDescriptor *a = d.colorAttachments[i];
        if (!a.texture) continue;
        u += snprintf(line + u, sizeof line - u, " | c%d %lux%lu fmt %lu s%lu t%lu a%lu L%lu S%lu%s", i,
                      (unsigned long)a.texture.width, (unsigned long)a.texture.height,
                      (unsigned long)a.texture.pixelFormat, (unsigned long)a.texture.sampleCount,
                      (unsigned long)a.texture.textureType, (unsigned long)a.texture.arrayLength,
                      (unsigned long)a.loadAction, (unsigned long)a.storeAction, a.resolveTexture ? " +resolve" : "");
    }
    id<MTLTexture> z = d.depthAttachment.texture;
    if (z && u < (int)sizeof line - 96)
        u += snprintf(line + u, sizeof line - u, " | z %lux%lu fmt %lu s%lu L%lu S%lu%s", (unsigned long)z.width,
                      (unsigned long)z.height, (unsigned long)z.pixelFormat, (unsigned long)z.sampleCount,
                      (unsigned long)d.depthAttachment.loadAction, (unsigned long)d.depthAttachment.storeAction,
                      d.depthAttachment.resolveTexture ? " +resolve" : "");
    fprintf(stderr, "%s\n", line);
}

static id<MTLRasterizationRateMap> vrr_map(id<MTLDevice> dev, NSUInteger w, NSUInteger h, NSUInteger layers) {
    for (int i = 0; i < 8; i++)
        if (g_vrr_maps[i].map && g_vrr_maps[i].w == w && g_vrr_maps[i].h == h && g_vrr_maps[i].layers == layers)
            return (__bridge id<MTLRasterizationRateMap>)g_vrr_maps[i].map;
    // KL_VRR_UNIFORM=1: every zone at q (a plain downscale in physical space; tests whether the scene's
    // shaders look anything up by screen position, which a rate map would misplace).
    static int uniform = -1;
    if (uniform < 0) { const char *u = getenv("KL_VRR_UNIFORM"); uniform = u && *u == '1'; }
    float q = g_vrr_q, m = uniform ? q : (1 + q) / 2, r[5] = { q, m, uniform ? q : 1, m, q };
    MTLRasterizationRateLayerDescriptor *l =
        [[MTLRasterizationRateLayerDescriptor alloc] initWithSampleCount:MTLSizeMake(5, 5, 0) horizontal:r vertical:r];
    MTLRasterizationRateLayerDescriptor *ls[8];
    for (NSUInteger i = 0; i < layers && i < 8; i++) ls[i] = l;
    MTLRasterizationRateMapDescriptor *md = [MTLRasterizationRateMapDescriptor
        rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(w, h, 0) layerCount:layers layers:ls];
    id<MTLRasterizationRateMap> map = [dev newRasterizationRateMapWithDescriptor:md];
    if (!map) return nil;
    for (int i = 0; i < 8; i++)
        if (!g_vrr_maps[i].map) {
            g_vrr_maps[i].w = w; g_vrr_maps[i].h = h; g_vrr_maps[i].layers = layers;
            g_vrr_maps[i].map = (void *)CFBridgingRetain(map);
            // KL_VRR_DUMP=<file>: the map's logical->physical mapping along each axis (it is separable), for an
            // offline unwarp of a snapshot: "x <logical> <physical>" and "y <logical> <physical>" lines.
            const char *dump = getenv("KL_VRR_DUMP");
            if (dump && *dump) {
                FILE *df = fopen(dump, "w");
                if (df) {
                    fprintf(df, "screen %lu %lu\n", (unsigned long)w, (unsigned long)h);
                    for (NSUInteger x = 0; x <= w; x++) {
                        MTLCoordinate2D c = [map mapScreenToPhysicalCoordinates:MTLCoordinate2DMake((float)x, (float)h / 2) forLayer:0];
                        fprintf(df, "x %lu %.4f\n", (unsigned long)x, c.x);
                    }
                    for (NSUInteger y = 0; y <= h; y++) {
                        MTLCoordinate2D c = [map mapScreenToPhysicalCoordinates:MTLCoordinate2DMake((float)w / 2, (float)y) forLayer:0];
                        fprintf(df, "y %lu %.4f\n", (unsigned long)y, c.y);
                    }
                    fclose(df);
                }
            }
            MTLSize ps = [map physicalSizeForLayer:0];
            fprintf(stderr, "[vrr] rate map %lux%lu x%lu layers, q %.2f: physical %lux%lu (%.0f%% of the pixels)\n",
                    (unsigned long)w, (unsigned long)h, (unsigned long)layers, q, (unsigned long)ps.width,
                    (unsigned long)ps.height, 100.0 * ps.width * ps.height / ((double)w * h));
            break;
        }
    return map;
}

// ---- Per-pass GPU time (KL_GPU_PASSES; diagnostics) ---------------------------
// Windows of KL_GPU_PASSES_N guest frames (default 24) in which every render, compute and blit encoder on the
// guest's queue gets Metal stage-boundary timestamps in a counter sample buffer of our own. It is attached at the
// first FREE sampleBufferAttachments index: VPKEngine samples every encoder at index 0 for its own timings (its
// timestamp queries), which build 26 overwrote on render passes; Metal has 4 per pass. Compute and blit encoders
// are timed whether made with a descriptor (VPKEngine) or without (MoltenVK).
// KL_GPU_PASSES lists the windows, comma separated:
//   <n>    from guest frame n
//   t<s>   s seconds after the first guest frame (wall time)
//   g<s>   s seconds after EVERY scene start: the game fading the grid out (IVRCompositor::FadeGrid at the end of
//          the start-up and of each level load; kl_gpu_time_scene, from the OpenVR shim). Fading back to the grid
//          (a load starting) drops that scene's windows that have not started.
// Build 26's windows were only t75..t330 after the first frame: a run that quit at 70 s or crashed gave nothing.
// Windows run one at a time, in time order. Each report ([passes] lines): busy (sum of exclusive encoder times),
// span (first encoder start to last end) and the GPU idle inside it (waits on fences/events, late submits), the
// [gputime] union of the same frames, time per kind (MSAA scene, eye 1x, depth-only, 2D UI targets, other, compute,
// blit) and the top passes by what they draw into. The first window of each scene (4 at most) also lists one frame's
// encoders in order. Encoders overlap on the GPU, so exclusive time is what each adds past everything before it.
enum { kProfPerBuf = 4096, kProfBufs = 8, kProfSamples = kProfPerBuf * kProfBufs };   // Metal: 32 KB per buffer
enum { kKindMsaa, kKindEye1x, kKindDepth, kKindUi, kKindOther, kKindCompute, kKindBlit, kKinds };
static const char *const k_prof_kind[kKinds] = { "scene-msaa", "eye-1x", "depth-only", "ui-2d", "other-rt", "compute", "blit" };
enum { kProfSampleSlots = 4 };                    // MTLMax{Render,Compute,Blit}PassSampleBuffers
static int g_prof = -1;
static uint32_t g_prof_n = 24;
static volatile uint32_t g_prof_from = UINT32_MAX; // the active window's first guest frame; UINT32_MAX = none
static id<MTLCounterSampleBuffer> g_prof_buf, g_prof_bufs[kProfBufs];
static unsigned g_prof_used;                       // sample pairs handed out in the active window
static unsigned g_prof_noslot;                     // encoders left untimed: all 4 sample attachments taken
static struct { uint32_t frame; uint8_t kind; char sig[200]; } *g_prof_meta;
static MTLTimestamp g_prof_cpu0, g_prof_gpu0;
static os_unfair_lock g_prof_lk = OS_UNFAIR_LOCK_INIT;   // window queue, activation, pair allocation
enum { kProfReqs = 64, kProfSpecs = 16 };
typedef struct { double at; uint32_t frame; int scene; char tag[24]; } prof_req;   // at < 0: by frame number
static prof_req g_prof_q[kProfReqs];
static int g_prof_nq;
static double g_prof_spec_t[kProfSpecs], g_prof_spec_g[kProfSpecs];
static int g_prof_nt, g_prof_ng;
static int g_prof_scene;                           // scene starts seen (grid fade-outs)
static double g_prof_t0;                           // the first guest frame (CACurrentMediaTime)
static int g_prof_win;                             // windows started
static char g_prof_tag[24];                        // the active window's name
static int g_prof_cur_scene, g_prof_cur_loading, g_prof_orders, g_prof_order_scene = -2;
static double g_prof_cur_at;                       // seconds after the first frame it started
static double g_prof_union;                        // [gputime] union of the window's frames (ms) and their count
static unsigned g_prof_union_n;

static void prof_push_locked(double at, uint32_t frame, int scene, const char *tag) {
    if (g_prof_nq >= kProfReqs) return;
    prof_req *r = &g_prof_q[g_prof_nq++];
    r->at = at; r->frame = frame; r->scene = scene;
    snprintf(r->tag, sizeof r->tag, "%s", tag);
}

// The OpenVR shim: the game faded the grid in (to_grid = 1, a level load starting) or out (0, a scene shown).
void kl_gpu_time_scene(int to_grid) {
    if (g_prof <= 0) return;
    double now = CACurrentMediaTime();
    int scene = 0, dropped = 0;
    static int last = -1;
    os_unfair_lock_lock(&g_prof_lk);
    if (to_grid) {
        int j = 0;
        for (int i = 0; i < g_prof_nq; i++) { if (g_prof_q[i].scene >= 1) dropped++; else g_prof_q[j++] = g_prof_q[i]; }
        g_prof_nq = j;
        if (g_prof_from != UINT32_MAX) g_prof_cur_loading = 1;
    } else {
        scene = ++g_prof_scene;
        for (int i = 0; i < g_prof_ng; i++) {
            char tag[24];
            snprintf(tag, sizeof tag, "scene%d+%gs", scene, g_prof_spec_g[i]);
            prof_push_locked(now + g_prof_spec_g[i], 0, scene, tag);
        }
    }
    os_unfair_lock_unlock(&g_prof_lk);
    if (last != to_grid || !to_grid) {
        last = to_grid;
        if (to_grid) fprintf(stderr, "[passes] grid shown (loading): %d pending scene window(s) dropped\n", dropped);
        else fprintf(stderr, "[passes] scene %d shown at %.1f s: %d window(s) queued\n", scene,
                     g_prof_t0 ? now - g_prof_t0 : 0.0, g_prof_ng);
    }
}

static void prof_sig_render(MTLRenderPassDescriptor *d, char *out, size_t n) {
    int u = snprintf(out, n, "R %lux%lu L%lu%s", (unsigned long)d.renderTargetWidth, (unsigned long)d.renderTargetHeight,
                     (unsigned long)d.renderTargetArrayLength, d.rasterizationRateMap ? " vrr" : "");
    for (int i = 0; i < 8 && u < (int)n - 40; i++) {
        MTLRenderPassColorAttachmentDescriptor *a = d.colorAttachments[i];
        if (!a.texture) continue;
        u += snprintf(out + u, n - u, " c%d %lux%lu f%lu s%lu ld%lu st%lu%s", i, (unsigned long)a.texture.width,
                      (unsigned long)a.texture.height, (unsigned long)a.texture.pixelFormat,
                      (unsigned long)a.texture.sampleCount, (unsigned long)a.loadAction, (unsigned long)a.storeAction,
                      a.resolveTexture ? "+r" : "");
    }
    id<MTLTexture> z = d.depthAttachment.texture;
    if (z && u < (int)n - 40)
        snprintf(out + u, n - u, " z %lux%lu f%lu s%lu ld%lu st%lu%s", (unsigned long)z.width, (unsigned long)z.height,
                 (unsigned long)z.pixelFormat, (unsigned long)z.sampleCount, (unsigned long)d.depthAttachment.loadAction,
                 (unsigned long)d.depthAttachment.storeAction, d.depthAttachment.resolveTexture ? "+r" : "");
}
// What a render pass is, for the per-kind totals: anything multisampled is the scene; an eye-sized layered (or
// 2D-array) target at 1x is eye post/overlay work; no colour is a depth-only pass (shadows); an 8-bit colour target
// that is not an eye image is 2D UI (Panorama panels, their blur/box-shadow scratch); the rest (bloom chain, fog,
// HDR intermediates) is "other".
static int prof_kind_render(MTLRenderPassDescriptor *d) {
    id<MTLTexture> c0 = nil;
    int msaa = 0;
    for (int i = 0; i < 8; i++) {
        id<MTLTexture> t = d.colorAttachments[i].texture;
        if (!t) continue;
        if (!c0) c0 = t;
        if (t.sampleCount > 1) msaa = 1;
    }
    id<MTLTexture> z = d.depthAttachment.texture ? d.depthAttachment.texture : d.stencilAttachment.texture;
    if (z && z.sampleCount > 1) msaa = 1;
    if (msaa) return kKindMsaa;
    id<MTLTexture> t = c0 ? c0 : z;
    if (t && t.width >= 1024 && (d.renderTargetArrayLength >= 2 ||
                                 (t.textureType == MTLTextureType2DArray && t.arrayLength >= 2))) return kKindEye1x;
    if (!c0) return kKindDepth;
    switch (c0.pixelFormat) {
    case MTLPixelFormatBGRA8Unorm_sRGB: case MTLPixelFormatRGBA8Unorm_sRGB:
    case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatRGBA8Unorm: return kKindUi;
    default: return kKindOther;
    }
}

// Is guest frame f inside the active window (a cheap check before the locked one)?
static int prof_in(uint32_t f) {
    uint32_t from = g_prof_from;
    return g_prof > 0 && from != UINT32_MAX && f >= from && f - from < g_prof_n;
}
// A sample pair for an encoder in guest frame f, or -1 (not profiling it).
// two = 1: also reserve pair k + 1 (a render pass's stages pair) under the same lock, so the two are adjacent even
// with encoders made on several threads; it starts as '!' (ignored) until the caller fills it.
static int prof_pair(id<MTLCommandBuffer> cb, uint32_t f, int kind, int two) {
    if (!prof_in(f)) return -1;
    int k = -1;
    os_unfair_lock_lock(&g_prof_lk);
    if (prof_in(f) && !g_prof_buf) {
        id<MTLDevice> dev = cb.device;
        id<MTLCounterSet> ts = nil;
        for (id<MTLCounterSet> c in dev.counterSets) if ([c.name isEqualToString:MTLCommonCounterSetTimestamp]) ts = c;
        if (!ts || ![dev supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) {
            fprintf(stderr, "[passes] no stage-boundary timestamp sampling on this GPU: per-pass times off\n");
            g_prof = 0;
        } else {
            MTLCounterSampleBufferDescriptor *bd = [MTLCounterSampleBufferDescriptor new];
            bd.counterSet = ts; bd.storageMode = MTLStorageModeShared; bd.sampleCount = kProfPerBuf;
            for (int i = 0; i < kProfBufs && g_prof > 0; i++) {
                NSError *err = nil;
                g_prof_bufs[i] = [dev newCounterSampleBufferWithDescriptor:bd error:&err];
                if (!g_prof_bufs[i]) {
                    fprintf(stderr, "[passes] no counter sample buffer: %s\n", err.localizedDescription.UTF8String);
                    g_prof = 0;
                }
            }
            g_prof_meta = g_prof > 0 ? calloc(kProfSamples / 2, sizeof *g_prof_meta) : NULL;
            if (!g_prof_meta) g_prof = 0;
            if (g_prof > 0) {
                g_prof_buf = g_prof_bufs[0];
                [dev sampleTimestamps:&g_prof_cpu0 gpuTimestamp:&g_prof_gpu0];
            }
        }
    }
    if (prof_in(f) && g_prof_buf && g_prof_used + (two ? 2u : 1u) <= kProfSamples / 2) {
        k = (int)g_prof_used;
        g_prof_used += two ? 2 : 1;
        g_prof_meta[k].frame = f;
        g_prof_meta[k].kind = (uint8_t)kind;
        g_prof_meta[k].sig[0] = 0;
        if (two) { g_prof_meta[k + 1].frame = f; g_prof_meta[k + 1].kind = kKindOther; g_prof_meta[k + 1].sig[0] = '!'; }
    }
    os_unfair_lock_unlock(&g_prof_lk);
    return k;
}
// Pair k lives in buffer k / (kProfPerBuf / 2), at samples 2 * (k % (kProfPerBuf / 2)) and the one after.
static id<MTLCounterSampleBuffer> prof_buf(int k) { return g_prof_bufs[k / (kProfPerBuf / 2)]; }
static NSUInteger prof_idx(int k) { return 2 * (NSUInteger)(k % (kProfPerBuf / 2)); }
// Metal did not make an encoder with our sample buffer at a second attachment index (MTLMax*PassSampleBuffers says 4
// are allowed; this is the fail-safe): the encoder is made again without it and per-pass timing stops for the session.
static volatile int g_prof_refused;
static void prof_refused(int k, const char *what) {
    if (k >= 0) g_prof_meta[k].sig[0] = '!';
    if (!g_prof_refused) {
        g_prof_refused = 1;
        fprintf(stderr, "[passes] Metal refused a %s encoder with our sample buffer at a free attachment index: "
                "per-pass times OFF for this session\n", what);
    }
}

static id (*g_cce)(id, SEL, MTLDispatchType);    // -computeCommandEncoderWithDispatchType:
static id (*g_bce)(id, SEL);                     // -blitCommandEncoder
static id (*g_cced)(id, SEL, MTLComputePassDescriptor *);   // -computeCommandEncoderWithDescriptor:
static id (*g_bced)(id, SEL, MTLBlitPassDescriptor *);      // -blitCommandEncoderWithDescriptor:
static uint32_t prof_frame_of(id<MTLCommandBuffer> cb, int *role) {
    void *q = (__bridge void *)[cb commandQueue];
    os_unfair_lock_lock(&g_lk);
    *role = watched(q);
    uint32_t f = g_frame;
    os_unfair_lock_unlock(&g_lk);
    return f;
}
// The descriptor variants carry the timestamps (VPKEngine makes every compute and blit encoder this way, with its
// own samples at index 0); the plain ones (MoltenVK) are turned into descriptor calls while a window is open.
// Re-entrancy guard: Metal's own encoder methods may call each other (e.g. the plain variant through the descriptor
// one); inside one of our hooks every nested hook goes straight to the original, so no encoder is timed twice.
static __thread int g_in_enc_hook;
static id kl_cced(id self, SEL sel, MTLComputePassDescriptor *d) {
    if (g_in_enc_hook || g_prof <= 0 || !d || g_prof_refused) return g_cced(self, sel, d);
    int role; uint32_t f = prof_frame_of((id<MTLCommandBuffer>)self, &role);
    if (role != 0 || !prof_in(f)) return g_cced(self, sel, d);
    int slot = 0;
    while (slot < kProfSampleSlots && d.sampleBufferAttachments[slot].sampleBuffer) slot++;
    if (slot == kProfSampleSlots) { g_prof_noslot++; return g_cced(self, sel, d); }
    int k = prof_pair((id<MTLCommandBuffer>)self, f, kKindCompute, 0);
    if (k < 0) return g_cced(self, sel, d);
    snprintf(g_prof_meta[k].sig, sizeof g_prof_meta[k].sig, "C compute%s",
             d.dispatchType == MTLDispatchTypeConcurrent ? " concurrent" : "");
    d.sampleBufferAttachments[slot].sampleBuffer = prof_buf(k);
    d.sampleBufferAttachments[slot].startOfEncoderSampleIndex = prof_idx(k);
    d.sampleBufferAttachments[slot].endOfEncoderSampleIndex = prof_idx(k) + 1;
    g_in_enc_hook = 1;
    id enc = g_cced(self, sel, d);
    if (!enc) { d.sampleBufferAttachments[slot].sampleBuffer = nil; prof_refused(k, "compute"); enc = g_cced(self, sel, d); }
    g_in_enc_hook = 0;
    return enc;
}
static id kl_bced(id self, SEL sel, MTLBlitPassDescriptor *d) {
    if (g_in_enc_hook || g_prof <= 0 || !d || g_prof_refused) return g_bced(self, sel, d);
    int role; uint32_t f = prof_frame_of((id<MTLCommandBuffer>)self, &role);
    if (role != 0 || !prof_in(f)) return g_bced(self, sel, d);
    int slot = 0;
    while (slot < kProfSampleSlots && d.sampleBufferAttachments[slot].sampleBuffer) slot++;
    if (slot == kProfSampleSlots) { g_prof_noslot++; return g_bced(self, sel, d); }
    int k = prof_pair((id<MTLCommandBuffer>)self, f, kKindBlit, 0);
    if (k < 0) return g_bced(self, sel, d);
    snprintf(g_prof_meta[k].sig, sizeof g_prof_meta[k].sig, "B blit");
    d.sampleBufferAttachments[slot].sampleBuffer = prof_buf(k);
    d.sampleBufferAttachments[slot].startOfEncoderSampleIndex = prof_idx(k);
    d.sampleBufferAttachments[slot].endOfEncoderSampleIndex = prof_idx(k) + 1;
    g_in_enc_hook = 1;
    id enc = g_bced(self, sel, d);
    if (!enc) { d.sampleBufferAttachments[slot].sampleBuffer = nil; prof_refused(k, "blit"); enc = g_bced(self, sel, d); }
    g_in_enc_hook = 0;
    return enc;
}
static id kl_cce(id self, SEL sel, MTLDispatchType dt) {
    int role = -1; uint32_t f = 0;
    if (!g_in_enc_hook) f = prof_frame_of((id<MTLCommandBuffer>)self, &role);
    if (g_in_enc_hook || role != 0 || !prof_in(f) || !g_cced || g_prof_refused) {
        int was = g_in_enc_hook;
        g_in_enc_hook = 1;
        id enc = g_cce(self, sel, dt);
        g_in_enc_hook = was;
        return enc;
    }
    MTLComputePassDescriptor *d = [MTLComputePassDescriptor computePassDescriptor];
    d.dispatchType = dt;
    return kl_cced(self, @selector(computeCommandEncoderWithDescriptor:), d);   // our descriptor hook, called directly
}
static id kl_bce(id self, SEL sel) {
    int role = -1; uint32_t f = 0;
    if (!g_in_enc_hook) f = prof_frame_of((id<MTLCommandBuffer>)self, &role);
    if (g_in_enc_hook || role != 0 || !prof_in(f) || !g_bced || g_prof_refused) {
        int was = g_in_enc_hook;
        g_in_enc_hook = 1;
        id enc = g_bce(self, sel);
        g_in_enc_hook = was;
        return enc;
    }
    return kl_bced(self, @selector(blitCommandEncoderWithDescriptor:), [MTLBlitPassDescriptor blitPassDescriptor]);
}

// Game thread, at every frame end: start the next due window when none is open.
static void prof_tick(uint32_t frame) {
    double now = CACurrentMediaTime();
    os_unfair_lock_lock(&g_prof_lk);
    if (!g_prof_t0) {
        g_prof_t0 = now;
        for (int i = 0; i < g_prof_nt; i++) {
            char tag[24];
            snprintf(tag, sizeof tag, "t%g", g_prof_spec_t[i]);
            prof_push_locked(now + g_prof_spec_t[i], 0, -1, tag);
        }
    }
    int best = -1;
    if (g_prof_from == UINT32_MAX)
        for (int i = 0; i < g_prof_nq; i++) {
            const prof_req *r = &g_prof_q[i];
            int due = r->at < 0 ? r->frame <= frame + 1 : r->at <= now;
            if (due && (best < 0 || (r->at >= 0 && (g_prof_q[best].at < 0 || r->at < g_prof_q[best].at)))) best = i;
        }
    if (best >= 0) {
        prof_req r = g_prof_q[best];
        g_prof_q[best] = g_prof_q[--g_prof_nq];
        snprintf(g_prof_tag, sizeof g_prof_tag, "%s", r.tag);
        g_prof_cur_scene = r.scene;
        g_prof_cur_loading = 0;
        g_prof_cur_at = now - g_prof_t0;
        g_prof_union = 0; g_prof_union_n = 0;
        g_prof_used = 0; g_prof_noslot = 0;
        g_prof_win++;
        g_prof_from = frame + 1;
    }
    os_unfair_lock_unlock(&g_prof_lk);
    if (best >= 0) {
        time_t tt = time(NULL);
        struct tm lt;
        localtime_r(&tt, &lt);
        fprintf(stderr, "[passes] W%d %s at %02d:%02d:%02d (%.1f s after the first frame): profiling guest frames %u..%u\n",
                g_prof_win, g_prof_tag, lt.tm_hour, lt.tm_min, lt.tm_sec, g_prof_cur_at, frame + 1, frame + g_prof_n);
    }
}

// Resolve, group and print one finished window (pairs > 0, sample buffers made).
static void prof_print(uint32_t from, unsigned pairs, const char *tag) {
    // Resolve every buffer that was handed pairs into one array, pair k at [2k], [2k+1].
    MTLCounterResultTimestamp *r = calloc(2 * (size_t)pairs + 2, sizeof *r);
    if (!r) return;
    for (unsigned k0 = 0; k0 < pairs; k0 += kProfPerBuf / 2) {
        unsigned nk = pairs - k0 < kProfPerBuf / 2 ? pairs - k0 : kProfPerBuf / 2;
        NSData *part = [prof_buf((int)k0) resolveCounterRange:NSMakeRange(0, 2 * nk)];
        if (part) memcpy(r + 2 * k0, part.bytes, part.length < 2 * nk * sizeof *r ? part.length : 2 * nk * sizeof *r);
    }
    MTLTimestamp cpu1, gpu1;
    [g_prof_buf.device sampleTimestamps:&cpu1 gpuTimestamp:&gpu1];
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double cpu_ns = (double)(cpu1 - g_prof_cpu0) * tb.numer / tb.denom;
    double ns_per_tick = gpu1 > g_prof_gpu0 && cpu_ns > 0 ? cpu_ns / (double)(gpu1 - g_prof_gpu0) : 1.0;
#define PROF_OK(k) (r[2 * (k)].timestamp != MTLCounterErrorValue && r[2 * (k) + 1].timestamp != MTLCounterErrorValue && \
                    r[2 * (k)].timestamp && r[2 * (k) + 1].timestamp >= r[2 * (k)].timestamp)
    // Pass 1: exclusive time per encoder (how far it pushes its frame's end past everything encoded before it, in
    // encoding order), per-frame span and busy, per-signature rows and per-kind totals.
    enum { kMax = 256 };
    static struct { char sig[200]; double t, vtx, frg; unsigned n; uint8_t kind; } row[kMax];
    int rows = 0;
    unsigned bad = 0, nf = 0, encs = 0;
    double total = 0, span_sum = 0, kt[kKinds] = { 0 }, kv[kKinds] = { 0 }, kf[kKinds] = { 0 };
    unsigned kn[kKinds] = { 0 };
    uint32_t cur = UINT32_MAX;
    uint64_t hi = 0, lo = 0;
    for (unsigned k = 0; k <= pairs; k++) {
        // '~': a render pass's stages pair (read with it below); '!': a pair handed out but not attached.
        if (k < pairs && (g_prof_meta[k].sig[0] == '~' || g_prof_meta[k].sig[0] == '!')) continue;
        if (k == pairs || g_prof_meta[k].frame != cur) {   // a frame ends: its span
            if (cur != UINT32_MAX && hi > lo) { span_sum += (double)(hi - lo); nf++; }
            if (k == pairs) break;
            cur = g_prof_meta[k].frame; hi = 0; lo = 0;
        }
        if (!PROF_OK(k)) { bad++; continue; }
        uint64_t a = r[2 * k].timestamp, b = r[2 * k + 1].timestamp;
        // the stages pair right after a render pass: vertex end, fragment start
        double vs = 0, fs = 0;
        if (k + 1 < pairs && g_prof_meta[k + 1].sig[0] == '~') {
            uint64_t ve = r[2 * (k + 1)].timestamp, fb = r[2 * (k + 1) + 1].timestamp;
            if (ve != MTLCounterErrorValue && ve >= a && ve) vs = (double)(ve - a);
            if (fb != MTLCounterErrorValue && fb && b >= fb) fs = (double)(b - fb);
        }
        if (!lo || a < lo) lo = a;
        uint64_t from_t = a > hi ? a : hi;
        double t = b > from_t ? (double)(b - from_t) : 0;
        if (b > hi) hi = b;
        total += t; encs++;
        int kd = g_prof_meta[k].kind < kKinds ? g_prof_meta[k].kind : kKindOther;
        kt[kd] += t; kv[kd] += vs; kf[kd] += fs; kn[kd]++;
        int j = 0;
        while (j < rows && strcmp(row[j].sig, g_prof_meta[k].sig)) j++;
        if (j == rows) {
            if (rows == kMax) continue;
            snprintf(row[rows].sig, sizeof row[rows].sig, "%s", g_prof_meta[k].sig);
            row[rows].t = row[rows].vtx = row[rows].frg = 0; row[rows].n = 0; row[rows].kind = (uint8_t)kd; rows++;
        }
        row[j].t += t; row[j].n++; row[j].vtx += vs; row[j].frg += fs;
    }
    if (!nf) nf = 1;
    // Units: Apple GPUs report these counters in ns, although sampleTimestamps' GPU clock ticks at
    // 24 MHz; take whichever puts the frame's busy time in a sane range (0.2..60 ms).
    double per_frame = total / nf, scale = 1e-6;          // raw ns -> ms
    if (per_frame * scale < 0.2 || per_frame * scale > 60) scale = ns_per_tick * 1e-6;
    double busy = per_frame * scale, span = span_sum / nf * scale;
    fprintf(stderr, "[passes] W%d %s%s: %u frames, %.1f encoders/frame (%u without timestamps, %u untimed: no free sample "
            "slot); busy %.2f ms/frame, span %.2f ms, GPU idle inside the span %.2f ms; [gputime] union %.2f ms (%u frames); "
            "units %s\n", g_prof_win, tag, g_prof_cur_loading ? " (a load began during it)" : "", nf, (double)encs / nf,
            bad, g_prof_noslot, busy, span, span > busy ? span - busy : 0.0,
            g_prof_union_n ? g_prof_union / g_prof_union_n : 0.0, g_prof_union_n, scale == 1e-6 ? "ns" : "GPU ticks");
    {
        char line[600];
        int u = snprintf(line, sizeof line, "[passes] W%d by kind (ms/frame, encoders/frame, vtx/frag):", g_prof_win);
        for (int i = 0; i < kKinds && u < (int)sizeof line - 64; i++)
            if (kn[i]) u += snprintf(line + u, sizeof line - u, " %s %.2f x%.1f (%.2f/%.2f) |", k_prof_kind[i],
                                     kt[i] * scale / nf, (double)kn[i] / nf, kv[i] * scale / nf, kf[i] * scale / nf);
        fprintf(stderr, "%s\n", line);
    }
    // Top passes by exclusive time.
    for (int i = 0; i < rows; i++) for (int j = i + 1; j < rows; j++)
        if (row[j].t > row[i].t) { __typeof__(row[0]) tmp = row[i]; row[i] = row[j]; row[j] = tmp; }
    for (int i = 0; i < rows && i < 16; i++)
        fprintf(stderr, "[passes] W%d %6.3f ms/frame %5.1f%%  x%-5.1f vtx %6.3f frag %6.3f  %-10s %s\n", g_prof_win,
                row[i].t * scale / nf, total > 0 ? 100.0 * row[i].t / total : 0, (double)row[i].n / nf,
                row[i].vtx * scale / nf, row[i].frg * scale / nf, k_prof_kind[row[i].kind], row[i].sig);
    if (rows > 16) {
        double rest = 0; for (int i = 16; i < rows; i++) rest += row[i].t;
        fprintf(stderr, "[passes] W%d %6.3f ms/frame in %d more signatures\n", g_prof_win, rest * scale / nf, rows - 16);
    }
    // One frame in encoding order (the window's second): its first window per scene, 4 scenes at most.
    if (g_prof_orders < 4 && g_prof_cur_scene != g_prof_order_scene) {
        g_prof_orders++; g_prof_order_scene = g_prof_cur_scene;
        uint32_t fd = from + 1; uint64_t h2 = 0, f0 = 0; int idx = 0;
        for (unsigned k = 0; k < pairs; k++) {
            if (g_prof_meta[k].frame != fd || g_prof_meta[k].sig[0] == '~' || g_prof_meta[k].sig[0] == '!') continue;
            if (!PROF_OK(k)) { fprintf(stderr, "[passes] W%d f%u #%03d (no timestamps) %s\n", g_prof_win, fd, idx++, g_prof_meta[k].sig); continue; }
            uint64_t a = r[2 * k].timestamp, b = r[2 * k + 1].timestamp;
            if (!f0) f0 = a;
            uint64_t from_t = a > h2 ? a : h2;
            fprintf(stderr, "[passes] W%d f%u #%03d at %7.3f span %6.3f excl %6.3f ms  %s\n", g_prof_win, fd, idx++,
                    (double)(a - f0) * scale, (double)(b - a) * scale, b > from_t ? (double)(b - from_t) * scale : 0.0,
                    g_prof_meta[k].sig);
            if (b > h2) h2 = b;
        }
    }
#undef PROF_OK
    free(r);
}

// After the active window's frames are final: print it (in an autorelease pool: the resolved counters are
// autoreleased and the game thread has none) and close it, so the next window can start.
static void prof_report(uint32_t frame) {
    uint32_t from = g_prof_from;
    // 12: VPKEngine keeps up to 12 command buffers (several frames) in flight; their samples must have landed.
    if (g_prof <= 0 || from == UINT32_MAX || frame < from + g_prof_n + 12) return;
    os_unfair_lock_lock(&g_prof_lk);
    unsigned pairs = g_prof_used;
    os_unfair_lock_unlock(&g_prof_lk);
    if (!pairs || !g_prof_buf)
        fprintf(stderr, "[passes] W%d %s: no encoder timed (%u left without a free sample slot)\n", g_prof_win, g_prof_tag,
                g_prof_noslot);
    else
        @autoreleasepool { prof_print(from, pairs, g_prof_tag); }
    os_unfair_lock_lock(&g_prof_lk);
    g_prof_used = 0;
    g_prof_from = UINT32_MAX;
    os_unfair_lock_unlock(&g_prof_lk);
}


// ---- Merging suspended/resumed scene passes (KL_VK_MERGE=1; experimental) -----
// Source 2 records its stereo scene pass as one Vulkan render pass instance split across command
// buffers with dynamic-rendering suspend/resume. MoltenVK ends the Metal encoder at every
// suspension, storing and resolving the full MSAA colour and depth, and loads them again at the
// resume. Per Vulkan the chunks are one render pass instance (an intermediate resolve is not
// observable), so here the Metal encoder is kept open across them: MoltenVK's endEncoding on an MSAA
// encoder is deferred, and when the next render pass on the same command buffer loads exactly the
// same attachments the same encoder is handed back. Its store actions are cached and applied at the
// real end, which comes before any other encoder, event or commit on that command buffer.
typedef struct {
    void *enc, *cb;                      // retained encoder; its command buffer (not retained)
    void *tex[10], *res[10];             // colour 0..7, depth, stencil attachments and resolve targets
    NSUInteger slice[10], level[10], w, h, layers;
    void *vis;                           // visibility result buffer (occlusion queries); must be the same
    int held;                            // MoltenVK has ended it; the real end is pending
    int st_set[10]; MTLStoreAction st[10];
    int opt_set[10]; MTLStoreActionOptions opt[10];
} kl_merge_t;
enum { kMergeMax = 16 };
static kl_merge_t g_mg[kMergeMax];
static os_unfair_lock g_mg_lk = OS_UNFAIR_LOCK_INIT;
static int g_merge = -1;
static unsigned g_merged, g_flushed;
static IMP g_end, g_scsa, g_sdsa, g_sssa, g_scso, g_sdso, g_ssso;
static IMP g_m_cce, g_m_bce, g_m_bced, g_m_cced, g_m_sig, g_m_wait;

static void mg_fill(kl_merge_t *m, MTLRenderPassDescriptor *d) {
    for (int i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *a = d.colorAttachments[i];
        m->tex[i] = (__bridge void *)a.texture; m->res[i] = (__bridge void *)a.resolveTexture;
        m->slice[i] = a.slice; m->level[i] = a.level;
    }
    m->tex[8] = (__bridge void *)d.depthAttachment.texture; m->res[8] = (__bridge void *)d.depthAttachment.resolveTexture;
    m->slice[8] = d.depthAttachment.slice; m->level[8] = d.depthAttachment.level;
    m->tex[9] = (__bridge void *)d.stencilAttachment.texture; m->res[9] = (__bridge void *)d.stencilAttachment.resolveTexture;
    m->slice[9] = d.stencilAttachment.slice; m->level[9] = d.stencilAttachment.level;
    m->w = d.renderTargetWidth; m->h = d.renderTargetHeight; m->layers = d.renderTargetArrayLength;
    m->vis = (__bridge void *)d.visibilityResultBuffer;
}
// KL_VK_MSAA_MEMORYLESS (kl_vulkan.c): a memoryless attachment lives only inside one encoder, so no encoder may load
// or store one. A resume chunk that did not merge into the held encoder would load it: that is counted ("unmerged
// load", the number that must stay zero) and made legal (DontCare), and a store is turned into DontCare or a plain
// resolve, so Metal never sees an illegal action. [ml] lines report the counts every 2000 memoryless encoders.
static _Atomic unsigned g_ml_enc, g_ml_loads, g_ml_stores;
static int ml_is(void *tex) { return tex && ((__bridge id<MTLTexture>)tex).storageMode == MTLStorageModeMemoryless; }
static MTLStoreAction ml_store(MTLStoreAction a) {
    if (a == MTLStoreActionStore) { atomic_fetch_add(&g_ml_stores, 1); return MTLStoreActionDontCare; }
    if (a == MTLStoreActionStoreAndMultisampleResolve) { atomic_fetch_add(&g_ml_stores, 1); return MTLStoreActionMultisampleResolve; }
    return a;
}
// A pass that loads any attachment is a resume (MoltenVK turned the memoryless ones' Load into DontCare).
static int ml_resume(MTLRenderPassDescriptor *d) {
    for (int i = 0; i < 8; i++) if (d.colorAttachments[i].texture && d.colorAttachments[i].loadAction == MTLLoadActionLoad) return 1;
    if (d.depthAttachment.texture && d.depthAttachment.loadAction == MTLLoadActionLoad) return 1;
    return 0;
}
static void ml_guard(MTLRenderPassDescriptor *d) {
    if (!d) return;
    int any = 0;
    for (int i = 0; i < 10; i++) {
        MTLRenderPassAttachmentDescriptor *a = i < 8 ? (MTLRenderPassAttachmentDescriptor *)d.colorAttachments[i]
                                             : i == 8 ? (MTLRenderPassAttachmentDescriptor *)d.depthAttachment
                                                      : (MTLRenderPassAttachmentDescriptor *)d.stencilAttachment;
        if (!ml_is((__bridge void *)a.texture)) continue;
        any = 1;
        if (a.loadAction == MTLLoadActionLoad || (a.loadAction == MTLLoadActionDontCare && ml_resume(d))) {
            unsigned n = atomic_fetch_add(&g_ml_loads, 1) + 1;
            if (n <= 8) fprintf(stderr, "[ml] UNMERGED load of memoryless attachment %d (%lux%lu) -> DontCare (#%u)\n", i,
                                (unsigned long)a.texture.width, (unsigned long)a.texture.height, n);
            a.loadAction = MTLLoadActionDontCare;
        }
        a.storeAction = ml_store(a.storeAction);
    }
    if (any) {
        unsigned n = atomic_fetch_add(&g_ml_enc, 1) + 1;
        if (n == 1 || n % 2000 == 0)
            fprintf(stderr, "[ml] %u memoryless MSAA encoders, %u unmerged loads, %u stores dropped\n", n,
                    atomic_load(&g_ml_loads), atomic_load(&g_ml_stores));
    }
}

// A pass that only continues the held one: the same attachments, every one of them loaded.
static int mg_continues(const kl_merge_t *m, MTLRenderPassDescriptor *d) {
    kl_merge_t n; memset(&n, 0, sizeof n); mg_fill(&n, d);
    for (int i = 0; i < 10; i++)
        if (n.tex[i] != m->tex[i] || n.res[i] != m->res[i] || n.slice[i] != m->slice[i] || n.level[i] != m->level[i]) return 0;
    if (n.w != m->w || n.h != m->h || n.layers != m->layers || n.vis != m->vis || d.rasterizationRateMap) return 0;
    // A memoryless attachment (KL_VK_MSAA_MEMORYLESS) is never loaded: MoltenVK turns a resume's Load into DontCare
    // for it, so DontCare there also continues the held pass (a Clear still starts a new one).
    #define MG_LOADS(a) ((a).loadAction == MTLLoadActionLoad || \
                         ((a).loadAction == MTLLoadActionDontCare && ml_is((__bridge void *)(a).texture)))
    for (int i = 0; i < 8; i++) if (d.colorAttachments[i].texture && !MG_LOADS(d.colorAttachments[i])) return 0;
    if (d.depthAttachment.texture && !MG_LOADS(d.depthAttachment)) return 0;
    if (d.stencilAttachment.texture && !MG_LOADS(d.stencilAttachment)) return 0;
    #undef MG_LOADS
    return 1;
}
static kl_merge_t *mg_of_enc(void *e) { for (int i = 0; i < kMergeMax; i++) if (g_mg[i].enc == e) return &g_mg[i]; return NULL; }
static kl_merge_t *mg_held_on(void *cb) { for (int i = 0; i < kMergeMax; i++) if (g_mg[i].enc && g_mg[i].cb == cb && g_mg[i].held) return &g_mg[i]; return NULL; }

// The real end of a held encoder: its latest store actions, then endEncoding. Call without g_mg_lk.
static void mg_finish(kl_merge_t c) {
    id enc = (__bridge id)c.enc;
    for (int i = 0; i < 10; i++) if (c.st_set[i] && ml_is(c.tex[i])) c.st[i] = ml_store(c.st[i]);
    for (int i = 0; i < 8; i++) {
        if (c.st_set[i]) ((void (*)(id, SEL, MTLStoreAction, NSUInteger))g_scsa)(enc, @selector(setColorStoreAction:atIndex:), c.st[i], (NSUInteger)i);
        if (c.opt_set[i] && g_scso) ((void (*)(id, SEL, MTLStoreActionOptions, NSUInteger))g_scso)(enc, @selector(setColorStoreActionOptions:atIndex:), c.opt[i], (NSUInteger)i);
    }
    if (c.st_set[8]) ((void (*)(id, SEL, MTLStoreAction))g_sdsa)(enc, @selector(setDepthStoreAction:), c.st[8]);
    if (c.opt_set[8] && g_sdso) ((void (*)(id, SEL, MTLStoreActionOptions))g_sdso)(enc, @selector(setDepthStoreActionOptions:), c.opt[8]);
    if (c.st_set[9]) ((void (*)(id, SEL, MTLStoreAction))g_sssa)(enc, @selector(setStencilStoreAction:), c.st[9]);
    if (c.opt_set[9] && g_ssso) ((void (*)(id, SEL, MTLStoreActionOptions))g_ssso)(enc, @selector(setStencilStoreActionOptions:), c.opt[9]);
    ((void (*)(id, SEL))g_end)(enc, @selector(endEncoding));
    CFRelease(c.enc);
}
// End whatever is held on this command buffer (before any other use of it). `why` names the call that needs it ended;
// for a held pass with a memoryless attachment the first few are logged ([ml] flush), because a resume after one of
// these cannot continue that pass.
static void mg_flush_why(void *cb, const char *why) {
    if (g_merge <= 0) return;
    os_unfair_lock_lock(&g_mg_lk);
    kl_merge_t *m = mg_held_on(cb), c;
    if (m) { c = *m; memset(m, 0, sizeof *m); g_flushed++; }
    os_unfair_lock_unlock(&g_mg_lk);
    if (m) {
        int ml = 0; for (int i = 0; i < 10; i++) if (ml_is(c.tex[i])) ml = 1;
        static _Atomic unsigned said;
        if (ml && why && atomic_fetch_add(&said, 1) < 12) {
            fprintf(stderr, "[ml] flush of a held memoryless pass by %s\n", why);
            static _Atomic unsigned bt;
            if (atomic_fetch_add(&bt, 1) < 4) {   // who asked for it (MoltenVK's command), the first few
                void *fr[24]; int n = backtrace(fr, 24); char **sy = backtrace_symbols(fr, n);
                for (int k = 1; k < n && sy; k++) fprintf(stderr, "[ml]   %s\n", sy[k]);
                free(sy);
            }
        }
        mg_finish(c);
    }
}
static void mg_flush(void *cb) { mg_flush_why(cb, NULL); }   // commit: the pass's normal end
// For the guest-stall dump (kl_app.c): how many merged scene encoders are held open right now, and the counters.
int kl_merge_held(unsigned *merged, unsigned *flushed) {
    int n = 0;
    os_unfair_lock_lock(&g_mg_lk);
    for (int i = 0; i < kMergeMax; i++) if (g_mg[i].enc && g_mg[i].held) n++;
    os_unfair_lock_unlock(&g_mg_lk);
    if (merged) *merged = g_merged;
    if (flushed) *flushed = g_flushed;
    return n;
}

static void kl_end(id self, SEL sel) {
    if (g_merge > 0) {
        os_unfair_lock_lock(&g_mg_lk);
        kl_merge_t *m = mg_of_enc((__bridge void *)self);
        if (m && !m->held) { m->held = 1; os_unfair_lock_unlock(&g_mg_lk); return; }
        os_unfair_lock_unlock(&g_mg_lk);
    }
    ((void (*)(id, SEL))g_end)(self, sel);
}
#define MG_CACHE(idx, field, flag, val) do { \
    if (g_merge > 0) { \
        os_unfair_lock_lock(&g_mg_lk); \
        kl_merge_t *m = mg_of_enc((__bridge void *)self); \
        if (m) { m->field[idx] = (val); m->flag[idx] = 1; os_unfair_lock_unlock(&g_mg_lk); return; } \
        os_unfair_lock_unlock(&g_mg_lk); \
    } } while (0)
static void kl_scsa(id self, SEL sel, MTLStoreAction a, NSUInteger i) {
    if (i < 8) MG_CACHE(i, st, st_set, a);
    ((void (*)(id, SEL, MTLStoreAction, NSUInteger))g_scsa)(self, sel, a, i);
}
static void kl_sdsa(id self, SEL sel, MTLStoreAction a) { MG_CACHE(8, st, st_set, a); ((void (*)(id, SEL, MTLStoreAction))g_sdsa)(self, sel, a); }
static void kl_sssa(id self, SEL sel, MTLStoreAction a) { MG_CACHE(9, st, st_set, a); ((void (*)(id, SEL, MTLStoreAction))g_sssa)(self, sel, a); }
static void kl_scso(id self, SEL sel, MTLStoreActionOptions o, NSUInteger i) {
    if (i < 8) MG_CACHE(i, opt, opt_set, o);
    ((void (*)(id, SEL, MTLStoreActionOptions, NSUInteger))g_scso)(self, sel, o, i);
}
static void kl_sdso(id self, SEL sel, MTLStoreActionOptions o) { MG_CACHE(8, opt, opt_set, o); ((void (*)(id, SEL, MTLStoreActionOptions))g_sdso)(self, sel, o); }
static void kl_ssso(id self, SEL sel, MTLStoreActionOptions o) { MG_CACHE(9, opt, opt_set, o); ((void (*)(id, SEL, MTLStoreActionOptions))g_ssso)(self, sel, o); }

// Everything else a command buffer can do ends the held encoder first.
static id kl_m_cce(id self, SEL sel, MTLDispatchType t) { mg_flush_why((__bridge void *)self, "computeCommandEncoder"); return ((id (*)(id, SEL, MTLDispatchType))g_m_cce)(self, sel, t); }
static id kl_m_bce(id self, SEL sel) { mg_flush_why((__bridge void *)self, "blitCommandEncoder"); return ((id (*)(id, SEL))g_m_bce)(self, sel); }
static id kl_m_bced(id self, SEL sel, id d) { mg_flush_why((__bridge void *)self, "blitCommandEncoderWithDescriptor"); return ((id (*)(id, SEL, id))g_m_bced)(self, sel, d); }
static id kl_m_cced(id self, SEL sel, id d) { mg_flush_why((__bridge void *)self, "computeCommandEncoderWithDescriptor"); return ((id (*)(id, SEL, id))g_m_cced)(self, sel, d); }
static void kl_m_sig(id self, SEL sel, id ev, uint64_t v) { mg_flush_why((__bridge void *)self, "encodeSignalEvent"); ((void (*)(id, SEL, id, uint64_t))g_m_sig)(self, sel, ev, v); }
static void kl_m_wait(id self, SEL sel, id ev, uint64_t v) { mg_flush_why((__bridge void *)self, "encodeWaitForEvent"); ((void (*)(id, SEL, id, uint64_t))g_m_wait)(self, sel, ev, v); }

static void hook(Class c, SEL s, IMP mine, IMP *orig);
// ---- Foveated scene passes (KL_VRR=1) ------------------------------------------
// The spike above, made the real thing. Measured on the Mac (2026-09-29): a rate map on the scene
// passes alone is enough, because Source 2's post chain (bloom, the output pass) simply carries the
// squeezed ("physical") layout through to the eye image, and the compositor unwarps it with the same
// map (kl_glfb_eye_rate_map -> the unwarp grid). Offline unwarp against a normal frame: 0.47/255 mean
// difference; the lighting is placed right because nothing in the scene shaders keys on screen position.
// Each eye gets its own layer, full rate around its OWN optical axis (the frustum is asymmetric, so the
// axis is off-centre: ~63% across for the left eye, ~37% for the right), falling off to KL_VRR_EDGE
// (default 0.35) at the far edge. KL_VRR_INNER / KL_VRR_OUTER: where the fall-off starts and ends, as
// fractions of the image width from the axis (defaults 0.18 and 0.50).
enum { kVrrZones = 16, kVrrZonesMax = 32 };
// Zones per axis of the map the scene passes are foveated with (vrr_fov_map): 32 for the wide map (half the
// quantisation of 16: the sharp zone ends within ~3 degrees of where it should), 16 otherwise or if Metal refuses 32.
static int g_vrr_fov_zones = kVrrZones;
extern void kl_ovrp_eye_view(int eye, float *px, float *py, float *pz, float *qx, float *qy, float *qz, float *qw, float tan4[4]);
static int g_vrr_on = -1;
// Live overrides (pause menu, kl_vrr_set): win over the environment read at start. NAN = not set.
static float g_vrr_live_inner = NAN, g_vrr_live_outer = NAN, g_vrr_live_edge = NAN;
static int g_vrr_live_soft = -1;
static float vrr_env(const char *n, float d) {
    float live = !strcmp(n, "KL_VRR_INNER") ? g_vrr_live_inner : !strcmp(n, "KL_VRR_OUTER") ? g_vrr_live_outer
               : !strcmp(n, "KL_VRR_EDGE") ? g_vrr_live_edge : NAN;
    if (g_vrr_live_soft >= 0) return isnan(live) ? d : live;   // a live preset replaces the start-up values
    const char *e = getenv(n);
    return e && *e ? (float)atof(e) : d;
}
// Rate per zone along one axis: 1 within `in` (a fraction of the image) of the axis, falling linearly to `edge` at `out`.
static void vrr_rates(float centre, float in, float outr, float edge, float *out, int n) {
    for (int i = 0; i < n; i++) {
        float p = ((float)i + 0.5f) / n, t = fabsf(p - centre);
        out[i] = t <= in ? 1.0f : t >= outr ? edge : 1.0f - (1.0f - edge) * (t - in) / (outr - in);
    }
}
// KL_VRR_MAP: "centre" (default) keeps full rate within +-20 degrees of each eye's axis (about Apple's own fixed
// foveation region), converted to image fractions from the eye's tangents, then falls to 0.25 over the next 12%
// of the image; "soft" is the first map (full rate within 18% of the width, 0.35 from 50% out). KL_VRR_EDGE,
// KL_VRR_INNER, KL_VRR_OUTER override either.
// KL_VRR_MAP=wide (AVP's M2/M5 presets): PTVisionPro's tested foveation, the user's reference: a sharp zone 60 degrees
// across around each eye's FORWARD axis (tangent 0, not the image centre), its centre 10 degrees BELOW that axis (the
// headset shows more below than above), the rest at KL_VRR_EDGE (10 % default, up to 65 % on an M5). A rate map is
// separable, so the circle becomes the
// rectangle that holds it; the ramp to the periphery is one zone wide. Build 24 gave a zone the rate of its point
// NEAREST the centre and used 16 zones: the sharp zone grew by up to a zone plus the ramp on each side (~13 degrees,
// the user saw it reach well past P.T.'s edge). Build 25: 32 zones, each rated at its own centre.
// Live mode (kl_vrr_set): 0 centre, 1 soft, 2 wide; -1 = from the environment.
static int vrr_mode(void) {
    if (g_vrr_live_soft >= 0) return g_vrr_live_soft;
    const char *m = getenv("KL_VRR_MAP");
    return m && !strcmp(m, "soft") ? 1 : m && !strcmp(m, "wide") ? 2 : 0;
}
static int vrr_soft(void) { return vrr_mode() == 1; }
static id<MTLRasterizationRateMap> vrr_fov_map(id<MTLDevice> dev, NSUInteger w, NSUInteger h, NSUInteger layers) {
    for (int i = 0; i < 8; i++)
        if (g_vrr_maps[i].map && g_vrr_maps[i].w == w && g_vrr_maps[i].h == h && g_vrr_maps[i].layers == layers)
            return (__bridge id<MTLRasterizationRateMap>)g_vrr_maps[i].map;
    MTLRasterizationRateLayerDescriptor *ls[2];
    float cx[2] = { 0.5f, 0.5f }, cy = 0.5f, span_x = 2.732f, span_y = 2.192f;   // headset-like defaults
    for (int e = 0; e < 2; e++) {
        float p[3], q[4], t[4] = { 0, 0, 0, 0 };   // tangents: left, right, up, down
        kl_ovrp_eye_view(e, &p[0], &p[1], &p[2], &q[0], &q[1], &q[2], &q[3], t);
        if (t[0] > 0 && t[1] > 0) { cx[e] = t[0] / (t[0] + t[1]); span_x = t[0] + t[1]; }
        if (e == 0 && t[2] > 0 && t[3] > 0) { cy = t[2] / (t[2] + t[3]); span_y = t[2] + t[3]; }
    }
    int soft = vrr_soft(), wide = vrr_mode() == 2;
    float tan20 = 0.364f;
    char wide_deg[24] = "";
    float in_x, in_y, out_x, out_y, edge;
    float deg = 60.0f;
    if (wide) {
        // Forward axis = tangent 0: x at left/(left+right) across (cx), y at up/(up+down) from the top (cy). The
        // centre sits 10 degrees below it, tan(10) = 0.1763 further down; half width tan(deg / 2): KL_VRR_WIDE_DEG
        // (30..70, the launcher's "zona nítida"; 60 = PTVisionPro's, tan(30) = 0.5774).
        cy += 0.1763f / span_y;
        const char *wd = getenv("KL_VRR_WIDE_DEG");   // launch-time only (not a live value)
        deg = wd && *wd ? (float)atof(wd) : 60.0f;
        if (!(deg >= 30.0f)) deg = 30.0f;
        if (deg > 70.0f) deg = 70.0f;
        snprintf(wide_deg, sizeof wide_deg, " %.0f deg", deg);
    }
    id<MTLRasterizationRateMap> map = nil;
    // The wide map at 32 zones per axis, 16 if Metal refuses it; the other maps at 16 as before.
    for (int zones = wide ? kVrrZonesMax : kVrrZones; !map && zones >= kVrrZones; zones /= 2) {
        float rx[2][kVrrZonesMax], ry[kVrrZonesMax];
        if (wide) {
            const float half = tanf(deg * 0.5f * (float)M_PI / 180.0f);
            in_x = vrr_env("KL_VRR_INNER", half / span_x);
            in_y = vrr_env("KL_VRR_INNER", half / span_y);
            out_x = vrr_env("KL_VRR_OUTER", in_x + 1.0f / zones);   // the ramp: one zone
            out_y = vrr_env("KL_VRR_OUTER", in_y + 1.0f / zones);
            edge = vrr_env("KL_VRR_EDGE", 0.10f);
        } else {
            in_x = vrr_env("KL_VRR_INNER", soft ? 0.18f : tan20 / span_x);
            in_y = vrr_env("KL_VRR_INNER", soft ? 0.18f : tan20 / span_y);
            out_x = vrr_env("KL_VRR_OUTER", soft ? 0.50f : in_x + 0.12f);
            out_y = vrr_env("KL_VRR_OUTER", soft ? 0.50f : in_y + 0.12f);
            edge = vrr_env("KL_VRR_EDGE", soft ? 0.35f : 0.25f);
        }
        // Every zone rated at its own centre (wide included: see above).
        vrr_rates(cy, in_y, out_y, edge, ry, zones);
        for (NSUInteger l = 0; l < layers && l < 2; l++) {
            vrr_rates(cx[layers > 1 ? l : 0], in_x, out_x, edge, rx[l], zones);
            ls[l] = [[MTLRasterizationRateLayerDescriptor alloc] initWithSampleCount:MTLSizeMake(zones, zones, 0)
                                                                         horizontal:rx[l] vertical:ry];
        }
        MTLRasterizationRateMapDescriptor *md = [MTLRasterizationRateMapDescriptor
            rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(w, h, 0) layerCount:(layers > 1 ? 2 : 1) layers:ls];
        map = [dev newRasterizationRateMapWithDescriptor:md];
        if (map) g_vrr_fov_zones = zones;   // this map's count, stored with it in the cache below
        else fprintf(stderr, "[vrr] Metal refused a %d-zone map\n", zones);
    }
    if (!map) return nil;
    for (int i = 0; i < 8; i++)
        if (!g_vrr_maps[i].map) {
            g_vrr_maps[i].w = w; g_vrr_maps[i].h = h; g_vrr_maps[i].layers = layers;
            g_vrr_maps[i].map = (void *)CFBridgingRetain(map);
            g_vrr_maps[i].zones = g_vrr_fov_zones;
            break;
        }
    MTLSize p0 = [map physicalSizeForLayer:0];
    fprintf(stderr, "[vrr] foveated map (%s%s, %d zones) %lu layer(s) %lux%lu: axis at %.0f%% / %.0f%% across, %.0f%% down; full rate within %.0f%%/%.0f%%, "
            "edge %.2f; physical %lux%lu (%.0f%% of the pixels)\n", soft ? "soft" : wide ? "wide" : "centre", wide_deg, g_vrr_fov_zones, (unsigned long)(layers > 1 ? 2 : 1),
            (unsigned long)w, (unsigned long)h, 100 * cx[0], 100 * cx[1], 100 * cy, 100 * in_x, 100 * in_y, edge, (unsigned long)p0.width,
            (unsigned long)p0.height, 100.0 * p0.width * p0.height / ((double)w * h));
    const char *dump = getenv("KL_VRR_DUMP");
    if (dump && *dump) {
        FILE *df = fopen(dump, "w");
        if (df) {
            fprintf(df, "screen %lu %lu\n", (unsigned long)w, (unsigned long)h);
            for (NSUInteger l = 0; l < (layers > 1 ? 2 : 1); l++) {
                for (NSUInteger x = 0; x <= w; x++)
                    fprintf(df, "x%lu %lu %.4f\n", (unsigned long)l, (unsigned long)x,
                            [map mapScreenToPhysicalCoordinates:MTLCoordinate2DMake((float)x, (float)h / 2) forLayer:l].x);
                for (NSUInteger y = 0; y <= h; y++)
                    fprintf(df, "y%lu %lu %.4f\n", (unsigned long)l, (unsigned long)y,
                            [map mapScreenToPhysicalCoordinates:MTLCoordinate2DMake((float)w / 2, (float)y) forLayer:l].y);
            }
            fclose(df);
        }
    }
    return map;
}

// For the compositor's unwarp grid (KleptonCompositor.unwarpGrid): screen -> physical for one eye of the
// published map, for an eye image stored TOP-DOWN (Vulkan). The grid is built bottom-up and the shader flips
// v afterwards (kl_reproject_v, flipY), so the screen y is flipped on the way in and the physical y
// pre-compensated on the way out: the shader's flip then lands on the physical texel.
typedef struct { void *map; unsigned layer; float scr_h, tex_h; } kl_vrr_ctx;
static kl_vrr_ctx g_vrr_ctx[2];
void kl_vrr_s2p(void *ctx, float sx, float sy, float *px, float *py) {
    kl_vrr_ctx *c = (kl_vrr_ctx *)ctx;
    if (!c || !c->map) { *px = sx; *py = sy; return; }
    id<MTLRasterizationRateMap> m = (__bridge id<MTLRasterizationRateMap>)c->map;
    MTLCoordinate2D p = [m mapScreenToPhysicalCoordinates:MTLCoordinate2DMake(sx, c->scr_h - sy) forLayer:c->layer];
    *px = p.x;
    *py = c->tex_h - p.y;
}
// The foveated map an eye image of this size was rasterized through (NULL if none): the compositor picks by the
// size of the image in hand, so a frame rendered at the previous fidelity level is unwarped with ITS map.
// Live foveation settings (pause menu): forget the cached maps so the next scene pass builds one from the
// current KL_VRR_* environment. The old maps are not released: the compositor and the guest's published
// eye-map pointer may still be using them for a frame in flight (8 small objects at most per change).
void kl_vrr_set(int mode, float inner, float outer, float edge) {   // mode: 0 centre, 1 soft, 2 wide
    g_vrr_live_inner = inner, g_vrr_live_outer = outer, g_vrr_live_edge = edge;   // < 0: preset default
    if (inner < 0) g_vrr_live_inner = NAN;
    if (outer < 0) g_vrr_live_outer = NAN;
    if (edge < 0) g_vrr_live_edge = NAN;
    g_vrr_live_soft = mode >= 0 && mode <= 2 ? mode : 0;
    kl_vrr_reload();
}
static void vrr_forget_full(void);
void kl_vrr_reload(void) {
    for (int i = 0; i < 8; i++) g_vrr_maps[i].map = NULL, g_vrr_maps[i].w = g_vrr_maps[i].h = 0;
    vrr_forget_full();   // KL_VRR_PHYS: a new physical size; every texture gets one full-area pass again
    fprintf(stderr, "[vrr] settings changed: maps rebuilt on the next frame\n");
}
void *kl_vrr_map_for(int w, int h) {
    if (g_vrr_on <= 0) return NULL;
    for (int i = 0; i < 8; i++)
        if (g_vrr_maps[i].map && (int)g_vrr_maps[i].w == w && (int)g_vrr_maps[i].h == h) return g_vrr_maps[i].map;
    return NULL;
}
void *kl_vrr_grid_ctx(int eye, void *map, float tex_h) {
    if (g_vrr_on < 0) { const char *v = getenv("KL_VRR"); g_vrr_on = v && *v == '1'; }
    if (g_vrr_on <= 0 || !map || eye < 0 || eye > 1) return NULL;
    id<MTLRasterizationRateMap> m = (__bridge id<MTLRasterizationRateMap>)map;
    g_vrr_ctx[eye].map = map;
    g_vrr_ctx[eye].layer = m.layerCount > 1 ? (unsigned)eye : 0;
    g_vrr_ctx[eye].scr_h = (float)m.screenSize.height;
    g_vrr_ctx[eye].tex_h = tex_h;
    return &g_vrr_ctx[eye];
}

// ---- Render area of the foveated passes (KL_VRR_PHYS=1; KL_VRR_PHYS_POST=1) -------------------------------------
// With a rasterization rate map Metal rasterizes into the map's PHYSICAL size (top-left of the attachments) while
// viewports and scissors stay in screen (logical) coordinates: Apple's own model, where the drawable textures are the
// physical size (CompositorServices' drawables and views' viewports, "Rendering with a rasterization rate map").
// The render target size is in physical pixels: VPKEngine sets it to the game's render area (the full eye size,
// 2784x2208 at 90 %), so every tile of that area was still cleared, loaded, stored and resolved although only the
// physical part (1536x1428 with the M2 map: 36 %) is ever drawn or read back (the compositor unwarps that part only).
// KL_VRR_PHYS=1 constrains the render target of every foveated pass (MSAA scene, 1x overlays with depth) to the
// map's physical size: the MSAA resolve, the depth resolve and the overlay pass's loads and stores shrink to it.
// Viewports, scissors and the map are untouched (logical, as before). Outside the physical part the textures are then
// no longer written every frame, but the unfoveated post passes (bloom, exposure) still read the whole texture: what
// lies there must stay what it is today (the clear colour, resolved), not whatever the memory held at allocation
// (VPKEngine gives each Vulkan image its own Metal texture, no aliasing, but Metal does not zero new textures). So the
// FIRST foveated pass that touches a texture keeps the full area (its clear and resolve fill the outside once) and
// only later passes on known textures are constrained (vrr_textures_known: a weak set, so a texture the game frees
// and re-creates, e.g. at a fidelity change, gets its full pass again).
// KL_VRR_PHYS_POST=1 (A/B, off by default) does the same for the unfoveated eye-sized layered 1x passes without depth
// (fullscreen post: tonemap and the like), which carry the physical layout texel for texel: there the viewport and
// scissor are larger than the render target WITHOUT a rate map, which Metal's validation calls an error (the GPU
// clips to the render target), hence opt-in until a run shows the picture intact.
static int g_vrr_phys = -1, g_vrr_phys_post = -1;
static void vrr_phys_env(void) {
    if (g_vrr_phys >= 0) return;
    const char *e = getenv("KL_VRR_PHYS");
    g_vrr_phys = e && *e == '1';
    e = getenv("KL_VRR_PHYS_POST");
    g_vrr_phys_post = e && *e == '1';
    fprintf(stderr, "[vrr] render area of foveated passes = the map's physical size: %s; unfoveated eye post passes: %s\n",
            g_vrr_phys ? "on (KL_VRR_PHYS)" : "off", g_vrr_phys_post ? "on (KL_VRR_PHYS_POST)" : "off");
}
// The largest physical size over the map's layers (the eyes' maps differ: their axes are off-centre on opposite sides).
static MTLSize vrr_phys_size(id<MTLRasterizationRateMap> m) {
    MTLSize p = [m physicalSizeForLayer:0];
    for (NSUInteger l = 1; l < m.layerCount && l < 2; l++) {
        MTLSize q = [m physicalSizeForLayer:l];
        if (q.width > p.width) p.width = q.width;
        if (q.height > p.height) p.height = q.height;
    }
    return p;
}
// 1 when every texture the pass writes or loads (attachments and resolve targets; a view counts as its parent;
// memoryless ones hold nothing) has had one full-area foveated pass already; otherwise records them and returns 0.
static NSHashTable *g_vrr_full_done;   // weak: entries vanish when the game frees the texture
static os_unfair_lock g_vrr_full_lk = OS_UNFAIR_LOCK_INIT;
static unsigned g_vrr_full_passes;
static int vrr_textures_known(MTLRenderPassDescriptor *d) {
    id<MTLTexture> ts[20];
    int n = 0;
    for (int i = 0; i < 8; i++) { ts[n++] = d.colorAttachments[i].texture; ts[n++] = d.colorAttachments[i].resolveTexture; }
    ts[n++] = d.depthAttachment.texture; ts[n++] = d.depthAttachment.resolveTexture;
    ts[n++] = d.stencilAttachment.texture; ts[n++] = d.stencilAttachment.resolveTexture;
    int known = 1;
    os_unfair_lock_lock(&g_vrr_full_lk);
    // alloc/init: owned (libklepton builds this file without ARC, where weakObjectsHashTable would be autoreleased)
    if (!g_vrr_full_done) g_vrr_full_done = [[NSHashTable alloc] initWithOptions:NSPointerFunctionsWeakMemory capacity:16];
    for (int i = 0; i < n; i++) {
        id<MTLTexture> t = ts[i];
        if (!t || t.storageMode == MTLStorageModeMemoryless) continue;
        if (t.parentTexture) t = t.parentTexture;
        if (![g_vrr_full_done containsObject:t]) { known = 0; [g_vrr_full_done addObject:t]; }
    }
    if (!known) g_vrr_full_passes++;
    os_unfair_lock_unlock(&g_vrr_full_lk);
    return known;
}
static void vrr_forget_full(void) {
    os_unfair_lock_lock(&g_vrr_full_lk);
    [g_vrr_full_done removeAllObjects];
    os_unfair_lock_unlock(&g_vrr_full_lk);
}
// Constrain the pass's render target (screen size w x h) to the map's physical size; only ever shrinks it.
static void vrr_constrain(MTLRenderPassDescriptor *d, id<MTLRasterizationRateMap> m, NSUInteger w, NSUInteger h, int post) {
    // KL_VK_MERGE (MoltenVK diagnostics) compares render target sizes to merge resumed chunks: leave them alone.
    if (g_merge > 0) return;
    MTLSize p = vrr_phys_size(m);
    if (!p.width || !p.height || p.width > w || p.height > h || (p.width == w && p.height == h)) return;
    if (!vrr_textures_known(d)) {   // its first pass: full area, so the outside holds what it always did
        if (g_vrr_full_passes <= 8 || g_vrr_full_passes % 100 == 0)
            fprintf(stderr, "[vrr] full-area first pass on new texture(s) (%u so far), physical area from the next one\n",
                    g_vrr_full_passes);
        return;
    }
    d.renderTargetWidth = p.width;
    d.renderTargetHeight = p.height;
    static int said[2];
    if (said[post] < 3) {
        said[post]++;
        id<MTLTexture> t = d.colorAttachments[0].texture ? d.colorAttachments[0].texture : d.depthAttachment.texture;
        fprintf(stderr, "[vrr] %s pass (fmt %lu x%lu, %lu layer(s)): render area %lux%lu -> %lux%lu (%.0f%% of the tiles)\n",
                post ? "unfoveated post" : "foveated", t ? (unsigned long)t.pixelFormat : 0ul,
                t ? (unsigned long)t.sampleCount : 0ul, (unsigned long)d.renderTargetArrayLength, (unsigned long)w,
                (unsigned long)h, (unsigned long)p.width, (unsigned long)p.height, 100.0 * p.width * p.height / ((double)w * h));
    }
}
// The foveated map already built for this screen size (the scene pass builds it earlier in the frame), or nil.
static id<MTLRasterizationRateMap> vrr_map_cached(NSUInteger w, NSUInteger h, NSUInteger layers) {
    for (int i = 0; i < 8; i++)
        if (g_vrr_maps[i].map && g_vrr_maps[i].w == w && g_vrr_maps[i].h == h && g_vrr_maps[i].layers == layers)
            return (__bridge id<MTLRasterizationRateMap>)g_vrr_maps[i].map;
    return nil;
}

// KL_VK_MERGE_VIS=1 (with KL_VK_MERGE): the scene's first chunk issues no occlusion queries and so gets no
// visibility-result buffer, while the chunk that resumes it does; Metal fixes that buffer per encoder, so the two
// could not merge and the first had to store its 4x samples for the second to load back. The buffer a resumed MSAA
// scene chunk brought (retained) is attached to the next first chunk on the same attachments up front: with no
// visibility mode set, the first chunk writes nothing to it. A different buffer next time just means no merge.
static int g_merge_vis = -1;
static void *g_vis_tex0, *g_vis_buf;
static unsigned g_vis_given, g_vis_seen;

// ---- The compositor's exclusive GPU time (build 36) ---------------------------------------------------------------
// Every render encoder on the compositor's queue (role 1: the composite, the eye prep's FXAA/sharpen passes, the
// panel clear) gets four stage-boundary timestamps in a sample buffer of our own, at the first free attachment index.
// When its command buffer completes, the encoders are placed on one timeline and the buffer's exclusive time is what
// they add past the latest end seen (the same rule as VPVulkan's and [passes]'), so a composite that ran alongside
// the game's encoders is not charged the game's time. Its blit encoders (eye mips, captures) are not timed: a
// compositor buffer without render encoders counts as 0. GPU ticks are calibrated against the CPU clock every 20 s.
enum { kCxSamples = 1024, kCxCbs = 32, kCxPerCb = 24 };
static id<MTLCounterSampleBuffer> g_cx_buf;
static int g_cx_failed;                      // no sample buffer / no stage sampling: compositor stays on the union
static unsigned g_cx_next;                   // next free sample index (a ring: 256 encoders in flight at most)
static struct { void *cb; uint32_t idx[kCxPerCb]; int n, tainted; } g_cx_cbs[kCxCbs];   // tainted: an encoder went untimed
static uint64_t g_cx_last_end;               // GPU ticks: the latest encoder end placed on the timeline
static MTLTimestamp g_cx_cpu0, g_cx_gpu0;    // calibration: ticks -> ns
static double g_cx_ns_per_tick, g_cx_cal_at;
static unsigned g_cx_attached, g_cx_resolved, g_cx_bad;
static os_unfair_lock g_cx_lk = OS_UNFAIR_LOCK_INIT;

// The calibration pair: taken at creation, then the ratio from a second pair at least 1 s later, redone every 20 s.
static void cx_calibrate(id<MTLDevice> dev) {
    double now = CACurrentMediaTime();
    MTLTimestamp cpu, gpu;
    if (!g_cx_cal_at) { [dev sampleTimestamps:&g_cx_cpu0 gpuTimestamp:&g_cx_gpu0]; g_cx_cal_at = now; return; }
    if (now - g_cx_cal_at < (g_cx_ns_per_tick > 0 ? 20.0 : 1.0)) return;
    [dev sampleTimestamps:&cpu gpuTimestamp:&gpu];
    // The CPU side is taken as ns, as VPVulkan's calibrate() does (its gpu.excl figures agree with [passes]); the
    // [passes] window applies the mach timebase and then has to fall back to raw ns by a range check. cx_resolve
    // checks the result against the buffer's own GPU span and drops the sample when the scale is off.
    double cpu_ns = (double)(cpu - g_cx_cpu0);
    if (gpu > g_cx_gpu0 && cpu_ns > 0) {
        double r = cpu_ns / (double)(gpu - g_cx_gpu0);
        if (g_cx_ns_per_tick <= 0)
            fprintf(stderr, "[gputime] compositor timestamps calibrated: %.4f ns per GPU tick\n", r);
        g_cx_ns_per_tick = r;
    }
    g_cx_cpu0 = cpu; g_cx_gpu0 = gpu; g_cx_cal_at = now;
}
// Attach our samples to a compositor render pass about to open; returns the attachment index used (or -1) and the
// first of its 4 sample indices.
static int cx_attach(id<MTLCommandBuffer> cb, MTLRenderPassDescriptor *d, unsigned *i0) {
    if (g_cx_failed || g_excl_on <= 0) return -1;
    int slot = 0;
    while (slot < kProfSampleSlots && d.sampleBufferAttachments[slot].sampleBuffer) slot++;
    os_unfair_lock_lock(&g_cx_lk);
    if (!g_cx_buf) {
        id<MTLDevice> dev = cb.device;
        id<MTLCounterSet> ts = nil;
        for (id<MTLCounterSet> c in dev.counterSets) if ([c.name isEqualToString:MTLCommonCounterSetTimestamp]) ts = c;
        if (!ts || ![dev supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) {
            g_cx_failed = 1;
            fprintf(stderr, "[gputime] no stage-boundary timestamps: the compositor's GPU time stays the union\n");
        } else {
            MTLCounterSampleBufferDescriptor *bd = [MTLCounterSampleBufferDescriptor new];
            bd.counterSet = ts; bd.storageMode = MTLStorageModeShared; bd.sampleCount = kCxSamples;
            NSError *err = nil;
            g_cx_buf = [dev newCounterSampleBufferWithDescriptor:bd error:&err];
            if (!g_cx_buf) {
                g_cx_failed = 1;
                fprintf(stderr, "[gputime] no counter sample buffer for the compositor: %s\n", err.localizedDescription.UTF8String ?: "?");
            } else cx_calibrate(dev);
        }
        if (g_cx_failed) { os_unfair_lock_unlock(&g_cx_lk); return -1; }
    }
    void *key = (__bridge void *)cb;
    int e = -1, free_e = -1;
    for (int i = 0; i < kCxCbs; i++) {
        if (g_cx_cbs[i].cb == key) { e = i; break; }
        if (!g_cx_cbs[i].cb && free_e < 0) free_e = i;
    }
    if (e < 0) {
        if (free_e < 0) { os_unfair_lock_unlock(&g_cx_lk); return -1; }   // 32 compositor buffers in flight: never
        e = free_e; g_cx_cbs[e].cb = key; g_cx_cbs[e].n = 0; g_cx_cbs[e].tainted = 0;
    }
    // An encoder this buffer cannot have timed (no free attachment index, 24 already): the buffer's figure would
    // be an under-count presented as exclusive, so it is marked and reported as a miss (the union stands in).
    if (slot == kProfSampleSlots || g_cx_cbs[e].n == kCxPerCb) { g_cx_cbs[e].tainted = 1; os_unfair_lock_unlock(&g_cx_lk); return -1; }
    *i0 = g_cx_next;
    g_cx_next = (g_cx_next + 4) % kCxSamples;
    g_cx_cbs[e].idx[g_cx_cbs[e].n++] = *i0;
    g_cx_attached++;
    os_unfair_lock_unlock(&g_cx_lk);
    MTLRenderPassSampleBufferAttachmentDescriptor *a = d.sampleBufferAttachments[slot];
    a.sampleBuffer = g_cx_buf;
    a.startOfVertexSampleIndex = *i0;
    a.endOfVertexSampleIndex = *i0 + 1;
    a.startOfFragmentSampleIndex = *i0 + 2;
    a.endOfFragmentSampleIndex = *i0 + 3;
    return slot;
}
// Metal would not open the encoder with our attachment: drop it (and the feature for the session) and let the caller retry.
static void cx_detach(MTLRenderPassDescriptor *d, int slot, unsigned i0) {
    d.sampleBufferAttachments[slot].sampleBuffer = nil;
    os_unfair_lock_lock(&g_cx_lk);
    for (int i = 0; i < kCxCbs; i++)
        for (int j = 0; j < g_cx_cbs[i].n; j++)
            if (g_cx_cbs[i].idx[j] == i0) { g_cx_cbs[i].idx[j] = g_cx_cbs[i].idx[--g_cx_cbs[i].n]; }
    if (!g_cx_failed) {
        g_cx_failed = 1;
        fprintf(stderr, "[gputime] Metal refused a compositor encoder with our sample buffer: compositor GPU time stays the union\n");
    }
    os_unfair_lock_unlock(&g_cx_lk);
}
// Completed compositor buffer: its encoders' exclusive ms on the timeline; 0 for a buffer we timed nothing in,
// -1 when a sample came back broken or the ticks are not calibrated yet (the union stands in).
static double cx_resolve(void *cb, double span_ms) {
    if (g_cx_failed) return -1;    // the union stands in for the whole session
    if (!g_cx_buf) return 0;       // no render pass of the compositor's has opened yet: nothing to time
    uint32_t idx[kCxPerCb];
    int n = 0, tainted = 0;
    os_unfair_lock_lock(&g_cx_lk);
    for (int i = 0; i < kCxCbs; i++)
        if (g_cx_cbs[i].cb == cb) {
            n = g_cx_cbs[i].n; tainted = g_cx_cbs[i].tainted;
            memcpy(idx, g_cx_cbs[i].idx, n * sizeof idx[0]);
            g_cx_cbs[i].cb = NULL; g_cx_cbs[i].n = 0; g_cx_cbs[i].tainted = 0;
            break;
        }
    os_unfair_lock_unlock(&g_cx_lk);
    if (tainted) return -1;
    if (!n) return 0;
    double ms = 0;
    os_unfair_lock_lock(&g_cx_lk);
    cx_calibrate(g_cx_buf.device);
    int ok = g_cx_ns_per_tick > 0;
    for (int j = 0; j < n && ok; j++) {
        MTLCounterResultTimestamp r[4];
        @autoreleasepool {   // a completion handler's thread: the resolved NSData must not outlive this
            NSData *part = [g_cx_buf resolveCounterRange:NSMakeRange(idx[j], 4)];
            if (!part || part.length < sizeof r) { ok = 0; break; }
            memcpy(r, part.bytes, sizeof r);
        }
        uint64_t v0 = r[0].timestamp, v1 = r[1].timestamp, f0 = r[2].timestamp, f1 = r[3].timestamp;
        uint64_t start = v0 != MTLCounterErrorValue ? v0 : 0, end = f1 != MTLCounterErrorValue ? f1 : 0;
        if (f0 != MTLCounterErrorValue && f0 && (!start || f0 < start)) start = f0;   // no vertex work
        if (!end && v1 != MTLCounterErrorValue) end = v1;
        if (!start || !end || end < start) { ok = 0; break; }
        uint64_t from = start > g_cx_last_end ? start : g_cx_last_end;
        if (end > from) ms += (double)(end - from) * g_cx_ns_per_tick / 1e6;
        if (end > g_cx_last_end) g_cx_last_end = end;
    }
    // The scale check: a buffer's exclusive time cannot exceed its own GPU span by more than the overlap between
    // its encoders allows (a little); far past it, the tick unit is wrong and the figure is dropped.
    if (ok && span_ms > 0 && ms > 1.5 * span_ms + 0.5) {
        static int said;
        if (said++ < 3)
            fprintf(stderr, "[gputime] compositor exclusive %.2f ms exceeds the buffer's span %.2f ms: tick scale %.4f looks wrong, sample dropped\n",
                    ms, span_ms, g_cx_ns_per_tick);
        ok = 0;
    }
    if (ok) g_cx_resolved++; else g_cx_bad++;
    os_unfair_lock_unlock(&g_cx_lk);
    return ok ? ms : -1;
}

static id kl_rce(id self, SEL sel, MTLRenderPassDescriptor *d) {
    if (g_merge > 0 && d) {
        if (g_merge_vis < 0) { const char *e = getenv("KL_VK_MERGE_VIS"); g_merge_vis = e && *e == '1';
                               if (g_merge_vis) fprintf(stderr, "[merge] carrying the scene's visibility buffer into its first chunk (KL_VK_MERGE_VIS)\n"); }
        if (g_merge_vis > 0 && !d.visibilityResultBuffer && g_vis_buf && d.colorAttachments[0].texture &&
            d.colorAttachments[0].texture.sampleCount > 1 && (__bridge void *)d.colorAttachments[0].texture == g_vis_tex0) {
            d.visibilityResultBuffer = (__bridge id<MTLBuffer>)g_vis_buf;
            if (g_vis_given++ % 2000 == 0) fprintf(stderr, "[merge] visibility buffer given to %u first chunks (%u seen)\n", g_vis_given, g_vis_seen);
        }
        void *cb = (__bridge void *)self;
        os_unfair_lock_lock(&g_mg_lk);
        kl_merge_t *m = mg_held_on(cb);
        if (m && mg_continues(m, d)) {
            m->held = 0;
            g_merged++;
            id enc = (__bridge id)m->enc;
            os_unfair_lock_unlock(&g_mg_lk);
            if (g_merged % 2000 == 1) fprintf(stderr, "[merge] %u resumed passes merged, %u real ends\n", g_merged, g_flushed);
            return enc;
        }
        if (g_merge_vis > 0 && m && d.visibilityResultBuffer && m->vis != (__bridge void *)d.visibilityResultBuffer &&
            d.colorAttachments[0].texture && d.colorAttachments[0].texture.sampleCount > 1 &&
            (__bridge void *)d.colorAttachments[0].texture == m->tex[0]) {
            void *nb = (__bridge void *)d.visibilityResultBuffer;
            g_vis_seen++;
            if (nb != g_vis_buf) {   // remember it for the next frame's first chunk
                if (g_vis_buf) CFRelease(g_vis_buf);
                g_vis_buf = (void *)CFBridgingRetain(d.visibilityResultBuffer);
                g_vis_tex0 = m->tex[0];
                if (g_vis_seen < 8) fprintf(stderr, "[merge] scene visibility buffer %p (seen %u)\n", nb, g_vis_seen);
            }
        }
        {   // why not (the first few): a held pass on another command buffer, or a different descriptor
            static int said;
            if (said < 6 && d.colorAttachments[0].texture && d.colorAttachments[0].texture.sampleCount > 1) {
                int other = 0;
                for (int i = 0; i < kMergeMax; i++) if (g_mg[i].enc && g_mg[i].held && g_mg[i].cb != cb) other = 1;
                if (m || other) {
                    said++;
                    char why[160] = "";
                    if (m) {
                        kl_merge_t n; memset(&n, 0, sizeof n); mg_fill(&n, d);
                        for (int i = 0; i < 10 && !why[0]; i++)
                            if (n.tex[i] != m->tex[i] || n.res[i] != m->res[i] || n.slice[i] != m->slice[i] || n.level[i] != m->level[i])
                                snprintf(why, sizeof why, "attachment %d: tex %p/%p res %p/%p slice %lu/%lu", i, m->tex[i], n.tex[i],
                                         m->res[i], n.res[i], (unsigned long)m->slice[i], (unsigned long)n.slice[i]);
                        if (!why[0]) snprintf(why, sizeof why, "size %lux%lu/%lux%lu layers %lu/%lu vis %p/%p rrm %p",
                                              (unsigned long)m->w, (unsigned long)m->h, (unsigned long)n.w, (unsigned long)n.h,
                                              (unsigned long)m->layers, (unsigned long)n.layers, m->vis,
                                              (__bridge void *)d.visibilityResultBuffer, (__bridge void *)d.rasterizationRateMap);
                    }
                    fprintf(stderr, "[merge] not merged: %s (load c0 %lu z %lu) %s\n",
                            m ? "held pass on this command buffer does not match" : "held pass is on another command buffer",
                            (unsigned long)d.colorAttachments[0].loadAction, (unsigned long)d.depthAttachment.loadAction, why);
                }
            }
        }
        os_unfair_lock_unlock(&g_mg_lk);
        mg_flush_why(cb, "a render pass that does not continue it");
    }
    if ((g_vrr_mode > 0 || g_vrr_on > 0) && d) {
        id<MTLCommandBuffer> cb = (id<MTLCommandBuffer>)self;
        void *q = (__bridge void *)[cb commandQueue];
        os_unfair_lock_lock(&g_lk);
        int role = watched(q);
        uint32_t f = g_frame;
        os_unfair_lock_unlock(&g_lk);
        if (role == 0 && g_vrr_mode == 1 && f == g_vrr_at) vrr_census(d, f);
        // KL_VRR_SPIKE_TOGGLE=s: inject for s seconds, then leave the passes alone for s seconds, and so
        // on, so one run gives both sides of the A/B on the same scene ([vrr] logs each switch).
        int on = 1;
        if (g_vrr_mode == 2 && g_vrr_toggle > 0) {
            on = ((long)(CACurrentMediaTime() / g_vrr_toggle)) % 2 == 0;
            static int was = -1;
            if (on != was) {
                was = on;
                time_t tt = time(NULL);
                struct tm lt;
                localtime_r(&tt, &lt);
                fprintf(stderr, "[vrr] %02d:%02d:%02d inject %s\n", lt.tm_hour, lt.tm_min, lt.tm_sec, on ? "on" : "off");
            }
        }
        if (role == 0 && g_vrr_on > 0 && !d.rasterizationRateMap) {
            id<MTLTexture> t = d.colorAttachments[0].texture ? d.colorAttachments[0].texture : d.depthAttachment.texture;
            // Besides the MSAA scene passes, every eye-sized LAYERED pass with a depth attachment at 1x: Source 2
            // draws its 3D overlays (the menu panels, the hands, world UI) after the resolve, into the 1x eye image
            // with the resolved depth (build 24 dump, pass 61: 112 draws on the RGBA8 sRGB eye texture). Left out
            // they were drawn in screen space onto a foveated picture: the left eye's menu squeezed into a corner,
            // different in each eye. Post passes (tonemap, bloom: fullscreen, no depth) stay unfoveated: they read
            // and write texel for texel, which carries the foveated layout through. Shadow maps are not layered;
            // the motion-vector target (RG16F) is left alone.
            id<MTLTexture> dt = d.depthAttachment.texture;
            id<MTLTexture> ct = d.colorAttachments[0].texture;
            int scene1x = dt && dt.width >= 1024 && d.renderTargetArrayLength == 2 &&   // two eyes, not a cascade
                          (dt.textureType == MTLTextureType2DArray || dt.textureType == MTLTextureType2DMultisampleArray) &&
                          (!ct || ct.pixelFormat != MTLPixelFormatRG16Float);
            // Build 36: the VR subtitles (cc_vr_*) are one quad in a pass of their own after the post chain: the eye
            // image's sRGB view, two layers, 1x, loaded, and NO depth attachment (cc_vr_depth_test 0). Left out, the
            // quad was drawn in screen space over the foveated layout, which the compositor then unwarped (Logs_Alyx 2_10:
            // left eye past the physical area, cut and doubled; right eye sheared). The texel-for-texel post passes
            // (tonemap, bloom composite) write the UNORM view (fmt 70) or HDR formats; nothing draws 3D into the sRGB
            // view without depth but this. KL_VRR_SRGB_1X=0 restores the old behaviour (A/B).
            static int srgb1x_on = -1;
            if (srgb1x_on < 0) { const char *e = getenv("KL_VRR_SRGB_1X"); srgb1x_on = !(e && *e == '0'); }
            int srgb1x = srgb1x_on > 0 && !dt && ct && ct.sampleCount == 1 && ct.width >= 1024 && d.renderTargetArrayLength == 2 &&
                         (ct.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB || ct.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB) &&
                         d.colorAttachments[0].loadAction == MTLLoadActionLoad;
            if (t && (t.sampleCount >= 4 || scene1x || srgb1x) && t.width >= 1024) {
                static int said1x, saidSrgb;
                if (scene1x && t.sampleCount < 4 && said1x < 4) {
                    said1x++;
                    fprintf(stderr, "[vrr] foveating a 1x layered pass with depth (overlays after the resolve): colour fmt %lu, "
                            "depth fmt %lu, %lux%lu x%lu, load %lu\n", ct ? (unsigned long)ct.pixelFormat : 0ul,
                            (unsigned long)dt.pixelFormat, (unsigned long)t.width, (unsigned long)t.height,
                            (unsigned long)d.renderTargetArrayLength, (unsigned long)d.colorAttachments[0].loadAction);
                }
                if (srgb1x && saidSrgb < 4) {
                    saidSrgb++;
                    fprintf(stderr, "[vrr] foveating a 1x layered pass without depth on the sRGB eye view (subtitles): "
                            "colour fmt %lu, %lux%lu x%lu, store %lu (frame %u)\n", (unsigned long)ct.pixelFormat,
                            (unsigned long)t.width, (unsigned long)t.height, (unsigned long)d.renderTargetArrayLength,
                            (unsigned long)d.colorAttachments[0].storeAction, f);
                }
                NSUInteger layers = d.renderTargetArrayLength > 1 ? d.renderTargetArrayLength : 1;
                NSUInteger w = d.renderTargetWidth ? d.renderTargetWidth : t.width;
                NSUInteger h = d.renderTargetHeight ? d.renderTargetHeight : t.height;
                id<MTLRasterizationRateMap> map = vrr_fov_map(cb.device, w, h, layers);
                if (map) {
                    d.rasterizationRateMap = map;
                    vrr_phys_env();
                    if (g_vrr_phys > 0) vrr_constrain(d, map, w, h, 0);
                    static void *published;
                    if ((__bridge void *)map != published) {   // the compositor unwarps the eye image with it
                        published = (__bridge void *)map;
                        int zones = kVrrZones;   // the zone count this map was built with
                        for (int i = 0; i < 8; i++)
                            if (g_vrr_maps[i].map == published && g_vrr_maps[i].zones > 0) zones = g_vrr_maps[i].zones;
                        kl_glfb_publish_eye_rate_map(published, zones, zones);
                    }
                }
            } else if (t && t.width >= 1024 && d.renderTargetArrayLength > 1) {
                // Measurement: eye-sized layered passes left unfoveated (expected: the fullscreen post passes only).
                NSUInteger w = d.renderTargetWidth ? d.renderTargetWidth : t.width;
                NSUInteger h = d.renderTargetHeight ? d.renderTargetHeight : t.height;
                static int saidNot;
                if (saidNot < 6) {
                    saidNot++;
                    fprintf(stderr, "[vrr] eye-sized layered pass NOT foveated: colour fmt %lu x%lu samples, depth %s, load %lu, "
                            "store %lu, area %lux%lu x%lu (frame %u)\n", ct ? (unsigned long)ct.pixelFormat : 0ul,
                            (unsigned long)t.sampleCount, dt ? "yes" : "no", (unsigned long)d.colorAttachments[0].loadAction,
                            (unsigned long)d.colorAttachments[0].storeAction, (unsigned long)w, (unsigned long)h,
                            (unsigned long)d.renderTargetArrayLength, f);
                }
                vrr_phys_env();
                if (g_vrr_phys_post > 0 && t.sampleCount == 1 && !dt && d.renderTargetArrayLength == 2) {
                    id<MTLRasterizationRateMap> m = vrr_map_cached(w, h, 2);
                    if (m) vrr_constrain(d, m, w, h, 1);
                }
            }
        }
        if (role == 0 && g_vrr_mode == 2 && on && !d.rasterizationRateMap) {
            id<MTLTexture> t = d.colorAttachments[0].texture ? d.colorAttachments[0].texture : d.depthAttachment.texture;
            if (t && t.sampleCount >= 4 && t.width >= 1024) {
                NSUInteger layers = d.renderTargetArrayLength > 1 ? d.renderTargetArrayLength : 1;
                // The map covers the render area (the eye textures are allocated at the largest
                // fidelity level's size and rendered in their top-left corner).
                NSUInteger w = d.renderTargetWidth ? d.renderTargetWidth : t.width;
                NSUInteger h = d.renderTargetHeight ? d.renderTargetHeight : t.height;
                id<MTLRasterizationRateMap> map = vrr_map(cb.device, w, h, layers);
                if (map) {
                    d.rasterizationRateMap = map;
                    if (g_vrr_injected++ % 5000 == 0)
                        fprintf(stderr, "[vrr] %u scene passes given the rate map so far\n", g_vrr_injected);
                }
            }
        }
    }
    int prof_slot = -1, prof_k = -1;   // our sample attachment on this pass, if any (undone if Metal refuses it)
    if (g_prof > 0 && d && !g_prof_refused) {
        int role; uint32_t f = prof_frame_of((id<MTLCommandBuffer>)self, &role);
        if (role == 0 && prof_in(f)) {
            // Our samples go to the first free attachment: VPKEngine's own (index 0) stay intact.
            int slot = 0;
            while (slot < kProfSampleSlots && d.sampleBufferAttachments[slot].sampleBuffer) slot++;
            if (slot == kProfSampleSlots) g_prof_noslot++;
            // Two adjacent pairs: k for the pass, k + 1 for the vertex stage's end and the fragment stage's start
            // (used only when both sit in the same sample buffer).
            int k = slot < kProfSampleSlots ? prof_pair((id<MTLCommandBuffer>)self, f, prof_kind_render(d), 1) : -1;
            int k2 = k >= 0 && prof_buf(k + 1) == prof_buf(k) ? k + 1 : -1;
            if (k >= 0) {
                // After the foveation hook above: the signature shows the rate map ("vrr") and the render area used.
                prof_sig_render(d, g_prof_meta[k].sig, sizeof g_prof_meta[k].sig);
                MTLRenderPassSampleBufferAttachmentDescriptor *a = d.sampleBufferAttachments[slot];
                a.sampleBuffer = prof_buf(k);
                a.startOfVertexSampleIndex = prof_idx(k);
                a.endOfVertexSampleIndex = k2 >= 0 ? prof_idx(k2) : MTLCounterDontSample;
                a.startOfFragmentSampleIndex = k2 >= 0 ? prof_idx(k2) + 1 : MTLCounterDontSample;
                a.endOfFragmentSampleIndex = prof_idx(k) + 1;
                if (k2 >= 0) snprintf(g_prof_meta[k2].sig, sizeof g_prof_meta[k2].sig, "~stages of %d", k);
                prof_slot = slot; prof_k = k;
            }
        }
    }
    // The compositor's passes (role 1): our timestamps for its exclusive GPU time (build 36).
    int cx_slot = -1;
    unsigned cx_i0 = 0;
    if (d && g_excl_on > 0 && !g_cx_failed) {
        int role; (void)prof_frame_of((id<MTLCommandBuffer>)self, &role);
        if (role == 1) cx_slot = cx_attach((id<MTLCommandBuffer>)self, d, &cx_i0);
    }
    ml_guard(d);
    id enc = ((id (*)(id, SEL, MTLRenderPassDescriptor *))g_rce)(self, sel, d);
    if (!enc && prof_slot >= 0) {   // no encoder with our sample buffer attached: drop it, and profiling, and retry
        d.sampleBufferAttachments[prof_slot].sampleBuffer = nil;
        prof_refused(prof_k, "render");
        enc = ((id (*)(id, SEL, MTLRenderPassDescriptor *))g_rce)(self, sel, d);
    }
    if (!enc && cx_slot >= 0) {
        cx_detach(d, cx_slot, cx_i0);
        enc = ((id (*)(id, SEL, MTLRenderPassDescriptor *))g_rce)(self, sel, d);
    }
    if (g_snap_at && !g_snap_done && enc && d) {
        int role; uint32_t f = prof_frame_of((id<MTLCommandBuffer>)self, &role);
        if (role == 0) snap_note((id<MTLCommandBuffer>)self, d, f);
    }
    if (g_merge > 0 && enc && d && d.colorAttachments[0].texture && d.colorAttachments[0].texture.sampleCount > 1) {
        int role; (void)prof_frame_of((id<MTLCommandBuffer>)self, &role);
        if (role == 0) {
            static int hooked;
            if (!hooked) {   // the render encoder class: endEncoding and the store actions
                hooked = 1;
                Class ec = object_getClass(enc);
                hook(ec, @selector(endEncoding), (IMP)kl_end, &g_end);
                hook(ec, @selector(setColorStoreAction:atIndex:), (IMP)kl_scsa, &g_scsa);
                hook(ec, @selector(setDepthStoreAction:), (IMP)kl_sdsa, &g_sdsa);
                hook(ec, @selector(setStencilStoreAction:), (IMP)kl_sssa, &g_sssa);
                hook(ec, @selector(setColorStoreActionOptions:atIndex:), (IMP)kl_scso, &g_scso);
                hook(ec, @selector(setDepthStoreActionOptions:), (IMP)kl_sdso, &g_sdso);
                hook(ec, @selector(setStencilStoreActionOptions:), (IMP)kl_ssso, &g_ssso);
                fprintf(stderr, "[merge] deferring the end of MSAA scene encoders (%s)\n", class_getName(ec));
            }
            os_unfair_lock_lock(&g_mg_lk);
            for (int i = 0; i < kMergeMax; i++)
                if (!g_mg[i].enc) {
                    memset(&g_mg[i], 0, sizeof g_mg[i]);
                    g_mg[i].enc = (void *)CFBridgingRetain(enc);
                    g_mg[i].cb = (__bridge void *)self;
                    mg_fill(&g_mg[i], d);
                    break;
                }
            os_unfair_lock_unlock(&g_mg_lk);
        }
    }
    return enc;
}

static void hook(Class c, SEL s, IMP mine, IMP *orig) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) { fprintf(stderr, "[gputime] %s has no %s\n", class_getName(c), sel_getName(s)); return; }
    *orig = method_getImplementation(m);
    if (!class_addMethod(c, s, mine, method_getTypeEncoding(m))) method_setImplementation(m, mine);
}

static void vrr_install(Class c) {
    const char *vr = getenv("KL_VRR");
    g_vrr_on = vr && *vr == '1';
    if (g_vrr_on) fprintf(stderr, "[vrr] foveated scene passes on (KL_VRR=1)\n");
    const char *sn = getenv("KL_GPU_SNAP");
    if (sn && *sn) {
        g_snap_at = (uint32_t)atoi(sn);
        const char *colon = strchr(sn, ':');
        snprintf(g_snap_path, sizeof g_snap_path, "%s", colon ? colon + 1 : "kl-snap.ppm");
        const char *sn_n = getenv("KL_GPU_SNAP_N"), *sn_e = getenv("KL_GPU_SNAP_EVERY");
        if (sn_n && atoi(sn_n) > 0) g_snap_n = (uint32_t)atoi(sn_n);
        if (sn_e && atoi(sn_e) > 0) g_snap_every = (uint32_t)atoi(sn_e);
    }
    const char *mg = getenv("KL_VK_MERGE");
    g_merge = mg && *mg == '1';
    if (g_merge) {
        hook(c, @selector(computeCommandEncoderWithDispatchType:), (IMP)kl_m_cce, &g_m_cce);
        hook(c, @selector(blitCommandEncoder), (IMP)kl_m_bce, &g_m_bce);
        hook(c, @selector(blitCommandEncoderWithDescriptor:), (IMP)kl_m_bced, &g_m_bced);
        hook(c, @selector(computeCommandEncoderWithDescriptor:), (IMP)kl_m_cced, &g_m_cced);
        hook(c, @selector(encodeSignalEvent:value:), (IMP)kl_m_sig, &g_m_sig);
        hook(c, @selector(encodeWaitForEvent:value:), (IMP)kl_m_wait, &g_m_wait);
        fprintf(stderr, "[merge] on (KL_VK_MERGE)\n");
    }
    const char *pp = getenv("KL_GPU_PASSES");
    g_prof = pp && *pp ? 1 : 0;
    if (g_prof) {
        const char *pn = getenv("KL_GPU_PASSES_N");
        if (pn && atoi(pn) > 0) g_prof_n = (uint32_t)atoi(pn);
        int nf = 0;
        os_unfair_lock_lock(&g_prof_lk);
        for (const char *q = pp; q && *q; ) {
            while (*q == ' ') q++;
            if (*q == 't' && g_prof_nt < kProfSpecs) g_prof_spec_t[g_prof_nt++] = atof(q + 1);
            else if (*q == 'g' && g_prof_ng < kProfSpecs) g_prof_spec_g[g_prof_ng++] = atof(q + 1);
            else if (*q >= '0' && *q <= '9') {
                char tag[24];
                snprintf(tag, sizeof tag, "f%d", atoi(q));
                prof_push_locked(-1, (uint32_t)atoi(q), -1, tag);
                nf++;
            }
            q = strchr(q, ',');
            if (q) q++;
        }
        os_unfair_lock_unlock(&g_prof_lk);
        hook(c, @selector(computeCommandEncoderWithDispatchType:), (IMP)kl_cce, (IMP *)&g_cce);
        hook(c, @selector(blitCommandEncoder), (IMP)kl_bce, (IMP *)&g_bce);
        hook(c, @selector(computeCommandEncoderWithDescriptor:), (IMP)kl_cced, (IMP *)&g_cced);
        hook(c, @selector(blitCommandEncoderWithDescriptor:), (IMP)kl_bced, (IMP *)&g_bced);
        fprintf(stderr, "[passes] per-pass GPU times (KL_GPU_PASSES=%s): %d window(s) after every scene start, %d after the "
                "first frame, %d at frame numbers; %u frames each\n", pp, g_prof_ng, g_prof_nt, nf, g_prof_n);
    }
    const char *e = getenv("KL_VRR_SPIKE");
    g_vrr_mode = !e || !*e ? 0 : !strncmp(e, "census", 6) ? 1 : !strncmp(e, "inject", 6) ? 2 : 0;
    excl_init();   // the compositor's passes get our timestamps through the render-encoder hook below
    if (!g_vrr_mode && !g_prof && !g_merge && !g_snap_at && !g_vrr_on && g_excl_on <= 0) return;
    if (!g_vrr_mode) { hook(c, @selector(renderCommandEncoderWithDescriptor:), (IMP)kl_rce, &g_rce); return; }
    if (g_vrr_mode == 2 && e[6] == ':') g_vrr_q = (float)atof(e + 7);
    const char *at = getenv("KL_VRR_SPIKE_AT");
    if (at && *at) g_vrr_at = (uint32_t)atoi(at);
    const char *tg = getenv("KL_VRR_SPIKE_TOGGLE");
    if (tg && *tg) g_vrr_toggle = atof(tg);
    SEL s = @selector(renderCommandEncoderWithDescriptor:);
    Method m = class_getInstanceMethod(c, s);
    if (!m) { fprintf(stderr, "[vrr] %s has no -renderCommandEncoderWithDescriptor:\n", class_getName(c)); return; }
    g_rce = method_getImplementation(m);
    if (!class_addMethod(c, s, (IMP)kl_rce, method_getTypeEncoding(m))) method_setImplementation(m, (IMP)kl_rce);
    fprintf(stderr, "[vrr] spike: %s\n", g_vrr_mode == 1 ? "census" : "inject");
}

static void watch(void *mtl_queue, int role) {
    if (!mtl_queue) return;
    const char *e = getenv("KL_GPU_TIME");
    if (e && *e == '0') return;
    os_unfair_lock_lock(&g_lk);
    int have = watched(mtl_queue) >= 0;
    if (!have && g_nqueues < kMaxQueues) { g_roles[g_nqueues] = role; g_queues[g_nqueues++] = mtl_queue; }
    int first = !g_commit;
    os_unfair_lock_unlock(&g_lk);
    if (have || !first) return;
    // The class that actually implements -commit for this device's buffers.
    id<MTLCommandQueue> q = (__bridge id<MTLCommandQueue>)mtl_queue;
    Class c;
    @autoreleasepool { c = object_getClass([q commandBuffer]); }
    Method m = class_getInstanceMethod(c, @selector(commit));
    if (!m) { fprintf(stderr, "[gputime] %s has no -commit; GPU time stays 0\n", class_getName(c)); return; }
    // Add the hook on the concrete class itself (so a superclass shared with
    // other command buffer kinds is left alone), keeping the inherited IMP.
    IMP orig = method_getImplementation(m);
    os_unfair_lock_lock(&g_lk);
    g_commit = orig;
    os_unfair_lock_unlock(&g_lk);
    if (!class_addMethod(c, @selector(commit), (IMP)kl_commit, method_getTypeEncoding(m)))
        method_setImplementation(m, (IMP)kl_commit);
    fprintf(stderr, "[gputime] timing %s -commit (first queue: %s)\n", class_getName(c),
            role ? "the compositor's" : "the guest's");
    vrr_install(c);
}

unsigned kl_gpu_time_frame(void) { return g_commit ? g_frame : 0; }
void kl_gpu_time_watch(void *mtl_queue) { watch(mtl_queue, 0); }
void kl_gpu_time_watch_compositor(void *mtl_queue) { watch(mtl_queue, 1); }

void kl_gpu_time_frame_end(void) {
    os_unfair_lock_lock(&g_lk);
    g_frame++;
    slot_of(g_frame);
    uint32_t frame = g_frame;
    int on = g_commit != NULL;
    os_unfair_lock_unlock(&g_lk);
    if (!on) return;
    if (g_prof > 0) {
        prof_report(frame);   // closes the active window once its frames are final
        prof_tick(frame);     // opens the next due one
    }
    // Every few seconds: the finished frames' GPU time.
    static unsigned last_f, n;
    static double sum, csum, worst, since;
    unsigned f;
    float comp;
    float ms = kl_gpu_time_frame_ms(0, &comp, &f);
    if (f && f != last_f) {
        last_f = f; sum += ms; csum += comp; n++; if (ms > worst) worst = ms;
        if (prof_in(f)) { g_prof_union += ms; g_prof_union_n++; }   // the profiled window's own [gputime]
    }
    // KL_GPU_TIME_LOG: the report interval in seconds (default 5).
    static double every;
    if (!every) { const char *e = getenv("KL_GPU_TIME_LOG"); every = e && atof(e) > 0 ? atof(e) : 5.0; }
    double now = CACurrentMediaTime();
    if (!since) since = now;
    if (now - since >= every) {
        if (n) {
            time_t t = time(NULL);
            struct tm lt;
            localtime_r(&t, &lt);
            unsigned h0, h1, m0, m1;
            os_unfair_lock_lock(&g_lk);
            h0 = g_excl_hits[0]; h1 = g_excl_hits[1]; m0 = g_excl_misses[0]; m1 = g_excl_misses[1];
            g_excl_hits[0] = g_excl_hits[1] = g_excl_misses[0] = g_excl_misses[1] = 0;
            os_unfair_lock_unlock(&g_lk);
            uint64_t vcbs = 0, vuns = 0;
            if (g_vp_busy_stats) g_vp_busy_stats(&vcbs, &vuns);
            fprintf(stderr, "[gputime] %02d:%02d:%02d GPU time per frame: game avg %.2f / worst %.2f ms, compositor avg "
                    "%.2f ms, over %u frames; exclusive buffers game %u (missed %u), compositor %u (missed %u); "
                    "VPVulkan accounted %llu (unsampled %llu); compositor samples %u resolved %u bad %u\n",
                    lt.tm_hour, lt.tm_min, lt.tm_sec, sum / n, worst, csum / n, n, h0, m0, h1, m1,
                    (unsigned long long)vcbs, (unsigned long long)vuns, g_cx_attached, g_cx_resolved, g_cx_bad);
        }
        sum = csum = worst = 0; n = 0; since = now;
    }
}

// The guest's GPU ms (and the compositor's in *compositor) of the latest final
// frame at least `frames_ago` closed frames back (0 = the frame closed most
// recently, or the one before it while its buffers are still in flight).
// Returns 0 with *frame = 0 when nothing is known.
static __thread int g_excl_last;   // per thread: bit 0 = the guest figure this thread last got was exclusive, bit 1 = the compositor's
int kl_gpu_time_frame_exclusive(void) { return g_excl_last; }
float kl_gpu_time_frame_ms(unsigned frames_ago, float *compositor, unsigned *frame) {
    float ms = 0, cms = 0;
    unsigned got = 0;
    os_unfair_lock_lock(&g_lk);
    for (unsigned back = 1 + frames_ago; back < kRing - 1 && back < g_frame; back++) {
        uint32_t f = g_frame - back;
        slot *s = &g_slots[f % kRing];
        if (s->frame != f) break;
        if (s->committed && s->completed == s->committed) {
            // Build 36: the exclusive figure when every buffer of the role was accounted, else the union.
            int ex0 = s->excl_n[0] && !s->excl_miss[0], ex1 = s->excl_n[1] && !s->excl_miss[1];
            ms = (float)((ex0 ? s->excl[0] : s->busy[0]) * 1e3);
            cms = (float)((ex1 ? s->excl[1] : s->busy[1]) * 1e3);
            g_excl_last = (ex0 ? 1 : 0) | (ex1 ? 2 : 0);
            got = f; break;
        }
    }
    os_unfair_lock_unlock(&g_lk);
    if (frame) *frame = got;
    if (compositor) *compositor = cms;
    return ms;
}

// KL_CP_DEPTH: an R32Float texture VIEW over a linear buffer (the depth staging buffer), so the compositor samples the
// game's depth where the copy left it instead of paying a second copy into an image. Returned retained (+1).
void *kl_mtl_buffer_texture_r32f(void *mtl_buffer, unsigned w, unsigned h, unsigned pitch_bytes) {
    id<MTLBuffer> b = (__bridge id<MTLBuffer>)mtl_buffer;
    if (!b || !w || !h || (NSUInteger)pitch_bytes * h > b.length) return NULL;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                   width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = b.storageMode;
    d.cpuCacheMode = b.cpuCacheMode;
    d.hazardTrackingMode = b.hazardTrackingMode;
    NSUInteger align = [b.device minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatR32Float];
    if (align && pitch_bytes % align) return NULL;
    id<MTLTexture> t = [b newTextureWithDescriptor:d offset:0 bytesPerRow:pitch_bytes];
    return t ? (void *)CFBridgingRetain(t) : NULL;
}
void kl_mtl_release(void *obj) { if (obj) CFRelease(obj); }
