// Always-on Vulkan call diagnostics. Included by kl_vulkan.c (headers branch only),
// after ours() and klvk_missing_trap, before the proc-addr functions that use kld_wrap().
//
// Why: a guest that gives up on Vulkan ("Error in Init() of RenderDeviceMgr001") often
// does so on a VkResult nobody printed — the driver returned it quietly and the guest
// turned it into a generic message box. So every entry point handed to the guest
// (vkGetInstanceProcAddr / vkGetDeviceProcAddr / dlsym) is wrapped, by name, in a
// generated thunk (kl_vk_diag_gen.h, tools/gen_vk_diag.py) that calls the very pointer
// it would otherwise have returned and then:
//   - VkResult != VK_SUCCESS: one line per (function, result) with the guest call site
//     (lib+offset) and a counter; errors (< 0) repeat at counts 10, 100, 1000…, success
//     codes (> 0: VK_NOT_READY, VK_TIMEOUT, VK_INCOMPLETE, VK_SUBOPTIMAL_KHR …) are
//     printed once only, since acquire/wait/query/enumerate return them routinely;
//   - vkCreate* / vkAllocate* / vkGetDeviceQueue*: a VK_NULL_HANDLE written to the
//     output on success is reported the same way;
//   - every call (VkResult, void and scalar — vkCmd* excepted, they are the hot path)
//     goes into a 64-entry lock-free ring that kl_vulkan_diag_dump() prints. The guest
//     message box calls it, so the box is preceded by the calls that led to it.
// Behaviour is unchanged: the thunk forwards the call bit-for-bit (see the generator's
// note on the AArch64 ABI) and returns exactly what the callee returned. No allocation;
// all shared state is fixed-size and atomic. KL_VK_DIAG=0 hands out the raw pointers.

#define KLD_NORES   INT32_MIN   // ring marker: the command returns no VkResult
#define KLD_VARIANTS 2          // distinct real pointers per name (e.g. gipa vs gdpa)
#define KLD_RES_SLOTS 4         // distinct non-success results tracked per function
#define KLD_RING    64

#define KLD_GEN_TABLE
#include "kl_vk_diag_gen.h"
#undef KLD_GEN_TABLE

static int kld_on(void) {
    static _Atomic int on = -1;
    int v = atomic_load_explicit(&on, memory_order_relaxed);
    if (v < 0) { v = kl_env_on("KL_VK_DIAG", 1) ? 1 : 0; atomic_store_explicit(&on, v, memory_order_relaxed); }
    return v;
}

static _Atomic(PFN_vkVoidFunction) kld_real[KLD_N][KLD_VARIANTS];
static struct { _Atomic int32_t res; _Atomic uint32_t n; } kld_seen[KLD_N][KLD_RES_SLOTS];
static _Atomic uint32_t kld_seen_more[KLD_N];   // results beyond KLD_RES_SLOTS
static _Atomic uint32_t kld_null_n[KLD_N];      // VK_NULL_HANDLE outputs on success

typedef struct {
    _Atomic uint64_t seq;        // index + 1 once complete; 0 while being written
    _Atomic uint32_t id_tid;     // function id | thread id << 16
    _Atomic int32_t  res;
    _Atomic uint32_t arg;        // first 32-bit scalar argument (a VkFormat, a count …)
    _Atomic uint64_t val;        // created handle, or a scalar return value
    _Atomic(const void *) ra;    // caller
} kld_ent;
static kld_ent kld_ring[KLD_RING];
static _Atomic uint64_t kld_head;
static _Atomic uint32_t kld_ntid;
static __thread uint32_t t_kld_tid;

static inline PFN_vkVoidFunction kld_real_fn(int id, int v) {
    return atomic_load_explicit(&kld_real[id][v], memory_order_acquire);
}
// t_kld_ra keeps the GUEST call site for the outermost thunk on this thread, so
// KLVK_WHO inside a Klepton wrapper still names the guest rather than the thunk.
static inline const void *kld_enter(const void *ra) {
    const void *prev = t_kld_ra;
    if (!prev) t_kld_ra = ra;
    return prev;
}
static inline void kld_leave(const void *prev) { if (!prev) t_kld_ra = NULL; }

