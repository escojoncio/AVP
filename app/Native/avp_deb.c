// AVP: .deb -> runtime libraries (see avp_deb.h).
#include "avp_deb.h"

#include <compression.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

// The vendored zstd decoder (app/Steam/CSteamSupport/zstd/zstddeclib.c), streaming entry points.
typedef struct ZSTD_DCtx_s ZSTD_DStream;
typedef struct { const void *src; size_t size; size_t pos; } ZSTD_inBuffer;
typedef struct { void *dst; size_t size; size_t pos; } ZSTD_outBuffer;
ZSTD_DStream *ZSTD_createDStream(void);
size_t ZSTD_freeDStream(ZSTD_DStream *zds);
size_t ZSTD_initDStream(ZSTD_DStream *zds);
size_t ZSTD_decompressStream(ZSTD_DStream *zds, ZSTD_outBuffer *output, ZSTD_inBuffer *input);
unsigned ZSTD_isError(size_t code);

static void fail(char *err, size_t len, const char *fmt, ...) {
    if (!err || !len) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, len, fmt, ap);
    va_end(ap);
}

// ---- growable buffer --------------------------------------------------------------------------

typedef struct { uint8_t *p; size_t n, cap; } buf;

static int buf_reserve(buf *b, size_t extra) {
    if (b->n + extra <= b->cap) return 0;
    size_t cap = b->cap ? b->cap : (1u << 20);
    while (cap < b->n + extra) cap *= 2;
    uint8_t *q = realloc(b->p, cap);
    if (!q) return -1;
    b->p = q;
    b->cap = cap;
    return 0;
}

// ---- decompressors ----------------------------------------------------------------------------

static int unxz(const uint8_t *src, size_t len, buf *out, char *err, size_t el) {
    compression_stream s;
    if (compression_stream_init(&s, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) != COMPRESSION_STATUS_OK) {
        fail(err, el, "xz: compression_stream_init failed");
        return -1;
    }
    s.src_ptr = src;
    s.src_size = len;
    int rc = -1;
    for (;;) {
        if (buf_reserve(out, 1u << 20)) { fail(err, el, "xz: out of memory"); break; }
        s.dst_ptr = out->p + out->n;
        s.dst_size = out->cap - out->n;
        compression_status st = compression_stream_process(&s, COMPRESSION_STREAM_FINALIZE);
        out->n = (size_t)(s.dst_ptr - out->p);
        if (st == COMPRESSION_STATUS_END) { rc = 0; break; }
        if (st != COMPRESSION_STATUS_OK) { fail(err, el, "xz: corrupt stream"); break; }
    }
    compression_stream_destroy(&s);
    return rc;
}

static int unzstd(const uint8_t *src, size_t len, buf *out, char *err, size_t el) {
    ZSTD_DStream *z = ZSTD_createDStream();
    if (!z) { fail(err, el, "zstd: out of memory"); return -1; }
    ZSTD_initDStream(z);
    ZSTD_inBuffer in = { src, len, 0 };
    int rc = 0;
    while (in.pos < in.size) {
        if (buf_reserve(out, 1u << 20)) { fail(err, el, "zstd: out of memory"); rc = -1; break; }
        ZSTD_outBuffer o = { out->p + out->n, out->cap - out->n, 0 };
        size_t r = ZSTD_decompressStream(z, &o, &in);
        out->n += o.pos;
        if (ZSTD_isError(r)) { fail(err, el, "zstd: corrupt stream"); rc = -1; break; }
        if (r == 0 && in.pos == in.size) break;
        if (o.pos == 0 && in.pos == in.size) break;
    }
    ZSTD_freeDStream(z);
    return rc;
}

