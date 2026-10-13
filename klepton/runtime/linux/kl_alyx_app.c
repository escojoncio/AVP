// AVP: the Alyx app's own files, read before the guest starts (kl_app.c's kl_app_configure_alyx).
//
// Adapted from Glovebox's kl_alyx_app.c (MIT). There the defaults rode in the app bundle and a test
// script could push replacements into Documents; in AVP every file is written by the app from its own
// settings (AlyxBoot.swift) into one config folder, and the app rules over the game: whatever the
// game, the player's in-game Options or Steam Cloud left in the game folder, the app's files are
// installed again at every launch.
//
//   <config>/alyx-env.txt      KEY=VALUE lines, applied to the environment before any default ('#'
//                              starts a comment). In a value "@config/", "@data/", "@game/" and
//                              "@dylibs/" are those folders, e.g. KL_VK_FOZ_REPLAY=@data/klfz
//   <config>/alyx-convars.lua  stands in for the game's (empty) game/gameinit.lua (KL_LUA_INJECT,
//                              kl_lua.c): it runs in the game's own VScript VM, so it can register
//                              ListenToGameEvent("player_activate", ...) and re-apply the app's forced
//                              convars at every spawn, whatever the game changed since
//   <config>/video2.txt        -> <game>/hlvr/cfg/deckard/video2.txt
//   <config>/vr_fidelity_levels_override.csv -> <game>/hlvr/vr_fidelity_levels_override.csv
//
// The game keeps video2.txt only while its VendorID and DeviceID equal the running GPU's; otherwise it
// replaces the whole file with its automatic setup at boot. So both ids are rewritten to the selected
// Vulkan driver's (kl_vulkan_gpu_ids: VPVulkan or MoltenVK, whichever KL_MVK_DYLIB names) as the file
// is installed. The game's previous file is kept once as <file>.game (the first time only).
//
// The soname names Valve's hlvr.sh links at every launch (libavcodec.so.58 -> libavcodec.so.58.91.100,
// ...) are made as empty files when nothing is at that name: the engine stats them while loading its
// modules, and a Steam download does not carry the links. The game folder otherwise holds the REAL
// ELF files, which are never mapped: with KL_DYLIB_ONLY=1 the loader takes every library, by its stem,
// from the signed <stem>.dylib in the dylibs folder (kl_image.c, dylib_candidate).
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "kl_alyx_app.h"

static kl_alyx_paths g_p;

static int exists(const char *p) { struct stat st; return stat(p, &st) == 0; }
static int named(const char *p) { struct stat st; return lstat(p, &st) == 0; }   // the name itself, links included

// "@config/", "@data/", "@game/" and "@dylibs/" anywhere in an env value, as the folders they name.
static void expand(const char *v, char *out, size_t n) {
    static const struct { const char *tag; size_t len; int which; } tags[] = {
        {"@config/", 8, 0}, {"@data/", 6, 1}, {"@game/", 6, 2}, {"@dylibs/", 8, 3},
    };
    size_t o = 0;
    out[0] = 0;
    while (*v && o + 1 < n) {
        int hit = -1;
        for (size_t t = 0; t < sizeof tags / sizeof *tags && hit < 0; t++)
            if (!strncmp(v, tags[t].tag, tags[t].len)) hit = (int)t;
        if (hit >= 0) {
            const char *base = tags[hit].which == 0 ? g_p.config : tags[hit].which == 1 ? g_p.data
                             : tags[hit].which == 2 ? g_p.game : g_p.dylibs;
            o += (size_t)snprintf(out + o, n - o, "%s/", base ? base : ".");
            v += tags[hit].len;
        } else {
            out[o++] = *v++;
            out[o] = 0;
        }
    }
    if (o >= n) out[n - 1] = 0;
}

static void env_file(const char *path, char *line_out, size_t outsz) {
    char line[1024], val[2048];
    FILE *f = fopen(path, "r");
    if (!f) return;
    size_t used = strlen(line_out);
    while (fgets(line, sizeof line, f)) {
        char *e = line + strcspn(line, "\r\n"); *e = 0;
        char *k = line; while (*k == ' ' || *k == '\t') k++;
        char *eq = strchr(k, '=');
        if (*k == '#' || !eq || eq == k) continue;
        char *ke = eq; while (ke > k && (ke[-1] == ' ' || ke[-1] == '\t')) ke--;
        *ke = 0;
        expand(eq + 1, val, sizeof val);
        setenv(k, val, 1);
        if (used < outsz) used += (size_t)snprintf(line_out + used, outsz - used, " %s=%s", k, val);
    }
    fclose(f);
}

