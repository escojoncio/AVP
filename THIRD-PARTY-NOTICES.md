# Avisos de terceros

## Klepton (MIT)
- Origen: https://github.com/shinyquagsire23/Klepton, commit `ce74582cb1e434db210014dbcd0ca0aad0e46ba2` (2026-09-03).
- Copia en `klepton/` con su licencia (`klepton/LICENSE`): `runtime/`, `Makefile`, `tools/klepton_ld.c`,
  `tools/mvk_fetch.sh`, `tools/mvk_retarget.sh`, `visionos/Sources`, `visionos/Info.plist`, `visionos/Klepton.entitlements`.
- Cambios propios (marcados con «VisionQuestPro» o «AVP» en el código):
  - `tools/klepton_ld.c`: modo en proceso (`-DKLEPTON_LD_INPROC`, `klepton_ld_run()`; los errores vuelven con
    `longjmp` en vez de `exit`) y un `LC_CODE_SIGNATURE` vacío al final de `__LINKEDIT`.
  - `tools/klepton_ld.c`, `runtime/kl_x18.c/.h`: se incorporan los cambios de Glovebox (veneers x18 para `casp` con el
    par x18:x19, `blr x18`, `adr x18`, `stp/ldp` con x18 y writeback; secciones `__klelf/__kltext/__klconst`,
    `LC_FUNCTION_STARTS`, `LC_SOURCE_VERSION`, `--symtab`).
  - `visionos/Sources/kl_app.c/.h`: `kl_app_configure_game()` (juego elegido en tiempo de ejecución); traducciones
    `<lib>.dylib` además de `<lib>.framework`.
  - `visionos/Sources/KleptonApp.swift`: ventana raíz = lanzador de VisionQuestPro; configuración con las rutas del juego.
  - `visionos/Sources/Klepton-Bridging-Header.h`, `visionos/Info.plist`: cabeceras y claves del lanzador.

## VPEngine
- `runtime/vp_codesign.c`, `runtime/vp_pkcs12.c` (firma de librerías en el visor) se toman de
  el repositorio VPEngine (mismo propietario que este) al compilar (CI); no se copian a este repositorio. Licencia: la de VPEngine.
- `app/Sources/VQFolder.swift` y `app/Sources/VQSigner.swift` siguen el diseño de `VPS4Folder.swift` y `VPGamePack.swift`.

## MoltenVK (Apache-2.0)
- v1.4.2, descargado y verificado (sha256) en CI por `klepton/tools/mvk_fetch.sh`; se incluye en la app como
  `Frameworks/MoltenVK.framework`.

## Glovebox (MIT)
- Copyright (c) 2026 the Glovebox contributors.
- Origen de los cambios de Klepton para Linux/Alyx (x18, personalidad glibc, OpenVR) y del diseño del cliente de
  Steam y de la preparación del juego, portados aquí a Swift/C para hacerse en el visor.

## Fossilize (MIT)
- Copyright (c) 2018-2019 Hans-Kristian Arntzen. Compilado en CI (`scripts/build-fossilize.sh`), enlazado estático.

## LuaJIT (MIT)
- Copyright (C) 2005-2025 Mike Pall. Compilado en CI (`scripts/build-luajit.sh`), solo intérprete.

## SDL3 (zlib)
- Copyright (C) 1997-2025 Sam Lantinga. Compilado en CI (`scripts/build-sdl.sh`), `Frameworks/SDL3.framework`.

## sdl2-compat (zlib)
- Copyright (C) 1997-2025 Sam Lantinga. Compilado en CI, `Frameworks/SDL2.framework`.

## LZMA SDK (dominio público)
- Igor Pavlov. Descompresión de chunks de Steam (`app/Steam/CSteamSupport/lzma`).

## Zstandard (BSD-3-Clause)
- Copyright (c) Meta Platforms, Inc. and affiliates. Descompresión de chunks de Steam (`app/Steam/CSteamSupport/zstd`).

## OpenVR headers (BSD-3-Clause)
- Copyright (c) 2015, Valve Corporation. Solo las cabeceras de la API (`klepton/runtime/openvr`).

## GameNetworkingSockets headers (BSD-3-Clause)
- Copyright (c) 2018, Valve Corporation. Solo cabeceras de la API, para el loopback de red en proceso.

## Steam Audio HRTF data (Apache-2.0)
- `klepton/runtime/data/phonon_hrtf_cipic_124.sofa`, si se incluye: datos HRTF de Steam Audio (Apache-2.0),
  derivados de la base CIPIC.

## Paquetes de Debian
- 17 paquetes arm64 de Debian (libstdc++, libgcc_s, OpenSSL, GLib, …) se descargan en el visor desde Debian,
  verificados por SHA-256; no se incluyen en este repositorio ni en la app. Cada uno conserva su licencia
  (GPL con excepción de runtime de GCC, Apache-2.0 de OpenSSL, LGPL-2.1+ de GLib, etc.).