static const char *kld_res_str(int32_t r, char *buf, size_t n) {
    const char *s = kld_result_name(r);
    if (s) return s;
    snprintf(buf, n, "VkResult(%d)", (int)r);
    return buf;
}
static void kld_site(const void *ra, char *buf, size_t n) {
    size_t off = 0; const char *img = kl_addr_image(ra, &off);
    if (img) {
        const char *slash = strrchr(img, '/');
        snprintf(buf, n, "%s+0x%zx", slash ? slash + 1 : img, off);
    } else snprintf(buf, n, "%p", ra);
}
static int kld_pow10(uint32_t n) {
    for (uint32_t p = 10; p && p <= n; p = (p > 0xffffffffu / 10) ? 0 : p * 10)
        if (p == n) return 1;
    return 0;
}
static uint32_t kld_tid(void) {
    if (!t_kld_tid) t_kld_tid = atomic_fetch_add_explicit(&kld_ntid, 1, memory_order_relaxed) + 1;
    return t_kld_tid;
}

static void kld_count(int id, int32_t r, const void *ra) {
    char rb[32], sb[256];
    for (int i = 0; i < KLD_RES_SLOTS; i++) {
        int32_t cur = atomic_load_explicit(&kld_seen[id][i].res, memory_order_relaxed);
        if (cur == 0) {   // VK_SUCCESS is never stored, so 0 means free
            int32_t exp = 0;
            cur = atomic_compare_exchange_strong(&kld_seen[id][i].res, &exp, r) ? r : exp;
        }
        if (cur != r) continue;
        uint32_t n = atomic_fetch_add_explicit(&kld_seen[id][i].n, 1, memory_order_relaxed) + 1;
        if (n == 1 || (r < 0 && kld_pow10(n))) {
            kld_site(ra, sb, sizeof sb);
            VKI("diag: %s -> %s #%u <- %s (t%u)%s\n", kld_names[id], kld_res_str(r, rb, sizeof rb),
                n, sb, kld_tid(), n == 1 && r > 0 ? " [success code: reported once]" : "");
        }
        return;
    }
    if (atomic_fetch_add_explicit(&kld_seen_more[id], 1, memory_order_relaxed) == 0) {
        kld_site(ra, sb, sizeof sb);
        VKI("diag: %s -> %s <- %s (more than %d distinct results; further ones only counted)\n",
            kld_names[id], kld_res_str(r, rb, sizeof rb), sb, KLD_RES_SLOTS);
    }
}

// Output array of a vkCreate*/vkAllocate*/vkGetDeviceQueue* that succeeded: any VK_NULL_HANDLE in it
// is a driver bug the guest will trip on later. Returns the first handle for the ring.
static uint64_t kld_out_handles(int id, const void *ra, const void *out, uint32_t n) {
    if (!out || !n) return 0;
    const uint64_t *h = (const uint64_t *)out;   // dispatchable and non-dispatchable: both 8 bytes on arm64
    uint32_t k = n > 256 ? 256 : n;
    for (uint32_t i = 0; i < k; i++) {
        if (h[i]) continue;
        uint32_t c = atomic_fetch_add_explicit(&kld_null_n[id], 1, memory_order_relaxed) + 1;
        if (c == 1 || kld_pow10(c)) {
            char sb[256];
            kld_site(ra, sb, sizeof sb);
            VKI("diag: %s succeeded but output[%u of %u] is VK_NULL_HANDLE #%u <- %s (t%u)\n",
                kld_names[id], i, n, c, sb, kld_tid());
        }
        break;
    }
    return h[0];
}

static void kld_after(int id, int32_t res, const void *ra, uint32_t arg, uint64_t val) {
    if (!t_pipe_replay) {   // the pipeline replayer's own calls would flush the guest's out of the ring
        uint64_t idx = atomic_fetch_add_explicit(&kld_head, 1, memory_order_relaxed);
        kld_ent *e = &kld_ring[idx & (KLD_RING - 1)];
        atomic_store_explicit(&e->seq, 0, memory_order_relaxed);
        atomic_thread_fence(memory_order_release);
        atomic_store_explicit(&e->id_tid, (uint32_t)id | kld_tid() << 16, memory_order_relaxed);
        atomic_store_explicit(&e->res, res, memory_order_relaxed);
        atomic_store_explicit(&e->arg, arg, memory_order_relaxed);
        atomic_store_explicit(&e->val, val, memory_order_relaxed);
        atomic_store_explicit(&e->ra, ra, memory_order_relaxed);
        atomic_store_explicit(&e->seq, idx + 1, memory_order_release);
    }
    if (res != KLD_NORES && res != VK_SUCCESS) kld_count(id, res, ra);
}

