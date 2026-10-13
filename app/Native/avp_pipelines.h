// AVP: rebuilds the game's Vulkan pipeline list (a Fossilize .foz archive) on the headset from
// Glovebox's recipe (app/Resources/alyx.recipe) and the player's own shader packs.
//
// Port of Glovebox's engine/pipelines.py build() with gb/foz.py, gb/vpk.py and gb/vcs.py (MIT).
// The recipe is a Fossilize archive whose shader-module entries are replaced by references
// ("GBREF" + JSON: pack, .vcs file, static combo id, offset, size, SHA-256). Each reference is
// resolved by reading the .vcs out of the VPK, LZMA1-decoding its static combo (vendored LZMA SDK),
// checking the slice's SHA-256 and re-encoding it as Fossilize's LEB128 module payload.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*avp_pipelines_progress)(uint32_t done, uint32_t total, void *user);

/// recipe: alyx.recipe; game_dir: the depot's game/ folder (core/, hlvr/); out: the .foz to write
/// (written to <out>.part, then renamed). Returns the number of shader modules resolved, or -1
/// with a message in `err`.
int avp_pipelines_build(const char *recipe, const char *game_dir, const char *out,
                        avp_pipelines_progress progress, void *user, char *err, size_t err_len);

#ifdef __cplusplus
}
#endif
