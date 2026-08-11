#!/bin/sh
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=${BUILD:-$here/build}
out=$build/kde-preview
root=$out/rootfs
archive=$out/kde-preview-rootfs.tar.gz
mirror=${RADIX_PREVIEW_DEBIAN_MIRROR:-https://deb.debian.org/debian}
# The bootstrap payload should be stable enough for CI. Native Radix packages
# remain the long-term source of truth; this Debian root is only a stage-0 bridge.
suite=${RADIX_PREVIEW_DEBIAN_SUITE:-trixie}
sudo_cmd=${SUDO:-sudo}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 is required for the KDE bootstrap preview" >&2
    exit 1
  }
}

need debootstrap
need tar
need gzip
need mount
need umount

# Clean up a previous interrupted build safely before replacing the output.
if [ -d "$root" ]; then
  $sudo_cmd umount -R "$root/run" 2>/dev/null || true
  $sudo_cmd umount -R "$root/sys" 2>/dev/null || true
  $sudo_cmd umount -R "$root/dev" 2>/dev/null || true
  $sudo_cmd umount "$root/proc" 2>/dev/null || true
fi
$sudo_cmd rm -rf "$out"
mkdir -p "$out"

mounted=0
cleanup_mounts() {
  [ "$mounted" -eq 1 ] || return 0

  echo '[preview] unmounting chroot runtime filesystems'
  $sudo_cmd umount -R "$root/run" 2>/dev/null || true
  $sudo_cmd umount -R "$root/sys" 2>/dev/null || true
  $sudo_cmd umount -R "$root/dev" 2>/dev/null || true
  $sudo_cmd umount "$root/proc" 2>/dev/null || true
  mounted=0
}

on_exit() {
  status=$?
  trap - 0 INT TERM
  cleanup_mounts
  exit "$status"
}

trap on_exit 0
trap 'exit 130' INT
trap 'exit 143' TERM

chroot_env() {
  $sudo_cmd chroot "$root" /usr/bin/env \
    DEBIAN_FRONTEND=noninteractive \
    APT_LISTCHANGES_FRONTEND=none \
    LC_ALL=C.UTF-8 \
    "$@"
}

dump_package_failure() {
  echo >&2
  echo '================ KDE preview package diagnostics ================' >&2

  echo >&2
  echo '--- dpkg --audit ---' >&2
  chroot_env dpkg --audit >&2 2>&1 || true

  echo >&2
  echo '--- apt-get check ---' >&2
  chroot_env apt-get check >&2 2>&1 || true

  if [ -f "$root/var/log/apt/term.log" ]; then
    echo >&2
    echo '--- /var/log/apt/term.log (last 300 lines) ---' >&2
    $sudo_cmd tail -n 300 "$root/var/log/apt/term.log" >&2 || true
  fi

  if [ -f "$root/var/log/dpkg.log" ]; then
    echo >&2
    echo '--- /var/log/dpkg.log (last 300 lines) ---' >&2
    $sudo_cmd tail -n 300 "$root/var/log/dpkg.log" >&2 || true
  fi

  echo '==================================================================' >&2
}

configure_pending() {
  echo '[preview] configuring pending packages'
  if ! chroot_env dpkg --configure -a; then
    dump_package_failure
    return 1
  fi

  if ! chroot_env apt-get check; then
    dump_package_failure
    return 1
  fi
}

apt_install_group() {
  label=$1
  shift

  echo "[preview] installing $label"
  if chroot_env apt-get install \
      -y \
      --no-install-recommends \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "$@"; then
    configure_pending
    return 0
  fi

  # Preserve the first failure before attempting a controlled repair. The
  # repair is not ignored: the build still fails unless dpkg becomes clean and
  # the exact requested package set can subsequently be installed successfully.
  echo "[preview] initial $label transaction failed; collecting diagnostics" >&2
  dump_package_failure

  echo "[preview] attempting one controlled dpkg/apt repair for $label" >&2
  chroot_env dpkg --configure -a || true
  if ! chroot_env apt-get \
      -y \
      -f install \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold; then
    dump_package_failure
    return 1
  fi

  if ! chroot_env dpkg --configure -a; then
    dump_package_failure
    return 1
  fi

  echo "[preview] verifying requested $label packages after repair"
  if ! chroot_env apt-get install \
      -y \
      --no-install-recommends \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "$@"; then
    dump_package_failure
    return 1
  fi

  configure_pending
}

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
# chroot. The installed Radix target receives its real OpenRC activation graph
# from setup-radix.
$sudo_cmd install -d "$root/usr/sbin"
cat <<'EOF2' | $sudo_cmd tee "$root/usr/sbin/policy-rc.d" >/dev/null
#!/bin/sh
exit 101
EOF2
$sudo_cmd chmod 0755 "$root/usr/sbin/policy-rc.d"

