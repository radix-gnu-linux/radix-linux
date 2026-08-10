#!/bin/sh
set -eu
[ $# -ge 3 ] && [ $# -le 4 ] || { echo "usage: $0 TARGET ROOT-DEVICE OUTPUT [ROOT-PARTUUID]" >&2; exit 2; }
target=$1; rootdev=$2; output=$3; root_partuuid=${4:-}
bb="$target/radix/profiles/system/bin/busybox"
[ -x "$bb" ] || { echo "static BusyBox missing: $bb" >&2; exit 1; }
if command -v file >/dev/null 2>&1 && file "$bb" | grep -q 'dynamically linked'; then
  echo "refusing dynamic BusyBox in disk initramfs" >&2; exit 1
fi
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p "$tmp"/bin "$tmp"/dev "$tmp"/proc "$tmp"/sys "$tmp"/newroot "$tmp"/run
cp "$bb" "$tmp/bin/busybox"
for app in sh mount mkdir mdev switch_root sleep cat echo blkid ln tr; do ln -s busybox "$tmp/bin/$app"; done
cat > "$tmp/init" <<'__INIT__'
#!/bin/sh
export PATH=/bin
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mdev -s 2>/dev/null || true
exec </dev/console >/dev/console 2>&1
rootarg=
fallback=
for x in $(cat /proc/cmdline); do
  case "$x" in
    root=*) rootarg=${x#root=};;
    radix.rootdev=*) fallback=${x#radix.rootdev=};;
  esac
done
[ -n "$rootarg" ] || rootarg='__ROOTARG__'
[ -n "$fallback" ] || fallback='__ROOTDEV__'
resolve_partuuid() {
  wanted=${1#PARTUUID=}
  wanted=$(printf '%s' "$wanted" | tr A-F a-f)
  i=0
  while [ $i -lt 10 ]; do
    mdev -s 2>/dev/null || true
    for d in /dev/*; do
      [ -b "$d" ] || continue
      info=$(blkid "$d" 2>/dev/null | tr A-F a-f || true)
      case "$info" in *"partuuid=\"$wanted\""*) printf '%s\n' "$d"; return 0;; esac
    done
    sleep 1; i=$((i+1))
  done
  return 1
}
case "$rootarg" in
  PARTUUID=*) rootdev=$(resolve_partuuid "$rootarg" || true);;
  /dev/*) rootdev=$rootarg;;
  *) rootdev=;;
esac
if [ -z "$rootdev" ] || [ ! -b "$rootdev" ]; then
  echo "Radix: could not resolve $rootarg; trying installer device $fallback"
  rootdev=$fallback
fi
i=0
while [ ! -b "$rootdev" ] && [ $i -lt 50 ]; do mdev -s 2>/dev/null || true; sleep 1; i=$((i+1)); done
[ -b "$rootdev" ] || { echo "Radix: root device not found: $rootdev"; exec sh; }
mkdir -p /newroot
mount -o rw "$rootdev" /newroot || { echo "Radix: cannot mount $rootdev"; exec sh; }
mkdir -p /newroot/run
mount -t tmpfs -o mode=0755 tmpfs /newroot/run || { echo 'Radix: cannot mount /run'; exec sh; }
ln -s /radix/profiles/system /newroot/run/current-system
mount --move /dev /newroot/dev 2>/dev/null || true
mount --move /proc /newroot/proc 2>/dev/null || true
mount --move /sys /newroot/sys 2>/dev/null || true
if [ -e /newroot/etc/radix/kde-bootstrap-preview ]; then
  for preview_init in /usr/sbin/openrc-init /sbin/openrc-init /sbin/init; do
    if [ -x "/newroot$preview_init" ]; then
      echo "Radix: switching to KDE bootstrap preview ($preview_init)"
      exec switch_root /newroot "$preview_init"
    fi
  done
  echo 'Radix: KDE bootstrap preview marker exists but no OpenRC init was found'
  exec sh
fi
echo 'Radix: switching to installed system'
exec switch_root /newroot /radix/profiles/system/init
__INIT__
rootarg=$rootdev
[ -n "$root_partuuid" ] && rootarg="PARTUUID=$root_partuuid"
sed -i "s#__ROOTARG__#$rootarg#g; s#__ROOTDEV__#$rootdev#g" "$tmp/init"; chmod 0755 "$tmp/init"
mknod -m 600 "$tmp/dev/console" c 5 1 2>/dev/null || true
mknod -m 666 "$tmp/dev/null" c 1 3 2>/dev/null || true
mkdir -p "$(dirname "$output")"
( cd "$tmp" && find . -print | LC_ALL=C sort | cpio -o -H newc ) > "$output"
chmod 0644 "$output"
