#!/usr/bin/env bash
# Applies AVP's patches on top of the pinned VPEngine checkout (vpengine.ref).
# Usage: apply-vpengine-patches.sh <VPEngine checkout> <patch dir>
# Every *.patch in the patch dir is applied in sorted order; no patches is a no-op.
# Any patch that does not apply cleanly (or with a 3-way merge) fails the run.
set -euo pipefail
SRC="$1"
DIR="$2"
[ -d "$DIR" ] || { echo "no patch dir $DIR: nothing to apply"; exit 0; }
shopt -s nullglob
PATCHES=("$DIR"/*.patch)
[ ${#PATCHES[@]} -gt 0 ] || { echo "no patches in $DIR: nothing to apply"; exit 0; }
IFS=$'\n' SORTED=($(printf '%s\n' "${PATCHES[@]}" | LC_ALL=C sort)); unset IFS
for P in "${SORTED[@]}"; do
  ABS="$(cd "$(dirname "$P")" && pwd)/$(basename "$P")"
  echo "== $(basename "$P")"
  if git -C "$SRC" apply --check "$ABS" 2>/dev/null; then
    git -C "$SRC" apply "$ABS"
  elif git -C "$SRC" apply --3way "$ABS"; then
    if git -C "$SRC" diff --name-only --diff-filter=U | grep -q .; then
      echo "CONFLICT applying $(basename "$P"):"; git -C "$SRC" diff --name-only --diff-filter=U
      exit 1
    fi
  else
    echo "FAILED to apply $(basename "$P")"; exit 1
  fi
done
echo "applied ${#SORTED[@]} patch(es)"
