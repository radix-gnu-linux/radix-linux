#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=${BUILD:-$here/build}
dist=${DIST:-$here/dist}
command -v qemu-system-x86_64 >/dev/null 2>&1 || { echo 'qemu-system-x86_64 missing' >&2; exit 1; }
[ -f "$build/vmlinuz" ] && [ -f "$build/live-initrd" ] || { echo 'run make live first' >&2; exit 1; }
[ -f "$dist/radix-live.iso" ] || { echo 'run make iso-preview first; radix-live.iso is missing' >&2; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT INT TERM
disk="$work/radix-test.img"; truncate -s "${RADIX_INSTALL_DISK_SIZE:-20G}" "$disk"
install_log="$work/install.log"; boot_log="$work/boot.log"

# Phase one deliberately direct-boots the live kernel. FIRMWARE=uefi in the
# answer file still builds the target fallback ESP, and avoids depending on an
# OVMF package just to exercise the destructive installer.
set +e
timeout 600 qemu-system-x86_64 \
  -machine accel=kvm:tcg -m "${RADIX_VM_MEMORY:-4096M}" -smp "${RADIX_VM_CPUS:-2}" \
  -display none -serial stdio -no-reboot \
  -drive if=virtio,format=raw,file="$disk" \
  -drive if=none,id=radixiso,format=raw,readonly=on,file="$dist/radix-live.iso" \
  -device ide-cd,drive=radixiso \
  -kernel "$build/vmlinuz" -initrd "$build/live-initrd" \
  -append 'console=ttyS0 panic=-1 radix.autoinstall=1' 2>&1 | tee "$install_log"
rc=$?
set -e
if ! grep -q 'Radix automated install: PASS' "$install_log"; then
  echo 'automated install did not complete' >&2; exit 1
fi
[ "$rc" -eq 0 ] || [ "$rc" -eq 124 ] || true

find_ovmf() {
  for p in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.fd; do
    [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}
code=$(find_ovmf) || { echo 'OVMF firmware missing; install ovmf to qualify installed UEFI boot' >&2; exit 1; }
vars=
case "$code" in
  *_4M.fd) for p in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS_4M.ms.fd; do [ -f "$p" ] && { vars=$p; break; }; done;;
  *) for p in /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/x64/OVMF_VARS.fd; do [ -f "$p" ] && { vars=$p; break; }; done;;
esac
[ -n "$vars" ] || { echo 'OVMF vars template missing' >&2; exit 1; }
cp "$vars" "$work/vars.fd"

set +e
timeout 180 qemu-system-x86_64 \
  -machine accel=kvm:tcg -m "${RADIX_VM_MEMORY:-4096M}" -smp "${RADIX_VM_CPUS:-2}" \
  -display none -serial stdio -no-reboot \
  -drive if=pflash,format=raw,readonly=on,file="$code" \
  -drive if=pflash,format=raw,file="$work/vars.fd" \
  -drive if=virtio,format=raw,file="$disk" 2>&1 | tee "$boot_log"
rc=$?
set -e
if grep -q 'Radix: switching to KDE bootstrap preview' "$boot_log"; then
  if ! grep -q 'Radix desktop preview: starting SDDM' "$boot_log"; then
    echo 'installed preview disk reached OpenRC but did not activate SDDM' >&2; exit 1
  fi
elif grep -q 'Radix: switching to installed system' "$boot_log"; then
  if ! grep -q 'Radix GNU/Linux closed base system' "$boot_log"; then
    echo 'installed disk did not reach the native Radix system generation' >&2; exit 1
  fi
  if ! grep -q 'Radix desktop: starting SDDM' "$boot_log"; then
    echo 'installed native Radix system did not activate the KDE display-manager path' >&2; exit 1
  fi
else
  echo 'installed disk did not reach either Radix switch_root path' >&2; exit 1
fi
[ "$rc" -eq 0 ] || [ "$rc" -eq 124 ] || true
echo 'QEMU install + UEFI disk boot: PASS'
