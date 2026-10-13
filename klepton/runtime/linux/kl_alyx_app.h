// AVP: the Alyx app's own files, read before the guest starts (kl_alyx_app.c).
#pragma once
#include <stddef.h>

// The four folders of an AVP launch (AlyxBoot.swift, AVPLaunchPaths):
//   game    the depot's game/ folder (bin/, hlvr/, core/), with the REAL ELF files
//   dylibs  the flat folder of signed <stem>.dylib translations (the only code that is loaded)
//   config  what the app wrote from its settings: alyx-env.txt (KEY=VALUE, '#' comments),
//           alyx-convars.lua, video2.txt, vr_fidelity_levels_override.csv
//   data    writable: klfz/ (pipelines, device info, perf), logs/
typedef struct {
    const char *game, *dylibs, *config, *data;
} kl_alyx_paths;

// Applies alyx-env.txt to the environment, points KL_LUA_INJECT at alyx-convars.lua (the convars
// re-applied at every player_activate), installs video2.txt and the fidelity table into the game
// folder at EVERY launch (the app rules over the game) with VendorID/DeviceID set to the selected
// Vulkan driver's, and makes the soname placeholders the engine needs. <envline> gets what the env
// file set and <filesline> what happened to each file, both for the boot log.
void kl_alyx_app_files(const kl_alyx_paths *p, char *envline, size_t envsz, char *filesline, size_t filessz);
