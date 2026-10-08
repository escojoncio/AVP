# Log — AVP

Half-Life: Alyx (Steam Frame ARM64 Linux build) as a native visionOS app for Apple Vision Pro, Klepton-style (Linux ARM64 ELF loaded natively, no CPU translation).

## State
- **No code yet.** The repository holds the plan only: `PLAN.md` (research, verified facts about the game binaries, platform constraints, architecture, app design, phases).
- `CLAUDE.md`: repo rules (read PLAN.md first; one commit per step; never push Valve binaries or content).

## Decisions recorded in PLAN.md
- Native visionOS app; LiveContainer ruled out.
- Everything main is downloaded by the app (Swift Steam client with 2FA), not from a PC; downloaded files go to a user-accessible folder in Files, where the user can also place their own adapted files.
- Fixed strong foveation (Steam Frame-like), launch menu: real render resolution, foveation amount, antialiasing and MetalFX upscaling options; full shader pre-cache after download.
- Framerate is the priority. Memory budget on the target device with Increased Memory Limit: 8133 MB.
- PS VR2 Sense controllers (input + haptics) planned (§5.6).

## Next step
- **Phase 0 (blocking, cheap):** minimal visionOS prototype installed with SideStore — import SideStore's certificate, download a `.dylib`, sign it on the headset and `dlopen` it without JIT.
  - Works → Option 2 (everything from the app, Valve-free IPA).
  - Fails → Option 1 (adapted engine inside the IPA).
- Then Phase 1 (scaffold + CI with `[build]`-only builds, user folder, Klepton fork + glibc layer, MoltenVK, OpenVR on Compositor Services/ARKit, input, foveation, menu).

## Related
- The FEX/JIT and memory work proven in AstroVisionPro (16 KB pages, SIGBUS on Darwin for permission faults, StikDebug JIT arena) is reusable if any translation layer is ever needed.
