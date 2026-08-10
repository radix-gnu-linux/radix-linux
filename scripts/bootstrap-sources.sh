#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache=${RADIX_SOURCE_CACHE:-$here/.cache/sources}
radix_repo=${RADIX_REPOSITORY_URL:-https://github.com/radix-gnu-linux/radix.git}
packages_repo=${RADIX_PACKAGES_URL:-https://github.com/radix-gnu-linux/radix-packages.git}
mkdir -p "$cache"

sync_repo() {
  url=$1 dst=$2 name=$3
  if [ -d "$dst/.git" ]; then
    echo "[bootstrap] updating $name" >&2
    git -C "$dst" fetch --depth=1 origin main
    git -C "$dst" reset --hard origin/main
  else
    rm -rf "$dst"
    echo "[bootstrap] cloning $name" >&2
    git clone --depth=1 "$url" "$dst"
  fi
}

sync_repo "$radix_repo" "$cache/radix" radix
sync_repo "$packages_repo" "$cache/radix-packages" radix-packages

if [ ! -x "$cache/radix/build/radix" ]; then
  echo '[bootstrap] building Radix' >&2
  make -C "$cache/radix" -j"${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}" build
fi

printf 'RADIX=%s\nPACKAGES=%s\n' "$cache/radix/build/radix" "$cache/radix-packages"
