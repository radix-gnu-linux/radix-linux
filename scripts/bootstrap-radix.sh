#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src=${1:-$here/../radix}
prefix=${2:-/usr/local}
url=${RADIX_REPOSITORY_URL:-https://github.com/radix-gnu-linux/radix.git}
if [ ! -d "$src" ]; then
  src=${RADIX_BOOTSTRAP_SOURCE:-$here/.cache/sources/radix}
  mkdir -p "$(dirname "$src")"
  if [ -d "$src/.git" ]; then git -C "$src" pull --ff-only
  else git clone --depth=1 "$url" "$src"; fi
fi
"$here/scripts/check-host.sh" bootstrap
make -C "$src" -j"${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}" build
bin=${RADIX_BIN:-$src/build/radix}
[ -x "$bin" ] || { echo "built Radix binary not found: $bin" >&2; exit 1; }
"$bin" --version
install -Dm755 "$bin" "$prefix/bin/radix"
