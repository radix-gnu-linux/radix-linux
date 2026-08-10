#!/bin/sh
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=${BUILD:-$here/build}
radix=${RADIX:-$here/../radix/build/radix}
packages=${PACKAGES:-$here/../radix-packages}
require_kde=${RADIX_REQUIRE_KDE:-1}

"$here/scripts/check-host.sh" build

if [ ! -x "$radix" ] || [ ! -d "$packages/pkgs" ]; then
  command -v git >/dev/null 2>&1 || { echo 'git is required to bootstrap missing Radix sources' >&2; exit 1; }
  eval "$($here/scripts/bootstrap-sources.sh)"
  radix=$RADIX; packages=$PACKAGES
fi
[ -x "$radix" ] || { echo "radix executable not found: $radix" >&2; exit 1; }
[ -d "$packages/pkgs" ] || { echo "radix-packages checkout not found: $packages" >&2; exit 1; }
if command -v readelf >/dev/null 2>&1 && readelf -W -l "$radix" 2>/dev/null | grep -q INTERP; then
  echo 'refusing to embed a dynamically linked Radix binary in the live/install environment' >&2; exit 1
fi
command -v grub-mkstandalone >/dev/null 2>&1 || { echo 'grub-mkstandalone is needed to build the installer EFI image' >&2; exit 1; }
mkdir -p "$build"

check_recipe_file() {
  id=$1
  [ -f "$packages/pkgs/$id.janet" ] || return 1
}
check_profile() {
  file=$1 label=$2
  missing=
  while IFS= read -r id; do
    case "$id" in ''|'#'*) continue;; esac
    check_recipe_file "$id" || missing="$missing $id"
  done < "$file"
  if [ -n "$missing" ]; then
    echo "$label package contract is incomplete in radix-packages:" >&2
    for id in $missing; do echo "  - $id" >&2; done
    return 1
  fi
}
check_profile "$here/profiles/base.packages" 'base'
if [ "$require_kde" = 1 ]; then
  check_profile "$here/profiles/kde.packages" 'KDE Plasma' || {
    echo 'Refusing to build a release ISO without the complete KDE profile.' >&2
    echo 'For console-only bring-up, set RADIX_REQUIRE_KDE=0 explicitly.' >&2
    exit 1
  }
fi

export RADIX_ROOT=/radix RADIX_RUN_ROOT=/run RADIX_REPOSITORY="$packages" RADIX_ALLOW_HOST_BOOTSTRAP=1 RADIX_SANDBOX=strict
"$radix" system validate "$here/live/system.janet"

rm -rf "$build/core-boot"
"$radix" system image "$here/live/system.janet" "$build/core-boot"
cp "$build/core-boot/initrd" "$build/live-initrd"
cp "$build/core-boot/vmlinuz" "$build/vmlinuz"

