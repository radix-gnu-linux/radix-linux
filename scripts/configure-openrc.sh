#!/bin/sh
set -eu
[ $# -eq 5 ] || { echo "usage: $0 TARGET kde|console GPU-DRIVER USER KEYMAP" >&2; exit 2; }
target=$1 desktop=$2 gpu=$3 user=$4 keymap=$5
etc=$target/etc
system=$target/run/current-system
mkdir -p "$etc/init.d" "$etc/runlevels/sysinit" "$etc/runlevels/boot" "$etc/runlevels/default" \
         "$etc/profile.d" "$etc/sddm.conf.d" "$etc/pam.d" "$etc/modprobe.d" "$etc/conf.d"

boot_path() {
  case "$1" in "$target"/*) printf '/%s\n' "${1#"$target"/}";; *) printf '%s\n' "$1";; esac
}
find_exec() {
  for rel in "$@"; do
    [ -x "$system/$rel" ] && { boot_path "$system/$rel"; return 0; }
  done
  return 1
}
need_exec() {
  label=$1; shift
  value=$(find_exec "$@" || true)
  [ -n "$value" ] || { echo "Radix activation: required executable missing from system profile: $label" >&2; exit 1; }
  printf '%s\n' "$value"
}

openrc_run=$(need_exec openrc-run sbin/openrc-run)
dbus=$(need_exec dbus-daemon bin/dbus-daemon sbin/dbus-daemon)
dhcpcd=$(need_exec dhcpcd sbin/dhcpcd bin/dhcpcd)
seatd=$(need_exec seatd bin/seatd sbin/seatd)
busybox=$(need_exec busybox bin/busybox)

link_profile_init() {
  name=$1 level=$2
  [ -e "$system/etc/init.d/$name" ] || return 0
  rm -f "$etc/init.d/$name" "$etc/runlevels/$level/$name"
  ln -s "/run/current-system/etc/init.d/$name" "$etc/init.d/$name"
  ln -s "../../init.d/$name" "$etc/runlevels/$level/$name"
}

for s in devfs dmesg mdev; do link_profile_init "$s" sysinit; done
for s in hwclock modules sysctl hostname keymaps bootmisc root localmount loopback; do link_profile_init "$s" boot; done
for s in local; do link_profile_init "$s" default; done

cat > "$etc/init.d/radix-dbus" <<SERVICE
#!$openrc_run
description="D-Bus system message bus"
command="$dbus"
command_args="--system --nofork --nopidfile"
command_background=true
pidfile="/run/radix-dbus.pid"
depend() { need localmount; after bootmisc; }
start_pre() { checkpath -d -m 0755 /run/dbus; }
SERVICE
chmod 0755 "$etc/init.d/radix-dbus"
ln -sf ../../init.d/radix-dbus "$etc/runlevels/default/radix-dbus"

cat > "$etc/init.d/radix-network" <<SERVICE
#!$openrc_run
description="Radix network autoconfiguration"
command="$dhcpcd"
command_args="-B"
pidfile="/run/dhcpcd/pid"
depend() { need localmount; after modules; provide net; }
SERVICE
chmod 0755 "$etc/init.d/radix-network"
ln -sf ../../init.d/radix-network "$etc/runlevels/default/radix-network"

cat > "$etc/init.d/radix-seatd" <<SERVICE
#!$openrc_run
description="seatd seat management"
command="$seatd"
command_args="-g video"
pidfile="/run/seatd.pid"
depend() { need localmount; after radix-dbus; }
SERVICE
chmod 0755 "$etc/init.d/radix-seatd"
ln -sf ../../init.d/radix-seatd "$etc/runlevels/default/radix-seatd"

cat > "$etc/init.d/radix-getty" <<SERVICE
#!$openrc_run
description="Radix console login"
command="$busybox"
command_args="getty 38400 tty2"
command_background=true
pidfile="/run/radix-getty.pid"
depend() { after localmount; }
SERVICE
chmod 0755 "$etc/init.d/radix-getty"
ln -sf ../../init.d/radix-getty "$etc/runlevels/default/radix-getty"

if [ "$desktop" = kde ]; then
  sddm=$(need_exec sddm bin/sddm sbin/sddm)
  startplasma=$(need_exec startplasma-wayland bin/startplasma-wayland)
  kwin=$(need_exec kwin_wayland bin/kwin_wayland)
  need_exec pipewire bin/pipewire >/dev/null
  need_exec wireplumber bin/wireplumber >/dev/null
  elogind=$(need_exec elogind lib/elogind/elogind libexec/elogind usr/lib/elogind/elogind usr/libexec/elogind)
  polkitd=$(need_exec polkitd lib/polkit-1/polkitd libexec/polkit-1/polkitd usr/lib/polkit-1/polkitd usr/libexec/polkit-1/polkitd)

  networkmanager=$(need_exec NetworkManager sbin/NetworkManager bin/NetworkManager)
  udevd=$(need_exec udevd lib/udev/udevd sbin/udevd lib/systemd/systemd-udevd)
  udevadm=$(need_exec udevadm bin/udevadm sbin/udevadm)
  upowerd=$(need_exec upowerd libexec/upowerd lib/upower/upowerd sbin/upowerd)
  udisksd=$(need_exec udisksd libexec/udisks2/udisksd lib/udisks2/udisksd sbin/udisksd)
  bluetoothd=$(need_exec bluetoothd libexec/bluetooth/bluetoothd lib/bluetooth/bluetoothd sbin/bluetoothd)

  cat > "$etc/init.d/radix-udev" <<SERVICE
#!$openrc_run
description="eudev device manager"
command="$udevd"
command_args="--daemon"
pidfile="/run/udev/udevd.pid"
depend() { after devfs; before localmount radix-networkmanager radix-seatd; }
start_pre() { checkpath -d -m 0755 /run/udev; }
start_post() { "$udevadm" trigger --action=add; "$udevadm" settle; }
SERVICE
  chmod 0755 "$etc/init.d/radix-udev"
  ln -sf ../../init.d/radix-udev "$etc/runlevels/sysinit/radix-udev"

  rm -f "$etc/runlevels/default/radix-network"
  cat > "$etc/init.d/radix-networkmanager" <<SERVICE
#!$openrc_run
description="NetworkManager"
command="$networkmanager"
command_args="--no-daemon"
command_background=true
pidfile="/run/NetworkManager/radix.pid"
depend() { need radix-dbus; after radix-udev radix-polkit; provide net; }
start_pre() { checkpath -d -m 0755 /run/NetworkManager; echo 'Radix desktop: starting NetworkManager'; }
SERVICE
  chmod 0755 "$etc/init.d/radix-networkmanager"
  ln -sf ../../init.d/radix-networkmanager "$etc/runlevels/default/radix-networkmanager"

  cat > "$etc/init.d/radix-elogind" <<SERVICE
#!$openrc_run
description="elogind login and seat manager"
command="$elogind"
command_background=true
pidfile="/run/elogind.pid"
depend() { need radix-dbus; after localmount; }
start_pre() { echo 'Radix desktop: starting elogind'; }
SERVICE
  chmod 0755 "$etc/init.d/radix-elogind"
  ln -sf ../../init.d/radix-elogind "$etc/runlevels/default/radix-elogind"

  cat > "$etc/init.d/radix-polkit" <<SERVICE
#!$openrc_run
description="polkit authorization service"
command="$polkitd"
command_background=true
pidfile="/run/polkitd.pid"
depend() { need radix-dbus; after radix-elogind; }
start_pre() { echo 'Radix desktop: starting polkit'; }
SERVICE
  chmod 0755 "$etc/init.d/radix-polkit"
  ln -sf ../../init.d/radix-polkit "$etc/runlevels/default/radix-polkit"

  cat > "$etc/init.d/radix-bluetooth" <<SERVICE
#!$openrc_run
description="BlueZ Bluetooth service"
command="$bluetoothd"
command_args="--nodetach"
command_background=true
pidfile="/run/bluetoothd.pid"
depend() { need radix-dbus; after radix-udev localmount; }
SERVICE
  chmod 0755 "$etc/init.d/radix-bluetooth"
  ln -sf ../../init.d/radix-bluetooth "$etc/runlevels/default/radix-bluetooth"

  cat > "$etc/init.d/radix-sddm" <<SERVICE
#!$openrc_run
description="SDDM display manager"
command="$sddm"
command_background=true
pidfile="/run/sddm.pid"
depend() { need radix-dbus radix-elogind; after radix-polkit radix-seatd radix-networkmanager radix-bluetooth; }
start_pre() { echo 'Radix desktop: starting SDDM'; checkpath -d -m 0755 /run/sddm; }
SERVICE
  chmod 0755 "$etc/init.d/radix-sddm"
  ln -sf ../../init.d/radix-sddm "$etc/runlevels/default/radix-sddm"

  cat > "$etc/sddm.conf.d/10-radix.conf" <<SDDM
[General]
DisplayServer=wayland

[Wayland]
CompositorCommand=$kwin --drm --no-lockscreen --no-global-shortcuts --locale1

[Theme]
Current=breeze
SDDM

  cat > "$etc/pam.d/sddm" <<'PAM'
auth       required     pam_unix.so
account    required     pam_unix.so
password   required     pam_unix.so
session    required     pam_unix.so
session    optional     pam_elogind.so
PAM
  cp "$etc/pam.d/sddm" "$etc/pam.d/sddm-autologin"

  cat > "$etc/profile.d/radix-desktop.sh" <<'PROFILE'
export XDG_DATA_DIRS=/run/current-system/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}
export XDG_CONFIG_DIRS=/etc/xdg:/run/current-system/etc/xdg${XDG_CONFIG_DIRS:+:$XDG_CONFIG_DIRS}
export QT_QPA_PLATFORM=wayland
export QT_QPA_PLATFORMTHEME=kde
export XDG_CURRENT_DESKTOP=KDE
PROFILE
  chmod 0644 "$etc/profile.d/radix-desktop.sh"
fi

if [ "$gpu" = nvidia ]; then
  cat > "$etc/modprobe.d/nvidia.conf" <<'NVIDIA'
options nvidia_drm modeset=1 fbdev=1
NVIDIA
fi

cat > "$etc/conf.d/keymaps" <<EOF2
keymap="$keymap"
windowkeys="YES"
extended_keymaps=""
EOF2
chmod 0644 "$etc/conf.d/keymaps"

mkdir -p "$etc/radix"
cat > "$etc/radix/desktop.conf" <<EOF2
desktop=$desktop
gpu_driver=$gpu
user=$user
EOF2
chmod 0644 "$etc/radix/desktop.conf"