# Give maintainer scripts the normal kernel pseudo-filesystems they expect.
# Services are still prevented from starting by policy-rc.d.
echo '[preview] mounting chroot runtime filesystems'
$sudo_cmd mkdir -p "$root/proc" "$root/sys" "$root/dev" "$root/run"
# Mark cleanup active before the first mount so a failure halfway through the
# sequence cannot leak an earlier mount into the runner.
mounted=1
$sudo_cmd mount -t proc proc "$root/proc"
$sudo_cmd mount --rbind /dev "$root/dev"
$sudo_cmd mount --make-rslave "$root/dev"
$sudo_cmd mount --rbind /sys "$root/sys"
$sudo_cmd mount --make-rslave "$root/sys"
$sudo_cmd mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$root/run"
$sudo_cmd mkdir -p "$root/run/lock" "$root/run/udev" "$root/run/dbus"

echo '[preview] refreshing Debian package metadata'
chroot_env apt-get update

# Keep the bootstrap packages in smaller transactions. This prevents a single
# low-level maintainer-script failure from turning into an unreadable desktop-
# wide dependency cascade and makes the first broken layer obvious in CI.
apt_install_group 'base init and session services' \
  openrc \
  elogind \
  libpam-elogind \
  dbus \
  dbus-x11 \
  polkitd \
  udev \
  seatd \
  sudo \
  passwd \
  login \
  bash \
  bash-completion \
  coreutils \
  util-linux \
  procps \
  psmisc \
  kmod \
  locales

apt_install_group 'network, storage, Bluetooth and audio services' \
  network-manager \
  wpasupplicant \
  iw \
  wireless-regdb \
  pipewire \
  pipewire-pulse \
  pipewire-alsa \
  wireplumber \
  libspa-0.2-bluetooth \
  alsa-utils \
  rtkit \
  upower \
  udisks2 \
  bluez

apt_install_group 'graphics and Wayland userspace' \
  mesa-vulkan-drivers \
  libgl1-mesa-dri \
  libegl-mesa0 \
  libgbm1 \
  libdrm2 \
  libinput10 \
  xwayland \
  mesa-utils \
  vulkan-tools

apt_install_group 'KDE Plasma desktop' \
  kde-plasma-desktop \
  plasma-workspace \
  kwin-wayland \
  plasma-nm \
  plasma-pa \
  powerdevil \
  bluedevil \
  kscreen \
  sddm \
  sddm-theme-breeze \
  kde-config-sddm \
  konsole \
  dolphin \
  kio-extras \
  ark \
  kate \
  xdg-desktop-portal \
  xdg-desktop-portal-kde \
  xdg-user-dirs \
  xdg-utils \
  shared-mime-info \
  fonts-noto-core \
  fonts-noto-color-emoji \
  fonts-dejavu-core \
  fontconfig

apt_install_group 'firmware and installer utilities' \
  firmware-linux \
  firmware-amd-graphics \
  firmware-iwlwifi \
  firmware-misc-nonfree \
  firmware-nvidia-graphics \
  firmware-realtek \
  firmware-atheros \
  firmware-brcm80211 \
  firmware-mediatek \
  firmware-sof-signed \
  iproute2 \
  iputils-ping \
  curl \
  wget \
  openssh-client \
  rsync \
  less \
  nano \
  e2fsprogs \
  dosfstools \
  btrfs-progs \
  pciutils \
  usbutils \
  hwdata

# Configure a usable default locale for the temporary desktop payload.
printf '%s\n' 'en_US.UTF-8 UTF-8' | $sudo_cmd tee "$root/etc/locale.gen" >/dev/null
chroot_env locale-gen en_US.UTF-8
chroot_env update-locale LANG=en_US.UTF-8

# Final package-database gate. A preview root with pending/broken packages must
# never be packed into an ISO.
configure_pending

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
  [ -x "$root/$rel" ] || {
    echo "KDE preview payload is missing $rel" >&2
    exit 1
  }
done

find "$root/usr/lib" -path '*/security/pam_elogind.so' -type f -print -quit | grep -q . || {
  echo 'KDE preview payload is missing pam_elogind.so' >&2
  exit 1
}

# Export the ext4 formatter and its exact Debian runtime dependencies as a tiny
# live-installer tool root. The live rescue image stays static/BusyBox, while
# mkfs.ext4 can run directly from the mounted ISO before the target root exists.
tools=$out/live-tools
tools_root=$tools/root
$sudo_cmd mkdir -p "$tools_root/usr/sbin" "$tools_root/etc"

