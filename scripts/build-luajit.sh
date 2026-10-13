#!/usr/bin/env bash
# LuaJIT (interpreter only, GC64) for the visionOS device, as a static library.
# Alyx's libvscript calls the Lua C API through its PLT; Klepton binds those names to this
# build (runtime/linux/kl_lua.c). No JIT: visionOS forbids executable memory for this app.
# Usage: build-luajit.sh <output dir>   (e.g. build/deps)
#   -> <out>/lib/libluajit.a, <out>/include/luajit/{lua.h,lauxlib.h,lualib.h,luaconf.h,luajit.h,lua.hpp}
# Idempotent: skipped when the library and the stamp for the pinned revision are present.
set -euo pipefail
LUAJIT_REV=c6ffc141                         # same pin as Glovebox (engine/kit/build-kit.sh)
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
SRC="$OUT/src/LuaJIT"
STAMP="$OUT/lib/.luajit-$LUAJIT_REV"
if [ -f "$OUT/lib/libluajit.a" ] && [ -f "$STAMP" ]; then echo "[luajit] $LUAJIT_REV up to date"; exit 0; fi

if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$OUT/src"
  git clone -q https://github.com/LuaJIT/LuaJIT.git "$SRC"
fi
git -C "$SRC" fetch -q origin || true
git -C "$SRC" checkout -q -f "$LUAJIT_REV"
git -C "$SRC" clean -qfdx

XR="$(xcrun --sdk xros --show-sdk-path)"
echo "[luajit] building $LUAJIT_REV for arm64-apple-xros26.0 (no JIT, GC64)"
# HOST_CC builds the buildvm/minilua generators for the Mac; TARGET_* the library for the device.
make -C "$SRC" -s clean > /dev/null
make -C "$SRC" -s -j"$(sysctl -n hw.ncpu)" \
  HOST_CC="clang -arch arm64" CROSS="" TARGET_CC=clang \
  TARGET_FLAGS="-target arm64-apple-xros26.0 -isysroot $XR" TARGET_SYS=iOS \
  XCFLAGS="-DLUAJIT_ENABLE_GC64 -DLUAJIT_NO_UNWIND -DLUAJIT_DISABLE_JIT" BUILDMODE=static > /dev/null

mkdir -p "$OUT/lib" "$OUT/include/luajit"
cp "$SRC/src/libluajit.a" "$OUT/lib/libluajit.a"
for h in lua.h lauxlib.h lualib.h luaconf.h luajit.h lua.hpp; do cp "$SRC/src/$h" "$OUT/include/luajit/"; done
cp "$SRC/COPYRIGHT" "$OUT/include/luajit/COPYRIGHT"
rm -f "$OUT"/lib/.luajit-*; touch "$STAMP"
echo "[luajit] -> $OUT/lib/libluajit.a"
