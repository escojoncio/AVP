#!/usr/bin/env bash
# Offline VPKEngine shader check on Linux: VPVulkan (null backend) + Valve's fossilize-replay over a
# pipelines.foz recorded on the headset (<AVP folder>/Cache/pipelines.foz). Every SPIR-V module and
# pipeline goes through the same SPIR-V -> VPIR -> MSL path as on the device; translator errors print
# as `vk.err`. The .foz is game content: never commit it.
# Usage: shader-harness.sh <pipelines.foz> [work dir]
set -euo pipefail
FOZ="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
WORK="$(mkdir -p "${2:-build/harness}" && cd "${2:-build/harness}" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$WORK/vpkengine/.git" ] || git clone -q "https://github.com/escojoncio/VPKEngine.git" "$WORK/vpkengine"
git -C "$WORK/vpkengine" checkout -q -f "$(tr -d ' \n' < "$ROOT/vpkengine.ref")"
for p in "$ROOT"/vpkengine-patches/*.patch; do git -C "$WORK/vpkengine" -c user.email=ci@localhost -c user.name=ci am -q --3way "$p"; done
cmake -S "$WORK/vpkengine/gpu" -B "$WORK/vp" -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null
make -C "$WORK/vp" -j"$(nproc)" VPVulkan >/dev/null
if [ ! -x "$WORK/fz/build/cli/fossilize-replay" ]; then
  [ -d "$WORK/fz/.git" ] || git clone -q https://github.com/ValveSoftware/Fossilize.git "$WORK/fz"
  git -C "$WORK/fz" checkout -q 556da9f && git -C "$WORK/fz" submodule -q update --init --recursive
  # Replay every pipeline: the feature filter judges the null device, not the headset.
  sed -i 's/if (!device->get_feature_filter().graphics_pipeline_is_supported(/if (!getenv("FZ_NOFILTER") \&\& !device->get_feature_filter().graphics_pipeline_is_supported(/' "$WORK/fz/cli/fossilize_replay.cpp"
  cmake -S "$WORK/fz" -B "$WORK/fz/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
  make -C "$WORK/fz/build" -j"$(nproc)" fossilize-replay >/dev/null
fi
mkdir -p "$WORK/vkl" "$WORK/dump"
ln -sf "$WORK/vp/vulkan/libVPVulkan.so" "$WORK/vkl/libvulkan.so.1"
LD_LIBRARY_PATH="$WORK/vkl" FZ_NOFILTER=1 VPVK_FORCE_1X=1 VPVK_DUMP_DIR="$WORK/dump" \
  "$WORK/fz/build/cli/fossilize-replay" "$FOZ" --num-threads "$(nproc)" > "$WORK/replay.log" 2>&1 || true
echo "errors by kind:"
grep -o 'vk.err what=[a-z_]* .*error="[^"]*"' "$WORK/replay.log" | sed 's/pipeline=[^ ]* //' | sort | uniq -c | sort -rn || echo "  none"
grep "Fossilize INFO: Playing back" "$WORK/replay.log"
echo "failing modules (IR / SPIR-V): $WORK/dump"