#define KLD_GEN_THUNKS
#include "kl_vk_diag_gen.h"
#undef KLD_GEN_THUNKS

static int kld_cmp(const void *k, const void *e) { return strcmp((const char *)k, *(const char *const *)e); }

// The pointer to hand the guest for `name`: a thunk around `fn`, or `fn` itself when
// there is nothing to wrap (unknown name, vkCmd*, the missing-function stub, diag off).
static PFN_vkVoidFunction kld_wrap(const char *name, PFN_vkVoidFunction fn) {
    if (!fn || !name || fn == (PFN_vkVoidFunction)klvk_missing_trap || !kld_on()) return fn;
    const char *const *p = bsearch(name, kld_names, KLD_N, sizeof *kld_names, kld_cmp);
    if (!p) return fn;
    int id = (int)(p - kld_names);
    for (int v = 0; v < KLD_VARIANTS; v++) {
        if (fn == kld_thunks[id][v]) return fn;   // already one of ours
        PFN_vkVoidFunction cur = atomic_load_explicit(&kld_real[id][v], memory_order_acquire);
        if (!cur) {
            PFN_vkVoidFunction exp = NULL;
            if (atomic_compare_exchange_strong(&kld_real[id][v], &exp, fn)) return kld_thunks[id][v];
            cur = exp;
        }
        if (cur == fn) return kld_thunks[id][v];
    }
    static _Atomic uint32_t said;
    if (atomic_fetch_add_explicit(&said, 1, memory_order_relaxed) < 8)
        VKI("diag: %s resolved to more than %d distinct pointers — this one handed out unwrapped\n",
            name, KLD_VARIANTS);
    return fn;
}

void kl_vulkan_diag_dump(const char *why) {
    if (!kld_on()) return;
    uint64_t head = atomic_load_explicit(&kld_head, memory_order_acquire);
    uint64_t from = head > KLD_RING ? head - KLD_RING : 0;
    char rb[32], sb[256];
    fprintf(stderr, "  [vk] diag: ---- last %llu of %llu Vulkan calls (vkCmd* not recorded), oldest first — %s ----\n",
            (unsigned long long)(head - from), (unsigned long long)head, why ? why : "dump");
    for (uint64_t s = from; s < head; s++) {
        kld_ent *e = &kld_ring[s & (KLD_RING - 1)];
        uint64_t q1 = atomic_load_explicit(&e->seq, memory_order_acquire);
        uint32_t it = atomic_load_explicit(&e->id_tid, memory_order_relaxed);
        int32_t res = atomic_load_explicit(&e->res, memory_order_relaxed);
        uint32_t arg = atomic_load_explicit(&e->arg, memory_order_relaxed);
        uint64_t val = atomic_load_explicit(&e->val, memory_order_relaxed);
        const void *ra = atomic_load_explicit(&e->ra, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        uint64_t q2 = atomic_load_explicit(&e->seq, memory_order_relaxed);
        if (q1 != s + 1 || q2 != q1) {
            fprintf(stderr, "  [vk] diag: #%llu (being written / overwritten)\n", (unsigned long long)s);
            continue;
        }
        uint32_t id = it & 0xffffu;
        if (id >= KLD_N) continue;
        kld_site(ra, sb, sizeof sb);
        fprintf(stderr, "  [vk] diag: #%llu t%u %s%s%s arg=%#x val=%#llx <- %s\n", (unsigned long long)s, it >> 16,
                kld_names[id], res == KLD_NORES ? "" : " -> ",
                res == KLD_NORES ? "" : kld_res_str(res, rb, sizeof rb), arg, (unsigned long long)val, sb);
    }
    for (int id = 0; id < KLD_N; id++) {
        for (int i = 0; i < KLD_RES_SLOTS; i++) {
            uint32_t n = atomic_load_explicit(&kld_seen[id][i].n, memory_order_relaxed);
            if (n) fprintf(stderr, "  [vk] diag: total %s -> %s x%u\n", kld_names[id],
                           kld_res_str(atomic_load_explicit(&kld_seen[id][i].res, memory_order_relaxed), rb, sizeof rb), n);
        }
        uint32_t z = atomic_load_explicit(&kld_null_n[id], memory_order_relaxed);
        if (z) fprintf(stderr, "  [vk] diag: total %s -> VK_NULL_HANDLE output x%u\n", kld_names[id], z);
    }
    fprintf(stderr, "  [vk] diag: ---- end ----\n");
    fflush(stderr);
}