roots_file="$build/installer-roots"
: > "$roots_file"
build_root() {
  id=$1 libc=${2:-glibc}
  echo "[payload] $id"
  path=$("$radix" build "$id" --libc="$libc" | tail -n 1)
  case "$path" in /radix/store/*) printf '%s\n' "$path" >> "$roots_file";; *) echo "could not capture store path for $id: $path" >&2; exit 1;; esac
}

build_root base/linux-stable glibc
while IFS= read -r id; do case "$id" in ''|'#'*) continue;; esac; build_root "$id" glibc; done < "$here/profiles/base.packages"
if [ "$require_kde" = 1 ]; then
  while IFS= read -r id; do case "$id" in ''|'#'*) continue;; esac; build_root "$id" glibc; done < "$here/profiles/kde.packages"
fi
if [ -f "$packages/pkgs/base/busybox-musl.janet" ]; then build_root base/busybox-musl musl; fi
if [ -f "$packages/pkgs/drivers/nvidia.janet" ]; then build_root drivers/nvidia glibc; fi

sort -u "$roots_file" -o "$roots_file"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT INT TERM
mkdir -p \
  "$tmp/radix-live/sbin" \
  "$tmp/radix-live/bin" \
  "$tmp/radix-live/boot" \
  "$tmp/radix-live/examples" \
  "$tmp/radix-live/core" \
  "$tmp/radix-live/packages" \
  "$tmp/root" \
  "$tmp/radix/store"
source_excludes="$tmp/source-excludes"
cat > "$source_excludes" <<'EOF_EXCLUDES'
./.git
./build
./dist
./cache
./.cache
./coverage
./htmlcov
./reports
./test-results
./.coverage
./.coverage.*
./.hypothesis
./.mypy_cache
./.nox
./.pytest_cache
./.ruff_cache
./.tox
./.scratch
./scratch
./local-work
./local-reports
./test-work
./test-output
./tests/local
./tests/generated
./tests/scratch
./tools/local
*.local.test
*.generated.test
*.test-output
./.idea
./.vscode
*/__pycache__
*.pyc
*.pyo
*.pyd
*.log
*.tmp
*.prof
coverage*.xml
junit*.xml
*.iso
*.img
*.qcow2
*.o
*.a
*.so
*.luac
.luacheckcache
.DS_Store
Thumbs.db
*~
*.swp
EOF_EXCLUDES
( cd "$here" && tar --exclude-from="$source_excludes" -cf - . ) | tar -xf - -C "$tmp/radix-live/core"
( cd "$packages" && tar --exclude-from="$source_excludes" -cf - . ) | tar -xf - -C "$tmp/radix-live/packages"
cp "$radix" "$tmp/radix-live/bin/radix"
ln -s ../core/sbin/setup-radix "$tmp/radix-live/sbin/setup-radix"
cp "$here/live/curl-compat" "$tmp/radix-live/bin/curl"; chmod 0755 "$tmp/radix-live/bin/curl"
cp -a "$here/examples/." "$tmp/radix-live/examples/"

git_rev() { git -C "$1" rev-parse HEAD 2>/dev/null || printf '%s\n' archive; }
radix_src=$(CDPATH= cd -- "$(dirname -- "$radix")/.." && pwd)
RADIX_LINUX_REV=$(git_rev "$here")
RADIX_PACKAGES_REV=$(git_rev "$packages")
RADIX_REV=$(git_rev "$radix_src")
cat > "$tmp/radix-live/BUILD_INFO" <<EOF3
RADIX_LINUX_REV=$RADIX_LINUX_REV
RADIX_PACKAGES_REV=$RADIX_PACKAGES_REV
RADIX_REV=$RADIX_REV
CORE_REPOSITORY=https://github.com/radix-gnu-linux/radix-linux
PACKAGES_REPOSITORY=https://github.com/radix-gnu-linux/radix-packages
RADIX_REPOSITORY=https://github.com/radix-gnu-linux/radix
DEFAULT_DESKTOP=kde
KDE_PLASMA=6.7.4
KDE_FRAMEWORKS=6.28.0
EOF3
cp "$tmp/radix-live/BUILD_INFO" "$build/BUILD_INFO"

cat "$roots_file" | while IFS= read -r root; do "$radix" store closure "$root"; done | sort -u | while IFS= read -r p; do
  case "$p" in /radix/store/*) [ -e "$tmp/radix/store/${p##*/}" ] || cp -a "$p" "$tmp/radix/store/${p##*/}";; esac
done

cat > "$tmp/embedded-grub.cfg" <<'EOF2'
search --no-floppy --label RADIX_ROOT --set=root
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
EOF2
grub-mkstandalone -O x86_64-efi -o "$tmp/radix-live/boot/BOOTX64.EFI" "boot/grub/grub.cfg=$tmp/embedded-grub.cfg"
cat > "$tmp/root/.profile" <<'EOF2'
export RADIX=/radix-live/bin/radix
export RADIX_PACKAGES=/radix-live/packages
export RADIX_LINUX_ROOT=/radix-live/core
export PATH=/radix-live/sbin:/radix-live/bin:/run/current-system/bin:/run/current-system/sbin
printf '\nRadix GNU/Linux live environment\n\n  setup-radix    Start the guided installer\n\n'
case " $(cat /proc/cmdline 2>/dev/null) " in
  *" radix.autoinstall=1 "*)
    echo 'Radix automated install: starting'
    if setup-radix --non-interactive --answers=/radix-live/examples/ci-install.conf; then
      echo 'Radix automated install: PASS'; sync; poweroff -f
    else
      echo 'Radix automated install: FAIL'
    fi
    ;;
esac
EOF2
( cd "$tmp" && find . -print0 | LC_ALL=C sort -z | cpio --null -o --format=newc --quiet ) >> "$build/live-initrd"
python3 "$here/tools/inspect-live-initrd.py" "$build/live-initrd"
echo "live tree ready: $build"
