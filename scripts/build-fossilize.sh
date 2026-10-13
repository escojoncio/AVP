#!/usr/bin/env bash
# Valve's Fossilize (MIT) for the visionOS device: the pipeline recorder/replayer behind
# runtime/linux/kl_fossilize.cpp (KL_VK_FOZ_RECORD / KL_VK_FOZ_REPLAY, kl_foz_prewarm).
# Usage: build-fossilize.sh <output dir>   (e.g. build/deps)
#   -> <out>/lib/libfossilize.a (Fossilize core + database + miniz)
#      <out>/include/fossilize/ (fossilize*.hpp, rapidjson/, vulkan/ + vk_video/ that Fossilize builds against)
# Klepton compiles kl_fossilize.cpp with -I<out>/include/fossilize (klepton/Makefile).
# Idempotent: skipped when the library and the stamp for the pinned revision are present.
set -euo pipefail
FOSSILIZE_REV=556da9f                       # same pin as Glovebox (engine/kit/build-kit.sh)
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
SRC="$OUT/src/Fossilize"
STAMP="$OUT/lib/.fossilize-$FOSSILIZE_REV"
if [ -f "$OUT/lib/libfossilize.a" ] && [ -f "$STAMP" ]; then echo "[fossilize] $FOSSILIZE_REV up to date"; exit 0; fi

if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$OUT/src"
  git clone -q https://github.com/ValveSoftware/Fossilize.git "$SRC"
fi
git -C "$SRC" fetch -q origin || true
git -C "$SRC" checkout -q -f "$FOSSILIZE_REV"
git -C "$SRC" submodule -q update --init --recursive

XR="$(xcrun --sdk xros --show-sdk-path)"
TGT=(-target arm64-apple-xros26.0 -isysroot "$XR" -O2 -g -fvisibility=hidden)
INC=(-I"$SRC" -I"$SRC/rapidjson/include" -I"$SRC/khronos" -I"$SRC/miniz")
OBJ="$OUT/src/fossilize-obj"
rm -rf "$OBJ"; mkdir -p "$OBJ"
echo "[fossilize] building $FOSSILIZE_REV for arm64-apple-xros26.0"
# Only what kl_fossilize.cpp needs: the state recorder/replayer, the .foz database, the
# application filter and their helpers. No layer, no CLI, no external replayer (fork/exec).
for f in fossilize.cpp fossilize_db.cpp varint.cpp path.cpp fossilize_application_filter.cpp; do
  xcrun --sdk xros clang++ -std=c++17 -fno-exceptions -Wno-unused-parameter "${TGT[@]}" "${INC[@]}" \
    -c "$SRC/$f" -o "$OBJ/${f%.cpp}.o"
done
xcrun --sdk xros clang "${TGT[@]}" -I"$SRC/miniz" -c "$SRC/miniz/miniz.c" -o "$OBJ/miniz.o"
mkdir -p "$OUT/lib"
rm -f "$OUT/lib/libfossilize.a"
xcrun --sdk xros ar rcs "$OUT/lib/libfossilize.a" "$OBJ"/*.o

H="$OUT/include/fossilize"
rm -rf "$H"; mkdir -p "$H"
cp "$SRC"/*.hpp "$SRC"/*.h "$H/" 2>/dev/null || cp "$SRC"/*.hpp "$H/"
cp -R "$SRC/rapidjson/include/rapidjson" "$H/rapidjson"
cp -R "$SRC/khronos/vulkan" "$H/vulkan"
[ -d "$SRC/khronos/vk_video" ] && cp -R "$SRC/khronos/vk_video" "$H/vk_video"
cp "$SRC/LICENSE" "$H/LICENSE-Fossilize"
[ -f "$SRC/miniz/LICENSE" ] && cp "$SRC/miniz/LICENSE" "$H/LICENSE-miniz"
[ -f "$SRC/rapidjson/license.txt" ] && cp "$SRC/rapidjson/license.txt" "$H/LICENSE-rapidjson"
rm -f "$OUT"/lib/.fossilize-*; touch "$STAMP"
echo "[fossilize] -> $OUT/lib/libfossilize.a"
