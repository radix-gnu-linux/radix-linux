#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=${BUILD:-$here/build}; dist=${DIST:-$here/dist}
version=$(cat "$here/VERSION")
[ -f "$build/vmlinuz" ] && [ -f "$build/live-initrd" ] || { echo 'run make live first' >&2; exit 1; }
iso="$build/iso-root"; rm -rf "$iso"; mkdir -p "$iso/boot/grub" "$dist"
cp "$build/vmlinuz" "$iso/boot/vmlinuz"
cp "$build/live-initrd" "$iso/boot/initrd"
cat > "$iso/boot/grub/grub.cfg" <<'EOF2'
set timeout=5
set default=0
menuentry 'Radix GNU/Linux - KDE installer' {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8 panic=-1
    initrd /boot/initrd
}
menuentry 'Radix GNU/Linux - safe console' {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8 nomodeset panic=-1
    initrd /boot/initrd
}
EOF2
name="radix-gnu-linux-${version}-x86_64.iso"
rm -f "$dist/$name" "$dist/radix-live.iso"
grub-mkrescue -o "$dist/$name" "$iso" >/dev/null
cp "$dist/$name" "$dist/radix-live.iso"
( cd "$dist" && sha256sum "$name" ) > "$dist/$name.sha256"
cp "$dist/$name.sha256" "$dist/radix-live.iso.sha256"
RADIX_LINUX_REV=unknown
RADIX_PACKAGES_REV=unknown
RADIX_REV=unknown
[ ! -f "$build/BUILD_INFO" ] || . "$build/BUILD_INFO"
cat > "$dist/build-info.json" <<EOF2
{"name":"Radix GNU/Linux","version":"$version","arch":"x86_64","firmware":"UEFI","default_desktop":"KDE Plasma 6.7.4","core_repository":"https://github.com/radix-gnu-linux/radix-linux","package_repository":"https://github.com/radix-gnu-linux/radix-packages","radix_linux_revision":"$RADIX_LINUX_REV","radix_packages_revision":"$RADIX_PACKAGES_REV","radix_revision":"$RADIX_REV"}
EOF2
echo "$dist/$name"
