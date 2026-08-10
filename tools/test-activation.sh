#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT INT TERM
mkdir -p "$t/run/current-system/etc/init.d" "$t/run/current-system/bin" "$t/run/current-system/sbin" \
         "$t/run/current-system/lib/elogind" "$t/run/current-system/lib/polkit-1"
for s in devfs hostname local; do : > "$t/run/current-system/etc/init.d/$s"; done
for f in \
  sbin/openrc-run sbin/dhcpcd \
  bin/dbus-daemon bin/seatd bin/busybox bin/sddm bin/startplasma-wayland \
  bin/kwin_wayland bin/pipewire bin/wireplumber bin/udevadm \
  sbin/NetworkManager sbin/upowerd sbin/udisksd sbin/bluetoothd \
  lib/udev/udevd lib/elogind/elogind lib/polkit-1/polkitd
do
  mkdir -p "$t/run/current-system/$(dirname "$f")"
  : > "$t/run/current-system/$f"
  chmod 0755 "$t/run/current-system/$f"
done
"$here/scripts/configure-openrc.sh" "$t" kde mesa tester us
[ -L "$t/etc/runlevels/default/radix-sddm" ]
[ -L "$t/etc/runlevels/default/radix-dbus" ]
[ -L "$t/etc/runlevels/default/radix-elogind" ]
[ -L "$t/etc/runlevels/default/radix-polkit" ]
[ -L "$t/etc/runlevels/sysinit/radix-udev" ]
[ -L "$t/etc/runlevels/default/radix-networkmanager" ]
[ ! -e "$t/etc/runlevels/default/radix-network" ]
[ -L "$t/etc/runlevels/default/radix-bluetooth" ]
grep -q 'Radix desktop: starting SDDM' "$t/etc/init.d/radix-sddm"
grep -q 'Radix desktop: starting elogind' "$t/etc/init.d/radix-elogind"
grep -q 'Radix desktop: starting polkit' "$t/etc/init.d/radix-polkit"
grep -q 'keymap="us"' "$t/etc/conf.d/keymaps"
grep -q 'DisplayServer=wayland' "$t/etc/sddm.conf.d/10-radix.conf"
grep -q 'kwin_wayland' "$t/etc/sddm.conf.d/10-radix.conf"
grep -q 'QT_QPA_PLATFORM=wayland' "$t/etc/profile.d/radix-desktop.sh"
echo 'desktop activation fixture: OK'
