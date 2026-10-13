// AVP: pipeline list rebuild (see avp_pipelines.h). Port of Glovebox engine/pipelines.py build(),
// gb/foz.py, gb/vpk.py, gb/vcs.py (MIT, Copyright (c) 2026 the Glovebox contributors).
#include "avp_pipelines.h"

#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#include "steam_support.h"  // steam_lzma_decode (vendored LZMA SDK, app/Steam/CSteamSupport)

static void fail(char *err, size_t len, const char *fmt, ...) {
    if (!err || !len) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, len, fmt, ap);
    va_end(ap);
}

static uint8_t *read_all(const char *path, size_t *len) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0) { close(fd); return NULL; }
    size_t n = (size_t)st.st_size;
    uint8_t *p = malloc(n ? n : 1);
    size_t done = 0;
    while (p && done < n) {
        ssize_t r = read(fd, p + done, n - done);
        if (r <= 0) { free(p); p = NULL; break; }
        done += (size_t)r;
    }
    close(fd);
    if (p) *len = n;
    return p;
}

static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static int64_t rd64(const uint8_t *p) { return (int64_t)((uint64_t)rd32(p) | (uint64_t)rd32(p + 4) << 32); }
static void wr32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24); }

// ---- VPK (gb/vpk.py) --------------------------------------------------------------------------

typedef struct {
    char *path;
    uint16_t arc, pre;
    uint32_t aoff, alen;
    size_t poff;  // preload bytes in the dir file
} vpk_entry;

typedef struct {
    char base[4096];   // ".../shaders_vulkan" (without _dir.vpk)
    uint8_t *dir;
    size_t dir_len;
    size_t inline_base;
    vpk_entry *e;
    int n;
} vpk;

static int vpk_cmp(const void *a, const void *b) { return strcmp(((const vpk_entry *)a)->path, ((const vpk_entry *)b)->path); }

static void vpk_free(vpk *v) {
    for (int i = 0; i < v->n; i++) free(v->e[i].path);
    free(v->e);
    free(v->dir);
    memset(v, 0, sizeof *v);
}

static int vpk_open(vpk *v, const char *dir_path, char *err, size_t el) {
    memset(v, 0, sizeof *v);
    size_t l = strlen(dir_path);
    if (l < 8 || strcmp(dir_path + l - 8, "_dir.vpk")) { fail(err, el, "%s: not a *_dir.vpk", dir_path); return -1; }
    snprintf(v->base, sizeof v->base, "%.*s", (int)(l - 8), dir_path);
    v->dir = read_all(dir_path, &v->dir_len);
    if (!v->dir || v->dir_len < 12) { fail(err, el, "%s: unreadable", dir_path); return -1; }
    const uint8_t *d = v->dir;
    if (rd32(d) != 0x55AA1234) { fail(err, el, "%s: bad VPK signature", dir_path); return -1; }
    uint32_t ver = rd32(d + 4), tree = rd32(d + 8);
    size_t hdr = ver == 1 ? 12 : 28;
    v->inline_base = hdr + tree;
    size_t off = hdr, cap = 4096;
    v->e = malloc(cap * sizeof *v->e);
    if (!v->e) return -1;
#define RS(dst) do { const uint8_t *z = memchr(d + off, 0, v->dir_len - off); if (!z) goto bad; dst = (const char *)d + off; off = (size_t)(z - d) + 1; } while (0)
    for (;;) {
        const char *ext; RS(ext);
        if (!*ext) break;
        for (;;) {
            const char *path; RS(path);
            if (!*path) break;
            for (;;) {
                const char *name; RS(name);
                if (!*name) break;
                if (off + 18 > v->dir_len) goto bad;
                const uint8_t *p = d + off;
                vpk_entry x;
                x.pre = rd16(p + 4);
                x.arc = rd16(p + 6);
                x.aoff = rd32(p + 8);
                x.alen = rd32(p + 12);
                off += 18;
                x.poff = off;
                off += x.pre;
                int root = 1;
                for (const char *c = path; *c; c++) if (*c != ' ') root = 0;
                size_t need = strlen(path) + strlen(name) + strlen(ext) + 3;
                x.path = malloc(need);
                if (!x.path) goto bad;
                if (root) snprintf(x.path, need, "%s.%s", name, ext);
                else snprintf(x.path, need, "%s/%s.%s", path, name, ext);
                if ((size_t)v->n == cap) {
                    cap *= 2;
                    vpk_entry *q = realloc(v->e, cap * sizeof *q);
                    if (!q) { free(x.path); goto bad; }
                    v->e = q;
                }
                v->e[v->n++] = x;
            }
        }
    }
#undef RS
    qsort(v->e, (size_t)v->n, sizeof *v->e, vpk_cmp);
    return 0;
bad:
    fail(err, el, "%s: corrupt directory", dir_path);
    return -1;
}

