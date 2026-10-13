# AVP

A native visionOS app that runs **Half-Life: Alyx** (the game's own ARM64 Linux build from Steam)
on **Apple Vision Pro**, with no PC and no Mac step.

## Requirements

- Apple Vision Pro on visionOS 26.
- PlayStation VR2 Sense controllers.
- Your own copy of Half-Life: Alyx on your Steam account.
- About 75 GB of free space on the headset.

## How it works

- The app signs in to Steam and checks that your account owns the game.
- It downloads the game and its ARM64 Linux binaries from Steam's servers onto the headset.
- The Linux libraries are converted to Mach-O on the headset (Klepton's `klepton_ld`, in process).
- The converted libraries are signed on the headset with your own imported certificate (`.p12`).
- The game runs under Klepton's runtime, with graphics through VPKEngine's Vulkan-to-Metal driver
  and input from the Sense controllers through an OpenVR layer on Compositor Services and ARKit.

Nothing from Valve is included in this repository or in the app: every game file comes from
your own Steam account. This project is not affiliated with or endorsed by Valve or Apple.

See [`PLAN.md`](PLAN.md) for the design and [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)
for licences.

## Credits

Written by Claude, building on the great work of Glovebox, Klepton (by Max Thomas), VPKEngine, Fossilize, LuaJIT, SDL and the Debian runtime libraries; the owner of this repository only contributed ideas on how some things could be adapted.
