#!/bin/sh
set -eu
[ $# -eq 4 ] || { echo "usage: $0 TARGET GPU-DRIVER USER KEYMAP" >&2; exit 2; }
target=$1 gpu=$2 user=$3 keymap=$4
etc=$target/etc
mkdir -p "$etc/init.d" "$etc/runlevels/sysinit" "$etc/runlevels/boot" "$etc/runlevels/default" \
         "$etc/profile.d" "$etc/sddm.conf.d" "$etc/modprobe.d" "$etc/conf.d" "$etc/radix"

find_target_exec() {
  for p in "$@"; do
    [ -x "$target$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}
need_exec() {
  label=$1; shift
  p=$(find_target_exec "$@" || true)
  [ -n "$p" ] || { echo "KDE preview activation: missing $label" >&2; exit 1; }
  printf '%s\n' "$p"
}

openrc_run=$(need_exec openrc-run /usr/sbin/openrc-run /sbin/openrc-run)
dbus=$(need_exec dbus-daemon /usr/bin/dbus-daemon /bin/dbus-daemon)
udevd=$(need_exec udevd /usr/lib/systemd/systemd-udevd /lib/systemd/systemd-udevd /usr/sbin/udevd)
udevadm=$(need_exec udevadm /usr/bin/udevadm /bin/udevadm)
elogind=$(need_exec elogind /usr/lib/elogind/elogind /usr/libexec/elogind /usr/bin/elogind)
polkitd=$(need_exec polkitd /usr/lib/polkit-1/polkitd /usr/libexec/polkit-1/polkitd)
networkmanager=$(need_exec NetworkManager /usr/sbin/NetworkManager /usr/bin/NetworkManager)
bluetoothd=$(need_exec bluetoothd /usr/libexec/bluetooth/bluetoothd /usr/lib/bluetooth/bluetoothd /usr/sbin/bluetoothd)
sddm=$(need_exec sddm /usr/bin/sddm /usr/sbin/sddm)
startplasma=$(need_exec startplasma-wayland /usr/bin/startplasma-wayland)
need_exec pipewire /usr/bin/pipewire >/dev/null
need_exec wireplumber /usr/bin/wireplumber >/dev/null

# openrc-init is PID 1 in the bootstrap preview. The installed Radix initramfs
# chooses it only when /etc/radix/kde-bootstrap-preview exists.
openrc_init=$(need_exec openrc-init /usr/sbin/openrc-init /sbin/openrc-init)
ln -sfn "$openrc_init" "$target/sbin/init"

make_service() {
  name=$1
  level=$2
  shift 2
  cat > "$etc/init.d/$name"
  chmod 0755 "$etc/init.d/$name"
  ln -sfn "../../init.d/$name" "$etc/runlevels/$level/$name"
}

make_service radix-udev sysinit <<SERVICE
#!$openrc_run
description="Radix preview device manager"
command="$udevd"
command_args="--daemon"
pidfile="/run/udev/udevd.pid"
depend() { after devfs; before localmount; }
start_pre() { checkpath -d -m 0755 /run/udev; }
start_post() { "$udevadm" trigger --action=add; "$udevadm" settle; }
SERVICE

make_service radix-dbus default <<SERVICE
#!$openrc_run
description="D-Bus system bus"
command="$dbus"
command_args="--system --nofork --nopidfile"
command_background=true
pidfile="/run/radix-dbus.pid"
depend() { need localmount; after radix-udev; }
start_pre() { checkpath -d -m 0755 /run/dbus; }
SERVICE

make_service radix-elogind default <<SERVICE
#!$openrc_run
description="elogind login and seat manager"
command="$elogind"
command_background=true
pidfile="/run/elogind.pid"
depend() { need radix-dbus; after localmount radix-udev; }
SERVICE

make_service radix-polkit default <<SERVICE
#!$openrc_run
description="polkit authorization service"
command="$polkitd"
command_background=true
pidfile="/run/polkitd.pid"
depend() { need radix-dbus radix-elogind; }
SERVICE

make_service radix-networkmanager default <<SERVICE
#!$openrc_run
description="NetworkManager"
command="$networkmanager"
command_args="--no-daemon"
command_background=true
pidfile="/run/NetworkManager/radix.pid"
depend() { need radix-dbus; after radix-udev radix-polkit; provide net; }
start_pre() { checkpath -d -m 0755 /run/NetworkManager; }
SERVICE

make_service radix-bluetooth default <<SERVICE
#!$openrc_run
description="BlueZ Bluetooth service"
command="$bluetoothd"
command_args="--nodetach"
command_background=true
pidfile="/run/bluetoothd.pid"
depend() { need radix-dbus; after radix-udev localmount; }
SERVICE

make_service radix-sddm default <<SERVICE
#!$openrc_run
description="SDDM display manager"
command="$sddm"
command_background=true
pidfile="/run/sddm.pid"
depend() { need radix-dbus radix-elogind; after radix-polkit radix-networkmanager radix-bluetooth; }
start_pre() { echo 'Radix desktop preview: starting SDDM'; checkpath -d -m 0755 /run/sddm; }
SERVICE

make_service radix-getty default <<SERVICE
#!$openrc_run
description="Radix fallback console login"
command="/radix/profiles/system/bin/busybox"
command_args="getty 38400 tty2"
command_background=true
pidfile="/run/radix-getty.pid"
depend() { after localmount; }
SERVICE

cat > "$etc/sddm.conf.d/10-radix-preview.conf" <<SDDM
[General]
DisplayServer=wayland

[Theme]
Current=breeze
SDDM

# Debian packages may carry pam_systemd entries even when elogind is the
# selected logind implementation. Rewrite those entries for the preview.
for pam in "$etc/pam.d"/*; do
  [ -f "$pam" ] || continue
  if grep -q 'pam_systemd\.so' "$pam" 2>/dev/null; then
    sed -i 's/pam_systemd\.so/pam_elogind.so/g' "$pam"
  fi
done

# PipeWire normally uses user service activation on the source distribution.
# The preview deliberately avoids depending on a systemd user manager.
mkdir -p "$etc/xdg/autostart" "$target/usr/local/bin"
cat > "$target/usr/local/bin/radix-session-audio" <<'AUDIO'
#!/bin/sh
pgrep -x pipewire >/dev/null 2>&1 || pipewire >/tmp/radix-pipewire.log 2>&1 &
pgrep -x pipewire-pulse >/dev/null 2>&1 || pipewire-pulse >/tmp/radix-pipewire-pulse.log 2>&1 &
sleep 1
pgrep -x wireplumber >/dev/null 2>&1 || wireplumber >/tmp/radix-wireplumber.log 2>&1 &
AUDIO
chmod 0755 "$target/usr/local/bin/radix-session-audio"
cat > "$etc/xdg/autostart/radix-session-audio.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Radix PipeWire session
Exec=/usr/local/bin/radix-session-audio
NoDisplay=true
X-KDE-autostart-phase=0
DESKTOP

cat > "$etc/profile.d/radix-desktop.sh" <<'PROFILE'
export XDG_CURRENT_DESKTOP=KDE
export XDG_SESSION_DESKTOP=KDE
export KDE_FULL_SESSION=true
export QT_QPA_PLATFORM='wayland;xcb'
PROFILE
chmod 0644 "$etc/profile.d/radix-desktop.sh"

cat > "$etc/conf.d/keymaps" <<EOF2
keymap="$keymap"
windowkeys="YES"
extended_keymaps=""
EOF2

case "$gpu" in
  nouveau)
    cat > "$etc/modprobe.d/radix-gpu.conf" <<'GPU'
# Radix KDE bootstrap preview: use the in-tree Nouveau driver.
options nouveau modeset=1
GPU
    ;;
  mesa)
    cat > "$etc/modprobe.d/radix-gpu.conf" <<'GPU'
# Intel/AMD graphics use the in-tree DRM drivers and Mesa userspace.
GPU
    ;;
  nvidia)
    echo 'proprietary NVIDIA is not supported by the generic KDE bootstrap preview' >&2
    exit 1
    ;;
esac

cat > "$etc/radix/desktop.conf" <<EOF2
desktop=kde
desktop_source=bootstrap-preview
gpu_driver=$gpu
user=$user
EOF2
chmod 0644 "$etc/radix/desktop.conf"

# OpenRC default runlevel directories can be empty in the debootstrap root.
for dir in sysinit boot default; do mkdir -p "$etc/runlevels/$dir"; done

echo "Radix KDE bootstrap preview configured: $startplasma"