static int ungzip(const uint8_t *src, size_t len, buf *out, char *err, size_t el) {
    z_stream s;
    memset(&s, 0, sizeof s);
    if (inflateInit2(&s, 31) != Z_OK) { fail(err, el, "gzip: init failed"); return -1; }
    s.next_in = (Bytef *)src;
    s.avail_in = (uInt)len;
    int rc = -1;
    for (;;) {
        if (buf_reserve(out, 1u << 20)) { fail(err, el, "gzip: out of memory"); break; }
        s.next_out = out->p + out->n;
        s.avail_out = (uInt)(out->cap - out->n);
        int r = inflate(&s, Z_NO_FLUSH);
        out->n = out->cap - s.avail_out;
        if (r == Z_STREAM_END) { rc = 0; break; }
        if (r != Z_OK) { fail(err, el, "gzip: corrupt stream (%d)", r); break; }
    }
    inflateEnd(&s);
    return rc;
}

// ---- tar --------------------------------------------------------------------------------------

typedef struct {
    char *path;       // normalised, no leading "./" or "/"
    char *link;       // symlink target as stored, or NULL
    size_t off, size; // data in the tar buffer (regular files)
    int regular;
} entry;

static uint64_t octal(const char *p, size_t n) {
    if ((unsigned char)p[0] & 0x80) {  // GNU base-256
        uint64_t v = 0;
        for (size_t i = 1; i < n; i++) v = (v << 8) | (unsigned char)p[i];
        return v;
    }
    uint64_t v = 0;
    size_t i = 0;
    while (i < n && (p[i] == ' ' || p[i] == 0)) i++;
    for (; i < n && p[i] >= '0' && p[i] <= '7'; i++) v = v * 8 + (uint64_t)(p[i] - '0');
    return v;
}

static char *dupn(const char *s, size_t n) {
    size_t l = strnlen(s, n);
    char *d = malloc(l + 1);
    if (!d) return NULL;
    memcpy(d, s, l);
    d[l] = 0;
    return d;
}

// Collapses "./", "//", "a/../" and drops a leading "/" in place.
static void normalise(char *path) {
    char *parts[256];
    int n = 0;
    char *save = NULL;
    char tmp[4096];
    snprintf(tmp, sizeof tmp, "%s", path);
    for (char *t = strtok_r(tmp, "/", &save); t; t = strtok_r(NULL, "/", &save)) {
        if (!strcmp(t, ".")) continue;
        if (!strcmp(t, "..")) { if (n) n--; continue; }
        if (n < 256) parts[n++] = t;
    }
    char out[4096];
    out[0] = 0;
    for (int i = 0; i < n; i++) {
        if (i) strlcat(out, "/", sizeof out);
        strlcat(out, parts[i], sizeof out);
    }
    strcpy(path, out);  // never longer than the input
}

// pax "path=" / "linkpath=" records.
static void pax(const uint8_t *p, size_t n, char **path, char **link) {
    size_t i = 0;
    while (i < n) {
        size_t len = 0, j = i;
        while (j < n && p[j] >= '0' && p[j] <= '9') len = len * 10 + (p[j++] - '0');
        if (!len || i + len > n || j >= n) break;
        const char *kv = (const char *)p + j + 1;
        size_t kvn = i + len - (j + 1);
        if (kvn && kv[kvn - 1] == '\n') kvn--;
        if (kvn > 5 && !strncmp(kv, "path=", 5)) { free(*path); *path = dupn(kv + 5, kvn - 5); }
        if (kvn > 9 && !strncmp(kv, "linkpath=", 9)) { free(*link); *link = dupn(kv + 9, kvn - 9); }
        i += len;
    }
}

