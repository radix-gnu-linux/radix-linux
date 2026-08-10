local M={}

local base={
  'base/busybox', 'base/bash', 'libc/glibc',
  'libs/expat', 'libs/libffi', 'libs/libidn2', 'libs/libunistring',
  'libs/libxcrypt', 'libs/ncurses', 'libs/nghttp2', 'libs/openssl',
  'libs/zlib', 'libs/zstd', 'net/libnl',
  'system/openrc', 'system/pam', 'system/sudo', 'system/dbus',
  'system/linux-firmware', 'system/tzdata', 'system/seatd',
  'net/ca-certificates', 'net/dhcpcd', 'net/iw', 'net/wpa-supplicant',
  'net/wireless-regdb', 'net/curl', 'net/openssh',
  'audio/alsa-lib', 'audio/alsa-utils',
  'graphics/wayland', 'graphics/wayland-protocols', 'graphics/libdrm',
  'graphics/xkeyboard-config'
}

local kde={
  'graphics/mesa', 'graphics/libinput',
  'system/eudev', 'system/elogind', 'system/polkit', 'system/udisks2',
  'system/upower', 'system/bluez', 'system/rtkit',
  'net/network-manager', 'audio/pipewire', 'audio/wireplumber',
  'desktop/xdg-desktop-portal', 'desktop/xdg-desktop-portal-kde',
  'desktop/xdg-user-dirs', 'desktop/shared-mime-info',
  'fonts/freetype', 'fonts/fontconfig', 'fonts/noto',
  'qt/qtbase', 'qt/qtdeclarative', 'qt/qtwayland', 'qt/qtsvg',
  'kde-frameworks/extra-cmake-modules', 'kde-frameworks/kconfig',
  'kde-frameworks/kcoreaddons', 'kde-frameworks/ki18n', 'kde-frameworks/kio',
  'kde-frameworks/kirigami', 'kde-frameworks/kglobalaccel',
  'kde-frameworks/networkmanager-qt', 'kde-frameworks/bluez-qt',
  'kde-plasma/breeze', 'kde-plasma/kwin', 'kde-plasma/plasma-workspace',
  'kde-plasma/plasma-desktop', 'kde-plasma/plasma-nm', 'kde-plasma/plasma-pa',
  'kde-plasma/kscreen', 'kde-plasma/powerdevil', 'kde-plasma/bluedevil',
  'kde-apps/konsole', 'kde-apps/dolphin', 'desktop/sddm'
}

local nvidia={'drivers/nvidia'}

local function append_unique(dst, seen, values)
  for _,v in ipairs(values) do
    if not seen[v] then seen[v]=true; dst[#dst+1]=v end
  end
end

function M.packages(cfg)
  if cfg.libc=='musl' then return {'base/busybox-musl'} end
  local out,seen={},{}
  append_unique(out,seen,base)
  if cfg.desktop=='kde' then append_unique(out,seen,kde) end
  if cfg.gpu_driver=='nvidia' then append_unique(out,seen,nvidia) end
  return out
end

local function missing_from(repo,values)
  local out={}
  if not repo or repo=='' then return out end
  local f=io.open(repo..'/pkgs/base/busybox.janet','rb')
  if not f then return out end
  f:close()
  for _,id in ipairs(values) do
    local p=io.open(repo..'/pkgs/'..id..'.janet','rb')
    if p then p:close() else out[#out+1]=id end
  end
  return out
end

function M.base() local o={} for i,v in ipairs(base) do o[i]=v end return o end
function M.kde() local o={} for i,v in ipairs(kde) do o[i]=v end return o end
function M.nvidia() local o={} for i,v in ipairs(nvidia) do o[i]=v end return o end
function M.kde_missing(repo) return missing_from(repo,kde) end

return M
