// AVP: the app's own C surface, for the Swift bridging header (one include).
#pragma once
#include <stddef.h>
#include "avp_config.h"
#include "avp_deb.h"
#include "avp_pipelines.h"
#include "steam_support.h"   // app/Steam/CSteamSupport/include

// klepton/tools/klepton_ld.c built with -DKLEPTON_LD_INPROC: one ELF -> one Mach-O dylib, in process.
int klepton_ld_run(const char *in, const char *out, char *err, size_t err_len);