static int parse_tar(const buf *t, entry **out, int *count, char *err, size_t el) {
    int n = 0, cap = 256;
    entry *e = calloc((size_t)cap, sizeof *e);
    if (!e) { fail(err, el, "tar: out of memory"); return -1; }
    char *long_name = NULL, *long_link = NULL;
    size_t off = 0;
    while (off + 512 <= t->n) {
        const char *h = (const char *)t->p + off;
        if (!h[0]) break;  // end-of-archive block
        uint64_t size = octal(h + 124, 12);
        char type = h[156];
        size_t data = off + 512;
        if (data + size > t->n) { fail(err, el, "tar: truncated"); goto bad; }
        size_t next = data + ((size + 511) & ~(size_t)511);
        if (type == 'L') { free(long_name); long_name = dupn((const char *)t->p + data, size); off = next; continue; }
        if (type == 'K') { free(long_link); long_link = dupn((const char *)t->p + data, size); off = next; continue; }
        if (type == 'x') { pax(t->p + data, size, &long_name, &long_link); off = next; continue; }
        if (type == 'g') { off = next; continue; }
        char name[4096];
        if (long_name) {
            snprintf(name, sizeof name, "%s", long_name);
        } else {
            char nm[101], pre[156];
            memcpy(nm, h, 100); nm[100] = 0;
            memcpy(pre, h + 345, 155); pre[155] = 0;
            if (!memcmp(h + 257, "ustar", 5) && pre[0]) snprintf(name, sizeof name, "%s/%s", pre, nm);
            else snprintf(name, sizeof name, "%s", nm);
        }
        normalise(name);
        if (type == '0' || type == 0 || type == '2' || type == '1') {
            if (n == cap) {
                cap *= 2;
                entry *q = realloc(e, (size_t)cap * sizeof *e);
                if (!q) { fail(err, el, "tar: out of memory"); goto bad; }
                e = q;
            }
            entry *x = &e[n++];
            memset(x, 0, sizeof *x);
            x->path = strdup(name);
            if (type == '2' || type == '1') {
                char lk[4096];
                if (long_link) snprintf(lk, sizeof lk, "%s", long_link);
                else { memcpy(lk, h + 157, 100); lk[100] = 0; }
                if (type == '1') { normalise(lk); }          // hard link: archive path
                x->link = strdup(lk);
                x->regular = (type == '1') ? 2 : 0;           // 2 = hard link
            } else {
                x->regular = 1;
                x->off = data;
                x->size = (size_t)size;
            }
        }
        free(long_name); long_name = NULL;
        free(long_link); long_link = NULL;
        off = next;
    }
    free(long_name); free(long_link);
    *out = e;
    *count = n;
    return 0;
bad:
    free(long_name); free(long_link);
    for (int i = 0; i < n; i++) { free(e[i].path); free(e[i].link); }
    free(e);
    return -1;
}

static const entry *find_path(const entry *e, int n, const char *path) {
    for (int i = 0; i < n; i++) if (!strcmp(e[i].path, path)) return &e[i];
    return NULL;
}

// Follows symlinks (relative to the link's folder, or absolute from the package root) and hard
// links to the entry holding the bytes.
static const entry *resolve(const entry *e, int n, const entry *x) {
    for (int hop = 0; x && hop < 16; hop++) {
        if (x->regular == 1) return x;
        char target[4096];
        if (x->regular == 2) {
            snprintf(target, sizeof target, "%s", x->link);
        } else if (x->link[0] == '/') {
            snprintf(target, sizeof target, "%s", x->link + 1);
        } else {
            char dir[4096];
            snprintf(dir, sizeof dir, "%s", x->path);
            char *slash = strrchr(dir, '/');
            if (slash) *slash = 0; else dir[0] = 0;
            snprintf(target, sizeof target, "%s%s%s", dir, dir[0] ? "/" : "", x->link);
        }
        normalise(target);
        x = find_path(e, n, target);
    }
    return NULL;
}

static const char *base_name(const char *p) {
    const char *s = strrchr(p, '/');
    return s ? s + 1 : p;
}

static int write_file(const char *path, const uint8_t *p, size_t n) {
    char tmp[4096];
    snprintf(tmp, sizeof tmp, "%s.partial", path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0755);
    if (fd < 0) return -1;
    size_t done = 0;
    while (done < n) {
        ssize_t w = write(fd, p + done, n - done);
        if (w <= 0) { close(fd); unlink(tmp); return -1; }
        done += (size_t)w;
    }
    if (close(fd) != 0) { unlink(tmp); return -1; }
    return rename(tmp, path);
}

