#!/usr/bin/env bash
# SDL3 and sdl2-compat (with AVP's visionOS patch) for the visionOS device, as frameworks.
# Alyx's engine opens libSDL2-2.0.so.0; Klepton's glibc personality redirects that dlopen to
# SDL2.framework (KL_SDL2_DYLIB), which is sdl2-compat over SDL3 on the offscreen video driver.
# Usage: build-sdl.sh <output dir>   (e.g. build/deps)
#   -> <out>/Frameworks/SDL3.framework (id @rpath/SDL3.framework/SDL3)
#      <out>/Frameworks/SDL2.framework (id @rpath/SDL2.framework/SDL2)
# Idempotent: skipped when both frameworks and the stamp for the pinned tags are present.
set -euo pipefail
SDL3_TAG=release-3.4.16
SDL2C_TAG=release-2.32.72
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/deps/sdl2-compat/0001-visionos-build.patch"
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
SRC="$OUT/src"
FW="$OUT/Frameworks"
STAMP="$FW/.sdl-$SDL3_TAG-$SDL2C_TAG"
if [ -f "$FW/SDL3.framework/SDL3" ] && [ -f "$FW/SDL2.framework/SDL2" ] && [ -f "$STAMP" ]; then
  echo "[sdl] $SDL3_TAG + sdl2-compat $SDL2C_TAG up to date"; exit 0
fi
mkdir -p "$SRC" "$FW"
[ -d "$SRC/SDL3/.git" ] || git clone -q --depth 1 --branch "$SDL3_TAG" https://github.com/libsdl-org/SDL.git "$SRC/SDL3"
if [ ! -d "$SRC/sdl2-compat/.git" ]; then
  git clone -q --depth 1 --branch "$SDL2C_TAG" https://github.com/libsdl-org/sdl2-compat.git "$SRC/sdl2-compat"
fi
# The patch once: --check fails when it is already applied.
if git -C "$SRC/sdl2-compat" apply --check "$PATCH" 2>/dev/null; then
  git -C "$SRC/sdl2-compat" apply "$PATCH"
elif ! git -C "$SRC/sdl2-compat" apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "[sdl] the sdl2-compat visionOS patch does not apply to $SDL2C_TAG"; exit 1
fi

COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT=xros
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0)
echo "[sdl] building SDL3 $SDL3_TAG"
cmake -S "$SRC/SDL3" -B "$SRC/build-sdl3" "${COMMON[@]}" -DSDL_SHARED=ON -DSDL_STATIC=OFF \
  -DSDL_TEST_LIBRARY=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_FRAMEWORK=ON > /dev/null
cmake --build "$SRC/build-sdl3" > /dev/null
B3=$(find "$SRC/build-sdl3" -name SDL3.framework -type d -prune | head -n 1)
[ -n "$B3" ] || { echo "[sdl] SDL3.framework not built"; exit 1; }

echo "[sdl] building sdl2-compat $SDL2C_TAG"
cmake -S "$SRC/sdl2-compat" -B "$SRC/build-sdl2c" "${COMMON[@]}" -DSDL2COMPAT_TESTS=OFF \
  -DSDL3_INCLUDE_DIRS="$SRC/SDL3/include" > /dev/null
cmake --build "$SRC/build-sdl2c" > /dev/null
B2=$(find "$SRC/build-sdl2c" -name 'libSDL2-2.0*.dylib' -type f | head -n 1)
[ -n "$B2" ] || { echo "[sdl] libSDL2-2.0.dylib not built"; exit 1; }

SDL3_VERSION=$(awk '/#define SDL_(MAJOR|MINOR|MICRO)_VERSION/ {v = v (v ? "." : "") $3} END {print v}' \
               "$SRC/SDL3/include/SDL3/SDL_version.h")
plist() {  # plist <framework dir> <executable> <bundle id> <version>
  cat > "$1/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$2</string>
  <key>CFBundleIdentifier</key><string>$3</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$4</string>
  <key>CFBundleVersion</key><string>$4</string>
  <key>CFBundleSupportedPlatforms</key><array><string>XROS</string></array>
  <key>MinimumOSVersion</key><string>26.0</string>
</dict>
</plist>
PLIST
}
# SDL3: a flat framework (iOS-family layout), its binary and Info.plist only; headers are not shipped.
rm -rf "$FW/SDL3.framework" "$FW/SDL2.framework"
mkdir -p "$FW/SDL3.framework" "$FW/SDL2.framework"
cp "$B3/SDL3" "$FW/SDL3.framework/SDL3"
install_name_tool -id @rpath/SDL3.framework/SDL3 "$FW/SDL3.framework/SDL3"
plist "$FW/SDL3.framework" SDL3 org.libsdl.SDL3 "$SDL3_VERSION"
# sdl2-compat builds a bare dylib: wrapped as SDL2.framework, the path Klepton dlopens.
cp "$B2" "$FW/SDL2.framework/SDL2"
install_name_tool -id @rpath/SDL2.framework/SDL2 "$FW/SDL2.framework/SDL2"
plist "$FW/SDL2.framework" SDL2 org.libsdl.sdl2-compat "${SDL2C_TAG#release-}"
for l in LICENSE.txt; do
  [ -f "$SRC/SDL3/$l" ] && cp "$SRC/SDL3/$l" "$FW/SDL3.framework/LICENSE.txt"
  [ -f "$SRC/sdl2-compat/$l" ] && cp "$SRC/sdl2-compat/$l" "$FW/SDL2.framework/LICENSE.txt"
done
rm -f "$FW"/.sdl-*; touch "$STAMP"
echo "[sdl] -> $FW/SDL3.framework, $FW/SDL2.framework"
