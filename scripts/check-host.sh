#!/bin/sh
set -eu
mode=${1:-build}
missing=
for c in git make cc cpio tar xorriso grub-mkrescue grub-mkstandalone python3 sha256sum; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ "$mode" = bootstrap ]; then
  for c in janet gplc bwrap; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
fi
if [ "$mode" = vm ]; then
  for c in qemu-system-x86_64; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
fi
[ -z "$missing" ] || { echo "missing tools:$missing" >&2; exit 1; }
if [ "$(id -u)" -ne 0 ] && [ ! -w /radix 2>/dev/null ]; then
  echo 'note: release image construction uses canonical /radix/store; run with sudo or make /radix writable' >&2
fi