// ---- ar + everything --------------------------------------------------------------------------

int avp_deb_extract(const char *deb_path, const char *out_dir, const char *const *wanted, int nwanted,
                    int *found, char *err, size_t el) {
    if (found) for (int i = 0; i < nwanted; i++) found[i] = 0;
    int fd = open(deb_path, O_RDONLY);
    if (fd < 0) { fail(err, el, "open %s: %s", deb_path, strerror(errno)); return -1; }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 8) { close(fd); fail(err, el, "%s: empty", deb_path); return -1; }
    size_t len = (size_t)st.st_size;
    const uint8_t *m = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (m == MAP_FAILED) { fail(err, el, "mmap: %s", strerror(errno)); return -1; }
    int result = -1;
    buf tarbuf = { 0 };
    entry *ents = NULL;
    int nents = 0;
    if (memcmp(m, "!<arch>\n", 8) != 0) { fail(err, el, "not an ar archive"); goto out; }
    size_t off = 8;
    const uint8_t *data = NULL;
    size_t data_len = 0;
    char kind = 0;
    while (off + 60 <= len) {
        char name[17];
        memcpy(name, m + off, 16);
        name[16] = 0;
        for (int i = 15; i >= 0 && (name[i] == ' ' || name[i] == '/'); i--) name[i] = 0;
        char sz[11];
        memcpy(sz, m + off + 48, 10);
        sz[10] = 0;
        size_t size = (size_t)strtoull(sz, NULL, 10);
        size_t body = off + 60;
        if (body + size > len) { fail(err, el, "ar: truncated member %s", name); goto out; }
        if (!strncmp(name, "data.tar", 8)) {
            data = m + body;
            data_len = size;
            if (!strcmp(name, "data.tar.xz")) kind = 'x';
            else if (!strcmp(name, "data.tar.zst")) kind = 'z';
            else if (!strcmp(name, "data.tar.gz")) kind = 'g';
            else if (!strcmp(name, "data.tar")) kind = 't';
            else { fail(err, el, "unsupported member %s", name); goto out; }
            break;
        }
        off = body + size + (size & 1);
    }
    if (!data) { fail(err, el, "no data.tar in the package"); goto out; }
    int rc = 0;
    switch (kind) {
    case 'x': rc = unxz(data, data_len, &tarbuf, err, el); break;
    case 'z': rc = unzstd(data, data_len, &tarbuf, err, el); break;
    case 'g': rc = ungzip(data, data_len, &tarbuf, err, el); break;
    default:
        if (buf_reserve(&tarbuf, data_len)) { fail(err, el, "out of memory"); rc = -1; break; }
        memcpy(tarbuf.p, data, data_len);
        tarbuf.n = data_len;
    }
    if (rc) goto out;
    if (parse_tar(&tarbuf, &ents, &nents, err, el)) goto out;
    result = 0;
    for (int w = 0; w < nwanted; w++) {
        const entry *hit = NULL;
        for (int i = 0; i < nents && !hit; i++) {
            if (!strcmp(base_name(ents[i].path), wanted[w])) hit = resolve(ents, nents, &ents[i]);
        }
        if (!hit) continue;
        char dst[4096];
        snprintf(dst, sizeof dst, "%s/%s", out_dir, wanted[w]);
        if (write_file(dst, tarbuf.p + hit->off, hit->size) != 0) {
            fail(err, el, "write %s: %s", dst, strerror(errno));
            result = -1;
            goto out;
        }
        if (found) found[w] = 1;
        result++;
    }
out:
    for (int i = 0; i < nents; i++) { free(ents[i].path); free(ents[i].link); }
    free(ents);
    free(tarbuf.p);
    munmap((void *)m, len);
    return result;
}
