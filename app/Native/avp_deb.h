// AVP: pulls shared libraries out of a Debian package (.deb) on the headset.
//
// A .deb is an `ar` archive holding debian-binary, control.tar.* and data.tar.{xz,zst,gz}. The
// runtime libraries the game expects from a Linux system (libstdc++, GLib, OpenSSL, ...) are
// copied out of data.tar under their soname, following symlinks inside the archive
// (libssl.so.3 is a real file, libpng16.so.16 -> libpng16.so.16.x.y is a link).
//
// Decompression: xz through Apple's Compression framework (COMPRESSION_LZMA decodes the .xz
// container: LZMA2 + CRC32/CRC64 checks, which is what dpkg-deb writes), zstd through the
// vendored single-file decoder (app/Steam/CSteamSupport/zstd), gzip through zlib.
#pragma once
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Extracts every file whose base name is in `wanted` (nwanted names) from the .deb at
/// `deb_path` into `out_dir/<name>` (symlinks resolved to the file they point at).
/// `found` (nwanted ints, may be NULL) gets 1 for each name written.
/// Returns the number of names written, or -1 with a message in `err`.
int avp_deb_extract(const char *deb_path, const char *out_dir, const char *const *wanted, int nwanted,
                    int *found, char *err, size_t err_len);

#ifdef __cplusplus
}
#endif
