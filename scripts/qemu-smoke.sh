#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dist=${DIST:-$here/dist}; iso="$dist/radix-live.iso"
[ -f "$iso" ] || { echo 'ISO missing' >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo 'qemu-system-x86_64 missing' >&2; exit 1; }
log=$(mktemp); trap 'rm -f "$log"' EXIT INT TERM
set +e
timeout 45 qemu-system-x86_64 -m 1024 -smp 2 -cdrom "$iso" -boot d -display none -serial stdio -no-reboot 2>&1 | tee "$log"
rc=$?
set -e
if ! grep -q 'Radix GNU/Linux closed base system' "$log"; then
  echo 'QEMU never reached Radix PID 1 marker' >&2; exit 1
fi
if ! grep -q 'Radix rescue init selected' "$log"; then
  echo 'QEMU did not reach rescue init' >&2; exit 1
fi
echo 'QEMU live boot: PASS'
[ "$rc" -eq 0 ] || [ "$rc" -eq 124 ]