static uint8_t *vpk_read(const vpk *v, const char *name, size_t *len, char *err, size_t el) {
    vpk_entry key = { .path = (char *)name };
    const vpk_entry *x = bsearch(&key, v->e, (size_t)v->n, sizeof *v->e, vpk_cmp);
    if (!x) { fail(err, el, "%s: not in %s_dir.vpk", name, v->base); return NULL; }
    size_t n = (size_t)x->pre + x->alen;
    uint8_t *out = malloc(n ? n : 1);
    if (!out) { fail(err, el, "out of memory"); return NULL; }
    memcpy(out, v->dir + x->poff, x->pre);
    if (x->alen) {
        if (x->arc == 0x7FFF) {
            size_t start = v->inline_base + x->aoff;
            if (start + x->alen > v->dir_len) { free(out); fail(err, el, "%s: inline data out of range", name); return NULL; }
            memcpy(out + x->pre, v->dir + start, x->alen);
        } else {
            char arc[4200];
            snprintf(arc, sizeof arc, "%s_%03u.vpk", v->base, (unsigned)x->arc);
            int fd = open(arc, O_RDONLY);
            if (fd < 0) { free(out); fail(err, el, "%s: %s", arc, strerror(errno)); return NULL; }
            size_t done = 0;
            while (done < x->alen) {
                ssize_t r = pread(fd, out + x->pre + done, x->alen - done, (off_t)x->aoff + (off_t)done);
                if (r <= 0) { close(fd); free(out); fail(err, el, "%s: short read", arc); return NULL; }
                done += (size_t)r;
            }
            close(fd);
        }
    }
    *len = n;
    return out;
}

// ---- VCS (gb/vcs.py) --------------------------------------------------------------------------

/// The static-combo table: finds `sid` and returns its file offset, or -1.
static int64_t vcs_static_offset(const uint8_t *d, size_t len, int64_t sid) {
    if (len < 8 || len > 0x7fffffff) return -1;
    uint8_t key[4];
    wr32(key, (uint32_t)len);
    for (size_t q = 0; q + 4 <= len; q++) {
        if (memcmp(d + q, key, 4) != 0) continue;
        for (int64_t n = 1; n < 50000; n++) {
            int64_t p = (int64_t)q - 12 * n - 4;
            if (p < 0) break;
            if ((int32_t)rd32(d + p) == n && (int64_t)(int32_t)rd32(d + p + 4 + 8 * n) == (int64_t)q + 4) {
                for (int64_t i = 0; i < n; i++) {
                    if (rd64(d + p + 4 + 8 * i) == sid) return (int32_t)rd32(d + p + 4 + 8 * n + 4 * i);
                }
                return -1;  // the table, without this combo
            }
        }
    }
    return -1;
}

static uint8_t *vcs_static_blob(const uint8_t *d, size_t len, int64_t off, size_t *out_len, char *err, size_t el) {
    if (off < 0 || (size_t)off + 21 > len) { fail(err, el, "static combo offset out of range"); return NULL; }
    const uint8_t *h = d + off;
    if (rd32(h + 4) != 0x414D5A4C) { fail(err, el, "static combo at %lld: not LZMA", (long long)off); return NULL; }
    int32_t usize = (int32_t)rd32(h + 8), csize = (int32_t)rd32(h + 12);
    if (usize <= 0 || csize <= 0 || (size_t)off + 21 + (size_t)csize > len) { fail(err, el, "static combo sizes"); return NULL; }
    uint8_t *out = malloc((size_t)usize);
    if (!out) { fail(err, el, "out of memory"); return NULL; }
    long n = steam_lzma_decode(h[16], rd32(h + 17), h + 21, (size_t)csize, out, (size_t)usize);
    if (n <= 0) { free(out); fail(err, el, "static combo at %lld: LZMA decode failed", (long long)off); return NULL; }
    *out_len = (size_t)n;
    return out;
}