// mkdir -p of <path>'s parent.
static void parents(const char *path) {
    char p[1200];
    snprintf(p, sizeof p, "%s", path);
    for (char *s = p + 1; *s; s++)
        if (*s == '/') { *s = 0; mkdir(p, 0755); *s = '/'; }
}

// A whole small file into memory (NUL-terminated); NULL when it can't be read. *len gets its size.
static char *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    size_t cap = 65536, n = 0;
    char *b = malloc(cap + 1);
    size_t r;
    while (b && (r = fread(b + n, 1, cap - n, f)) > 0) {
        n += r;
        if (n == cap) { char *g = realloc(b, (cap *= 2) + 1); if (!g) { free(b); b = NULL; } else b = g; }
    }
    fclose(f);
    if (!b) return NULL;
    b[n] = 0;
    *len = n;
    return b;
}

// The value of a "key" "value" line of a KeyValues file (video2.txt), into out; 0 when there is none.
static int kv_get(const char *text, const char *key, char *out, size_t n) {
    char q[64];
    snprintf(q, sizeof q, "\"%s\"", key);
    for (const char *l = text; l && *l; l = strchr(l, '\n') ? strchr(l, '\n') + 1 : NULL) {
        const char *k = l;
        while (*k == ' ' || *k == '\t') k++;
        if (strncmp(k, q, strlen(q))) continue;
        const char *v = strchr(k + strlen(q), '"');
        const char *e = v ? strchr(v + 1, '"') : NULL;
        if (!e || memchr(v, '\n', (size_t)(e - v))) return 0;
        snprintf(out, n, "%.*s", (int)(e - v - 1), v + 1);
        return 1;
    }
    return 0;
}

// <text> with the value of its first "key" line set to val; a new malloc'd string.
static char *kv_set(const char *text, const char *key, const char *val) {
    char q[64], cur[256];
    snprintf(q, sizeof q, "\"%s\"", key);
    if (!kv_get(text, key, cur, sizeof cur)) return strdup(text);
    size_t out_n = strlen(text) + strlen(val) + 1;
    char *out = malloc(out_n);
    if (!out) return NULL;
    out[0] = 0;
    int done = 0;
    for (const char *l = text; *l;) {
        const char *nl = strchr(l, '\n');
        size_t len = nl ? (size_t)(nl - l + 1) : strlen(l);
        const char *k = l;
        while (*k == ' ' || *k == '\t') k++;
        if (!done && !strncmp(k, q, strlen(q))) {
            const char *v = strchr(k + strlen(q), '"');
            const char *e = v ? strchr(v + 1, '"') : NULL;
            if (e && e < l + len) {
                strncat(out, l, (size_t)(v - l + 1));
                strcat(out, val);
                strncat(out, e, (size_t)(l + len - e));
                l += len;
                done = 1;
                continue;
            }
        }
        strncat(out, l, len);
        l += len;
    }
    return out;
}

// <data> written to <dst> through a temporary file and a rename; 0 on success.
static int put(const char *dst, const char *data, size_t n) {
    char tmp[1300];
    parents(dst);
    snprintf(tmp, sizeof tmp, "%s.klnew", dst);
    FILE *out = fopen(tmp, "wb");
    if (!out) return -1;
    int bad = fwrite(data, 1, n, out) != n;
    if (fclose(out) != 0 || bad || rename(tmp, dst) != 0) { unlink(tmp); return -1; }
    return 0;
}

// The selected Vulkan driver's ids (kl_vulkan.c, in the same archive); 0 when no driver loads.
int kl_vulkan_gpu_ids(unsigned *vendor, unsigned *device);