copy_tool_path() {
  rel=$1
  src=$root$rel
  [ -e "$src" ] || {
    echo "preview live tool dependency missing: $rel" >&2
    exit 1
  }
  $sudo_cmd mkdir -p "$tools_root$(dirname "$rel")"
  $sudo_cmd cp -L "$src" "$tools_root$rel"
}

copy_tool_path /usr/sbin/mke2fs
for dep in $($sudo_cmd chroot "$root" /usr/bin/ldd /usr/sbin/mke2fs | awk '{for (i=1;i<=NF;i++) if ($i ~ /^\//) print $i}' | sort -u); do
  copy_tool_path "$dep"
done

if [ -f "$root/etc/mke2fs.conf" ]; then
  $sudo_cmd cp -L "$root/etc/mke2fs.conf" "$tools_root/etc/mke2fs.conf"
fi

$sudo_cmd chown -R "$(id -u):$(id -g)" "$tools"
mkdir -p "$tools/bin"
cat > "$tools/bin/mkfs.ext4" <<'LIVE_TOOL'
#!/bin/sh
set -eu
root=/run/radix-media/radix/tools/root
loader=
for p in \
  "$root"/lib64/ld-linux-x86-64.so.2 \
  "$root"/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
  "$root"/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2; do
  [ -x "$p" ] && { loader=$p; break; }
done
[ -n "$loader" ] || {
  echo 'Radix live ext4 tool: dynamic loader missing' >&2
  exit 1
}
export MKE2FS_CONFIG="$root/etc/mke2fs.conf"
exec "$loader" \
  --library-path "$root/lib/x86_64-linux-gnu:$root/usr/lib/x86_64-linux-gnu:$root/lib64" \
  "$root/usr/sbin/mke2fs" -t ext4 "$@"
LIVE_TOOL
chmod 0755 "$tools/bin/mkfs.ext4"

# openrc-init is PID 1 for this preview. systemd libraries and udev may still be
# present as runtime dependencies, but systemd is not selected as the init.
$sudo_cmd ln -sfn /usr/sbin/openrc-init "$root/sbin/init"
$sudo_cmd mkdir -p \
  "$root/etc/runlevels/sysinit" \
  "$root/etc/runlevels/boot" \
  "$root/etc/runlevels/default"

# SDDM should prefer Plasma Wayland. setup-radix adds the actual OpenRC service
# activation on the installed target.
$sudo_cmd mkdir -p "$root/etc/sddm.conf.d"
cat <<'EOF2' | $sudo_cmd tee "$root/etc/sddm.conf.d/00-radix-preview.conf" >/dev/null
[General]
DisplayServer=wayland

[Theme]
Current=breeze
EOF2

# Package configuration is finished. Remove temporary service suppression and
# runtime mounts before recording or packing the filesystem.
$sudo_cmd rm -f "$root/usr/sbin/policy-rc.d"
cleanup_mounts

# Leave machine identity and users to setup-radix.
$sudo_cmd rm -f "$root/etc/machine-id"
$sudo_cmd truncate -s 0 "$root/etc/machine-id"

# Record exactly what the bootstrap contains before removing package logs/caches.
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

# Keep copies of package-manager logs outside the root so CI can upload them
# even after the rootfs itself is trimmed.
mkdir -p "$out/logs"
if [ -f "$root/var/log/apt/term.log" ]; then
  $sudo_cmd cp "$root/var/log/apt/term.log" "$out/logs/apt-term.log"
fi
if [ -f "$root/var/log/dpkg.log" ]; then
  $sudo_cmd cp "$root/var/log/dpkg.log" "$out/logs/dpkg.log"
fi
$sudo_cmd chown -R "$(id -u):$(id -g)" "$out/logs"

# Trim caches and mutable machine state. This is a bootstrap payload, not a
# second package repository embedded in the installed system.
$sudo_cmd rm -rf \
  "$root/var/lib/apt/lists"/* \
  "$root/var/cache/apt"/* \
  "$root/var/log"/* \
  "$root/tmp"/* \
  "$root/var/tmp"/*
$sudo_cmd mkdir -p \
  "$root/var/lib/apt/lists/partial" \
  "$root/var/cache/apt/archives/partial" \
  "$root/var/log"

# /dev, /proc, /sys and /run are runtime mounts and are empty here after the
# cleanup above. Exclusions are retained as a safety belt.
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
chmod 0644 \
  "$archive" \
  "$archive.sha256" \
  "$out/manifest" \
  "$out/packages.tsv" \
  "$out/desktop-versions.txt"

echo '[preview] KDE bootstrap payload ready:'
ls -lh "$archive"
cat "$out/desktop-versions.txt"