// ---- Fossilize (gb/foz.py) --------------------------------------------------------------------

typedef struct {
    const uint8_t *name;     // 40 hex chars
    uint32_t fmt, crc, size;
    const uint8_t *stored;
    uint32_t stored_len;
    // a reference (GBREF) entry:
    int is_ref;
    char *json;              // the module's JSON header (unescaped)
    char *pack, *file;
    int64_t sid;
    uint32_t offset, code_size;
    char sha[65];
    uint8_t *code;           // resolved SPIR-V
} foz_entry;

// Minimal JSON for a flat object of strings and integers: returns the value of `key` as a string
// (unescaped) or the raw number text.
static char *json_get(const char *j, const char *key) {
    char pat[64];
    snprintf(pat, sizeof pat, "\"%s\":", key);
    const char *p = strstr(j, pat);
    if (!p) return NULL;
    p += strlen(pat);
    while (*p == ' ') p++;
    if (*p == '"') {
        p++;
        size_t cap = strlen(p) + 1, n = 0;
        char *out = malloc(cap);
        if (!out) return NULL;
        while (*p && *p != '"') {
            if (*p == '\\' && p[1]) {
                p++;
                switch (*p) {
                case 'n': out[n++] = '\n'; break;
                case 't': out[n++] = '\t'; break;
                case 'r': out[n++] = '\r'; break;
                case 'b': out[n++] = '\b'; break;
                case 'f': out[n++] = '\f'; break;
                case 'u': {
                    unsigned v = 0;
                    for (int i = 1; i <= 4 && p[i]; i++) {
                        char c = p[i];
                        v = v * 16 + (unsigned)(c >= 'a' ? c - 'a' + 10 : c >= 'A' ? c - 'A' + 10 : c - '0');
                    }
                    p += 4;
                    if (v < 0x80) out[n++] = (char)v;  // the recipe only escapes ASCII
                    break;
                }
                default: out[n++] = *p;
                }
                p++;
            } else {
                out[n++] = *p++;
            }
        }
        out[n] = 0;
        return out;
    }
    const char *e = p;
    while (*e == '-' || (*e >= '0' && *e <= '9')) e++;
    char *out = malloc((size_t)(e - p) + 1);
    if (!out) return NULL;
    memcpy(out, p, (size_t)(e - p));
    out[e - p] = 0;
    return out;
}

static long long json_int(const char *j, const char *key, int *ok) {
    char *s = json_get(j, key);
    if (!s || !*s) { free(s); *ok = 0; return 0; }
    long long v = strtoll(s, NULL, 10);
    free(s);
    return v;
}

static int cmp_group(const void *a, const void *b) {
    const foz_entry *x = *(const foz_entry *const *)a, *y = *(const foz_entry *const *)b;
    int c = strcmp(x->pack, y->pack);
    if (c) return c;
    c = strcmp(x->file, y->file);
    if (c) return c;
    return x->sid < y->sid ? -1 : x->sid > y->sid;
}

static int write_all(FILE *f, const void *p, size_t n) { return fwrite(p, 1, n, f) == n ? 0 : -1; }

