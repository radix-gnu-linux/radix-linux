#!/bin/sh
set -eu
root=${1:-/}
etc="$root/etc"
system="$root/run/current-system/etc"
accounts="$root/var/lib/radix/accounts"
mkdir -p "$etc" "$accounts"

for n in passwd shadow group gshadow; do
  [ -e "$accounts/$n" ] || continue
  rm -rf "$etc/$n"
  ln -s "/var/lib/radix/accounts/$n" "$etc/$n"
done

mutable_dir() {
  case "$1" in init.d|runlevels|conf.d|pam.d|profile.d|sddm.conf.d|modprobe.d|sudoers.d) return 0;; *) return 1;; esac
}

if [ -d "$system" ]; then
  for src in "$system"/*; do
    [ -e "$src" ] || continue
    n=${src##*/}
    case "$n" in passwd|shadow|group|gshadow|profile) continue;; esac
    if mutable_dir "$n" && [ -d "$src" ]; then
      rm -rf "$etc/$n"
      mkdir -p "$etc/$n"
      cp -a "$src/." "$etc/$n/"
    else
      rm -rf "$etc/$n"
      ln -s "/run/current-system/etc/$n" "$etc/$n"
    fi
  done
fi
mkdir -p "$etc/radix"
cat > "$etc/profile" <<'PROFILE'
export RADIX_ROOT=/radix
export RADIX_REPOSITORY=/var/lib/radix/repository
export RADIX_SANDBOX=strict
export PATH=/radix/bin:/run/current-system/bin:/run/current-system/sbin
for f in /etc/profile.d/*.sh; do [ -r "$f" ] && . "$f"; done
unset f
PROFILE
chmod 0644 "$etc/profile"
cat > "$etc/radix/environment" <<'ENV'
RADIX_ROOT=/radix
RADIX_REPOSITORY=/var/lib/radix/repository
RADIX_SANDBOX=strict
ENV
chmod 0644 "$etc/radix/environment"
