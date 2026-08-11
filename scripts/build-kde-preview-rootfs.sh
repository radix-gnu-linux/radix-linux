#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=${BUILD:-$here/build}
out=$build/kde-preview
root=$out/rootfs
archive=$out/kde-preview-rootfs.tar.gz
mirror=${RADIX_PREVIEW_DEBIAN_MIRROR:-https://deb.debian.org/debian}
suite=${RADIX_PREVIEW_DEBIAN_SUITE:-sid}
sudo_cmd=${SUDO:-sudo}

command -v debootstrap >/dev/null 2>&1 || {
  echo 'debootstrap is required for the KDE bootstrap preview' >&2
  exit 1
}
command -v tar >/dev/null 2>&1 || { echo 'tar is required' >&2; exit 1; }
command -v gzip >/dev/null 2>&1 || { echo 'gzip is required' >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out"

echo "[preview] creating Debian $suite stage-0 root"
$sudo_cmd debootstrap \
  --arch=amd64 \
  --variant=minbase \
  --include=ca-certificates \
  "$suite" "$root" "$mirror"

cat <<EOF2 | $sudo_cmd tee "$root/etc/apt/sources.list" >/dev/null
deb $mirror $suite main contrib non-free non-free-firmware
EOF2

# Package postinst scripts must not try to start services inside the build
# chroot. The installer creates the OpenRC activation graph on the target.
$sudo_cmd install -d "$root/usr/sbin"
cat <<'EOF2' | $sudo_cmd tee "$root/usr/sbin/policy-rc.d" >/dev/null
#!/bin/sh
exit 101
EOF2
$sudo_cmd chmod 0755 "$root/usr/sbin/policy-rc.d"

# Keep package selection explicit. This payload is a temporary stage-0 bridge
# so people can install and test Radix with a real Plasma desktop while the
# native Radix Qt/KDE recipes are still being qualified.
packages='
openrc elogind libpam-elogind dbus polkitd udev seatd 
network-manager wpasupplicant iw wireless-regdb 
pipewire pipewire-pulse pipewire-alsa wireplumber libspa-0.2-bluetooth alsa-utils rtkit 
upower udisks2 bluez 
mesa-vulkan-drivers libgl1-mesa-dri libegl-mesa0 libgbm1 libdrm2 libinput10 xwayland mesa-utils vulkan-tools
kde-plasma-desktop plasma-workspace kwin-wayland plasma-nm plasma-pa 
powerdevil bluedevil kscreen sddm sddm-theme-breeze kde-config-sddm 
konsole dolphin kio-extras ark kate 
xdg-desktop-portal xdg-desktop-portal-kde xdg-user-dirs xdg-utils shared-mime-info 
fonts-noto-core fonts-noto-color-emoji fonts-dejavu-core fontconfig 
firmware-linux firmware-amd-graphics firmware-iwlwifi firmware-misc-nonfree firmware-nvidia-graphics 
firmware-realtek firmware-atheros firmware-brcm80211 firmware-mediatek firmware-sof-signed 
sudo passwd login bash bash-completion coreutils util-linux procps psmisc kmod dbus-x11 
iproute2 iputils-ping curl wget openssh-client rsync less nano 
e2fsprogs dosfstools btrfs-progs pciutils usbutils hwdata locales'

echo '[preview] installing KDE, OpenRC and hardware userspace'
$sudo_cmd chroot "$root" /usr/bin/env \
  DEBIAN_FRONTEND=noninteractive \
  APT_LISTCHANGES_FRONTEND=none \
  apt-get update
# shellcheck disable=SC2086
$sudo_cmd chroot "$root" /usr/bin/env \
  DEBIAN_FRONTEND=noninteractive \
  APT_LISTCHANGES_FRONTEND=none \
  apt-get install -y --no-install-recommends $packages

# Verify the payload before spending time packing it. These are the concrete
# runtime entry points setup-radix depends on after reboot.
for rel in \
  usr/sbin/openrc-init \
  usr/bin/startplasma-wayland \
  usr/bin/kwin_wayland \
  usr/bin/sddm \
  usr/sbin/NetworkManager \
  usr/bin/pipewire \
  usr/bin/wireplumber \
  usr/bin/glxinfo \
  usr/bin/vulkaninfo; do
  [ -x "$root/$rel" ] || { echo "KDE preview payload is missing $rel" >&2; exit 1; }
done
find "$root/usr/lib" -path '*/security/pam_elogind.so' -type f -print -quit | grep -q . || {
  echo 'KDE preview payload is missing pam_elogind.so' >&2
  exit 1
}

# Export the ext4 formatter and its exact Debian runtime dependencies as a
# tiny live-installer tool root. The live rescue image stays static/BusyBox,
# while mkfs.ext4 can run directly from the mounted ISO before the target root
# exists. Nothing is taken from the GitHub runner at install time.
tools=$out/live-tools
tools_root=$tools/root
$sudo_cmd mkdir -p "$tools_root/usr/sbin" "$tools_root/etc"
copy_tool_path() {
  rel=$1
  src=$root$rel
  [ -e "$src" ] || { echo "preview live tool dependency missing: $rel" >&2; exit 1; }
  $sudo_cmd mkdir -p "$tools_root$(dirname "$rel")"
  $sudo_cmd cp -L "$src" "$tools_root$rel"
}
copy_tool_path /usr/sbin/mke2fs
for dep in $($sudo_cmd chroot "$root" /usr/bin/ldd /usr/sbin/mke2fs | awk '{for (i=1;i<=NF;i++) if ($i ~ /^\//) print $i}' | sort -u); do
  copy_tool_path "$dep"
done
if [ -f "$root/etc/mke2fs.conf" ]; then $sudo_cmd cp -L "$root/etc/mke2fs.conf" "$tools_root/etc/mke2fs.conf"; fi
$sudo_cmd chown -R "$(id -u):$(id -g)" "$tools"
mkdir -p "$tools/bin"
cat > "$tools/bin/mkfs.ext4" <<'LIVE_TOOL'
#!/bin/sh
set -eu
root=/run/radix-media/radix/tools/root
loader=
for p in "$root"/lib64/ld-linux-x86-64.so.2 "$root"/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 "$root"/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2; do
  [ -x "$p" ] && { loader=$p; break; }
done
[ -n "$loader" ] || { echo 'Radix live ext4 tool: dynamic loader missing' >&2; exit 1; }
export MKE2FS_CONFIG="$root/etc/mke2fs.conf"
exec "$loader" \
  --library-path "$root/lib/x86_64-linux-gnu:$root/usr/lib/x86_64-linux-gnu:$root/lib64" \
  "$root/usr/sbin/mke2fs" -t ext4 "$@"
LIVE_TOOL
chmod 0755 "$tools/bin/mkfs.ext4"

# openrc-init is PID 1 for this preview. systemd libraries/udev can still be
# present as runtime dependencies; systemd is not used as the init system.
$sudo_cmd ln -sfn /usr/sbin/openrc-init "$root/sbin/init"
$sudo_cmd mkdir -p "$root/etc/runlevels/sysinit" "$root/etc/runlevels/boot" "$root/etc/runlevels/default"

# SDDM should prefer Plasma Wayland. The target installer adds the actual
# OpenRC service scripts after copying this payload.
$sudo_cmd mkdir -p "$root/etc/sddm.conf.d"
cat <<'EOF2' | $sudo_cmd tee "$root/etc/sddm.conf.d/00-radix-preview.conf" >/dev/null
[General]
DisplayServer=wayland

[Theme]
Current=breeze
EOF2

# Leave machine identity and users to setup-radix.
$sudo_cmd rm -f "$root/etc/machine-id"
$sudo_cmd truncate -s 0 "$root/etc/machine-id"
$sudo_cmd rm -f "$root/usr/sbin/policy-rc.d"

# Trim caches and mutable machine state. This is a bootstrapping payload, not a
# second package repository embedded in the installed system.
$sudo_cmd rm -rf \
  "$root/var/lib/apt/lists"/* \
  "$root/var/cache/apt"/* \
  "$root/var/log"/* \
  "$root/tmp"/* \
  "$root/var/tmp"/*
$sudo_cmd mkdir -p "$root/var/lib/apt/lists/partial" "$root/var/cache/apt/archives/partial" "$root/var/log"

# Record exactly what the preview was assembled from. It intentionally tracks
# Debian sid so it is not a reproducible Radix-native package closure yet.
$sudo_cmd chroot "$root" dpkg-query -W -f='${Package}\t${Version}\n' \
  | LC_ALL=C sort > "$out/packages.tsv"
for pkg in plasma-desktop plasma-workspace kwin-wayland sddm openrc elogind network-manager pipewire wireplumber; do
  grep -E "^${pkg}[[:space:]]" "$out/packages.tsv" || true
done > "$out/desktop-versions.txt"

printf '%s\n' \
  'mode=kde-bootstrap-preview' \
  "suite=$suite" \
  "mirror=$mirror" \
  "built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$out/manifest"
cat "$out/desktop-versions.txt" >> "$out/manifest"

# /dev, /proc, /sys and /run are runtime mounts. Excluding them keeps the
# archive portable and avoids packaging transient build-chroot state.
echo '[preview] packing KDE userspace'
$sudo_cmd tar \
  --numeric-owner \
  --one-file-system \
  --exclude='./dev/*' \
  --exclude='./proc/*' \
  --exclude='./sys/*' \
  --exclude='./run/*' \
  -C "$root" -czf "$archive" .
$sudo_cmd chown "$(id -u):$(id -g)" "$archive"

( cd "$out" && sha256sum kde-preview-rootfs.tar.gz ) > "$archive.sha256"
chmod 0644 "$archive" "$archive.sha256" "$out/manifest" "$out/packages.tsv" "$out/desktop-versions.txt"

echo '[preview] KDE bootstrap payload ready:'
ls -lh "$archive"
cat "$out/desktop-versions.txt"
