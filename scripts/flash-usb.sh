#!/bin/sh
set -eu
[ $# -eq 2 ] || { echo "usage: $0 IMAGE /dev/WHOLE-DISK" >&2; exit 2; }
image=$1; disk=$2
[ -f "$image" ] || { echo "image not found: $image" >&2; exit 1; }
[ -b "$disk" ] || { echo "not a block device: $disk" >&2; exit 1; }
echo "THIS WILL OVERWRITE $disk" >&2
printf 'type the disk path again: ' >&2; read ans
[ "$ans" = "$disk" ] || exit 1
umount "${disk}"?* 2>/dev/null || true
dd if="$image" of="$disk" bs=16M conv=fsync status=progress
sync