// <config>/<name> installed as <game>/<rel>, at every launch; video settings get the GPU's ids.
// Returns what happened, for the boot log (into buf).
static const char *install(const char *name, const char *rel, int gpu_ids, char *buf, size_t bufsz) {
    char src[1200], dst[1200], keep[1300];
    snprintf(src, sizeof src, "%s/%s", g_p.config, name);
    snprintf(dst, sizeof dst, "%s/%s", g_p.game, rel);
    size_t n;
    char *ours = slurp(src, &n);
    if (!ours) return named(dst) ? "game's own (the app wrote none)" : "none";
    const char *ids = "";
    if (gpu_ids) {
        unsigned id[2];
        static const char *const keys[] = {"VendorID", "DeviceID"};
        if (kl_vulkan_gpu_ids(&id[0], &id[1])) {
            for (int i = 0; i < 2; i++) {
                char want[24];
                snprintf(want, sizeof want, "%u", id[i]);
                char *t = kv_set(ours, keys[i], want);
                if (t) { free(ours); ours = t; }
            }
            n = strlen(ours);
            static char idbuf[64];
            snprintf(idbuf, sizeof idbuf, ", gpu ids %u/%u", id[0], id[1]);
            ids = idbuf;
        } else ids = ", GPU IDS UNKNOWN (the game may replace it)";
    }
    // The game's own file, once, so nothing of the player's is lost the first time the app takes over.
    snprintf(keep, sizeof keep, "%s.game", dst);
    if (named(dst) && !named(keep)) {
        size_t on;
        char *prev = slurp(dst, &on);
        if (prev) { (void)put(keep, prev, on); free(prev); }
    }
    int bad = put(dst, ours, n) != 0;
    free(ours);
    snprintf(buf, bufsz, "%s%s", bad ? "WRITE FAILED" : "installed", ids);
    return buf;
}

// hlvr.sh's links for linuxsteamrtarm64, and the SDL2 name the engine opens.
static const char *const k_sonames[] = {
    "libavcodec.so.58", "libavcodec.so", "libavformat.so.58", "libavformat.so", "libavresample.so.4",
    "libavresample.so", "libavutil.so.56", "libavutil.so", "libfontconfig.so.1", "libfontconfig.so",
    "libfreetype.so.6", "libfreetype.so", "libharfbuzz-gobject.so.0", "libharfbuzz-gobject.so",
    "libharfbuzz-icu.so.0", "libharfbuzz-icu.so", "libharfbuzz.so.0", "libharfbuzz.so",
    "libharfbuzz-subset.so.0", "libharfbuzz-subset.so", "libpango-1.0.so.0", "libpango-1.0.so",
    "libpangoft2-1.0.so.0", "libpangoft2-1.0.so", "libswscale.so.5", "libswscale.so", "libSDL2-2.0.so.0",
};

static int sonames(void) {
    char dir[1200], p[1300];
    snprintf(dir, sizeof dir, "%s/bin/linuxsteamrtarm64", g_p.game);
    if (!exists(dir)) return -1;
    int made = 0;
    for (size_t i = 0; i < sizeof k_sonames / sizeof k_sonames[0]; i++) {
        snprintf(p, sizeof p, "%s/%s", dir, k_sonames[i]);
        if (named(p)) continue;
        // O_EXCL: never through a link, never over a file that appeared meanwhile.
        int fd = open(p, O_WRONLY | O_CREAT | O_EXCL, 0644);
        if (fd >= 0) { close(fd); made++; }
    }
    return made;
}

void kl_alyx_app_files(const kl_alyx_paths *p, char *envline, size_t envsz, char *filesline, size_t filessz) {
    g_p = *p;
    char path[1200];
    envline[0] = 0;
    snprintf(path, sizeof path, "%s/alyx-env.txt", g_p.config);
    const char *env_from = "none";
    if (exists(path)) {
        snprintf(envline, envsz, "  env file  :");
        env_file(path, envline, envsz);
        size_t u = strlen(envline);
        if (u + 1 < envsz) snprintf(envline + u, envsz - u, "\n");
        env_from = "applied";
    }
    // The convars, unless a hand-given KL_LUA_INJECT names its own.
    static char spec[1300];
    const char *cv_from = "none";
    snprintf(path, sizeof path, "%s/alyx-convars.lua", g_p.config);
    if (exists(path) && !getenv("KL_LUA_INJECT")) {
        snprintf(spec, sizeof spec, "game/gameinit=%s", path);
        setenv("KL_LUA_INJECT", spec, 1);
        cv_from = "injected as game/gameinit.lua";
    }
    char hlvr[1200], fb[96], vb[96];
    snprintf(hlvr, sizeof hlvr, "%s/hlvr", g_p.game);
    const char *fid = "no game folder", *vid = "no game folder";
    if (exists(hlvr)) {
        fid = install("vr_fidelity_levels_override.csv", "hlvr/vr_fidelity_levels_override.csv", 0, fb, sizeof fb);
        vid = install("video2.txt", "hlvr/cfg/deckard/video2.txt", 1, vb, sizeof vb);
    }
    int so = sonames();
    snprintf(filesline, filessz,
             "  app files : env %s, convars %s, fidelity table %s, video settings %s, soname placeholders %s%d\n",
             env_from, cv_from, fid, vid, so < 0 ? "(no bin folder) " : "made ", so < 0 ? 0 : so);
}