int avp_pipelines_build(const char *recipe, const char *game_dir, const char *out,
                        avp_pipelines_progress progress, void *user, char *err, size_t el) {
    size_t rlen = 0;
    uint8_t *r = read_all(recipe, &rlen);
    if (!r || rlen < 16) { free(r); fail(err, el, "%s: unreadable", recipe); return -1; }
    int result = -1, n = 0, cap = 16384, nrefs = 0;
    foz_entry *e = calloc((size_t)cap, sizeof *e);
    foz_entry **refs = NULL;
    vpk packs[2];
    const char *pack_names[2] = { "core/shaders_vulkan_dir.vpk", "hlvr/shaders_vulkan_dir.vpk" };
    int packs_open[2] = { 0, 0 };
    uint8_t *inflated = NULL;
    FILE *f = NULL;
    char tmp[4200];
    snprintf(tmp, sizeof tmp, "%s.part", out);
    if (!e) { fail(err, el, "out of memory"); goto done; }

    // 1. Entries (foz.read): a torn tail is skipped.
    for (size_t off = 16; off + 56 <= rlen;) {
        uint32_t stored = rd32(r + off + 40);
        size_t end = off + 56 + stored;
        if (end > rlen) break;
        if (n == cap) {
            cap *= 2;
            foz_entry *q = realloc(e, (size_t)cap * sizeof *e);
            if (!q) { fail(err, el, "out of memory"); goto done; }
            memset(q + n, 0, (size_t)(cap - n) * sizeof *q);
            e = q;
        }
        foz_entry *x = &e[n++];
        x->name = r + off;
        x->stored_len = stored;
        x->fmt = rd32(r + off + 44);
        x->crc = rd32(r + off + 48);
        x->size = rd32(r + off + 52);
        x->stored = r + off + 56;
        off = end;
    }
    // 2. References.
    for (int i = 0; i < n; i++) {
        foz_entry *x = &e[i];
        const uint8_t *p = x->stored;
        size_t plen = x->stored_len;
        free(inflated); inflated = NULL;
        if (x->fmt == 2) {
            inflated = malloc(x->size ? x->size : 1);
            if (!inflated) { fail(err, el, "out of memory"); goto done; }
            uLongf dl = x->size;
            if (uncompress(inflated, &dl, x->stored, x->stored_len) != Z_OK) { fail(err, el, "recipe entry %d: bad deflate", i); goto done; }
            p = inflated;
            plen = dl;
        }
        if (plen < 5 || memcmp(p, "GBREF", 5) != 0) continue;
        char *j = malloc(plen - 5 + 1);
        if (!j) { fail(err, el, "out of memory"); goto done; }
        memcpy(j, p + 5, plen - 5);
        j[plen - 5] = 0;
        int ok = 1;
        x->is_ref = 1;
        x->json = json_get(j, "json");
        x->pack = json_get(j, "pack");
        x->file = json_get(j, "file");
        char *sha = json_get(j, "sha256");
        x->sid = json_int(j, "static", &ok);
        x->offset = (uint32_t)json_int(j, "offset", &ok);
        x->code_size = (uint32_t)json_int(j, "size", &ok);
        free(j);
        if (!ok || !x->json || !x->pack || !x->file || !sha || strlen(sha) != 64 || x->code_size % 4) {
            free(sha);
            fail(err, el, "recipe entry %d: bad reference", i);
            goto done;
        }
        memcpy(x->sha, sha, 65);
        free(sha);
        nrefs++;
    }
    free(inflated); inflated = NULL;
    refs = malloc((size_t)(nrefs ? nrefs : 1) * sizeof *refs);
    if (!refs) { fail(err, el, "out of memory"); goto done; }
    { int k = 0; for (int i = 0; i < n; i++) if (e[i].is_ref) refs[k++] = &e[i]; }
    qsort(refs, (size_t)nrefs, sizeof *refs, cmp_group);

    // 3. Resolve, one static combo at a time.
    for (int k = 0; k < 2; k++) {
        char path[4200];
        snprintf(path, sizeof path, "%s/%s", game_dir, pack_names[k]);
        if (vpk_open(&packs[k], path, err, el) != 0) { vpk_free(&packs[k]); goto done; }
        packs_open[k] = 1;
    }
    for (int i = 0; i < nrefs;) {
        int j = i;
        while (j < nrefs && cmp_group(&refs[i], &refs[j]) == 0) j++;
        foz_entry *g = refs[i];
        int which = !strcmp(g->pack, pack_names[0]) ? 0 : !strcmp(g->pack, pack_names[1]) ? 1 : -1;
        if (which < 0) { fail(err, el, "unknown pack %s", g->pack); goto done; }
        size_t vlen = 0, blen = 0;
        uint8_t *vcs = vpk_read(&packs[which], g->file, &vlen, err, el);
        if (!vcs) goto done;
        int64_t off = vcs_static_offset(vcs, vlen, g->sid);
        if (off < 0) { free(vcs); fail(err, el, "%s: static combo %lld not found", g->file, (long long)g->sid); goto done; }
        uint8_t *blob = vcs_static_blob(vcs, vlen, off, &blen, err, el);
        free(vcs);
        if (!blob) goto done;
        for (int k = i; k < j; k++) {
            foz_entry *x = refs[k];
            if ((size_t)x->offset + x->code_size > blen) { free(blob); fail(err, el, "%s static %lld: slice out of range", x->file, (long long)x->sid); goto done; }
            unsigned char dg[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256(blob + x->offset, (CC_LONG)x->code_size, dg);
            char hex[65];
            for (int b = 0; b < 32; b++) snprintf(hex + 2 * b, 3, "%02x", dg[b]);
            if (strcmp(hex, x->sha) != 0) {
                free(blob);
                fail(err, el, "%s static %lld @%u: not the expected shader (game files changed?)", x->file, (long long)x->sid, x->offset);
                goto done;
            }
            x->code = malloc(x->code_size ? x->code_size : 1);
            if (!x->code) { free(blob); fail(err, el, "out of memory"); goto done; }
            memcpy(x->code, blob + x->offset, x->code_size);
        }
        free(blob);
        if (progress) progress((uint32_t)j, (uint32_t)nrefs, user);
        i = j;
    }

    // 4. Write: header, then every entry in order; references become raw modules (foz.join_module).
    f = fopen(tmp, "wb");
    if (!f) { fail(err, el, "%s: %s", tmp, strerror(errno)); goto done; }
    if (write_all(f, r, 16)) goto werr;
    for (int i = 0; i < n; i++) {
        foz_entry *x = &e[i];
        if (!x->is_ref) {
            uint8_t h[16];
            wr32(h, x->stored_len); wr32(h + 4, x->fmt); wr32(h + 8, x->crc); wr32(h + 12, x->size);
            if (write_all(f, x->name, 40) || write_all(f, h, 16) || write_all(f, x->stored, x->stored_len)) goto werr;
            continue;
        }
        size_t jl = strlen(x->json), words = x->code_size / 4;
        uint8_t *payload = malloc(jl + 1 + words * 5 + 1);
        if (!payload) { fail(err, el, "out of memory"); goto done; }
        memcpy(payload, x->json, jl);
        payload[jl] = 0;
        size_t pn = jl + 1;
        for (size_t w = 0; w < words; w++) {
            uint32_t v = rd32(x->code + 4 * w);
            for (;;) {
                uint8_t b = v & 0x7F;
                v >>= 7;
                if (v) payload[pn++] = b | 0x80;
                else { payload[pn++] = b; break; }
            }
        }
        int ok = 1;
        long long vs = json_int(x->json, "varintSize", &ok);
        long long vo = json_int(x->json, "varintOffset", &ok);
        if (!ok || vs != (long long)(pn - jl - 1) || vo != 0) {
            free(payload);
            fail(err, el, "shader module re-encodes to a different size");
            goto done;
        }
        uint8_t h[16];
        uint32_t crc = (uint32_t)crc32(0L, payload, (uInt)pn);
        wr32(h, (uint32_t)pn); wr32(h + 4, 1); wr32(h + 8, crc); wr32(h + 12, (uint32_t)pn);
        int bad = write_all(f, x->name, 40) || write_all(f, h, 16) || write_all(f, payload, pn);
        free(payload);
        if (bad) goto werr;
    }
    if (fclose(f) != 0) { f = NULL; goto werr; }
    f = NULL;
    if (rename(tmp, out) != 0) { fail(err, el, "rename %s: %s", out, strerror(errno)); goto done; }
    result = nrefs;
    goto done;
werr:
    fail(err, el, "%s: write failed (%s)", tmp, strerror(errno));
done:
    if (f) fclose(f);
    if (result < 0) unlink(tmp);
    free(inflated);
    for (int k = 0; k < 2; k++) if (packs_open[k]) vpk_free(&packs[k]);
    for (int i = 0; i < n; i++) {
        free(e[i].json); free(e[i].pack); free(e[i].file); free(e[i].code);
    }
    free(e);
    free(refs);
    free(r);
    return result;
}
