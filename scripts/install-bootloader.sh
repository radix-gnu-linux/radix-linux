#!/bin/sh
set -eu
[ $# -ge 5 ] && [ $# -le 7 ] || { echo "usage: $0 TARGET DISK ROOT-DEVICE uefi|bios lts|stable [ROOT-PARTUUID] [SERIAL-CONSOLE-0|1]" >&2; exit 2; }
target=$1; disk=$2; rootdev=$3; firmware=$4; flavor=$5; root_partuuid=${6:-}; serial=${7:-0}
self=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
profile="$target/radix/profiles/system"; kernel="$profile/lib/radix/kernel/vmlinuz"
[ -f "$kernel" ] || { echo "kernel missing from system closure: $kernel" >&2; exit 1; }
mkdir -p "$target/boot/grub"; cp "$kernel" "$target/boot/vmlinuz-radix"
"$self/make-disk-initrd.sh" "$target" "$rootdev" "$target/boot/initrd-radix" "$root_partuuid"
rootarg=$rootdev
[ -n "$root_partuuid" ] && rootarg="PARTUUID=$root_partuuid"
console=
[ "$serial" = 1 ] && console=' console=tty0 console=ttyS0,115200n8'
cat > "$target/boot/grub/grub.cfg" <<EOF2
set timeout=5
set default=0
menuentry 'Radix GNU/Linux' {
    linux /boot/vmlinuz-radix root=$rootarg radix.rootdev=$rootdev rw$console
    initrd /boot/initrd-radix
}
menuentry 'Radix GNU/Linux (verbose)' {
    linux /boot/vmlinuz-radix root=$rootarg radix.rootdev=$rootdev rw loglevel=7$console
    initrd /boot/initrd-radix
}
EOF2
if [ "$firmware" = uefi ]; then
  src=${RADIX_BOOTX64:-/radix-live/boot/BOOTX64.EFI}
  [ -f "$src" ] || { echo "standalone Radix GRUB EFI image missing: $src" >&2; exit 1; }
  mkdir -p "$target/boot/efi/EFI/BOOT"
  cp "$src" "$target/boot/efi/EFI/BOOT/BOOTX64.EFI"
else
  command -v grub-install >/dev/null 2>&1 || { echo 'BIOS disk installation is staged but the closed live image does not carry grub-install yet' >&2; exit 1; }
  grub-install --target=i386-pc --boot-directory="$target/boot" --recheck "$disk"
fi
