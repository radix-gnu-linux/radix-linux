local u=require('util')
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

local function append_unique(dst,seen,values)
  for _,v in ipairs(values) do
    if not seen[v] then seen[v]=true; dst[#dst+1]=v end
  end
end

local function file_exists(path)
  if u and u.exists then return u.exists(path) end
  local f=io.open(path,'rb')
  if f then f:close(); return true end
  return false
end

function M.preview_rootfs()
  local p=os.getenv('RADIX_KDE_PREVIEW_ROOTFS') or '/run/radix-media/radix/payload/kde-preview-rootfs.tar.gz'
  return file_exists(p) and p or nil
end

function M.preview_available()
  return M.preview_rootfs()~=nil
end

function M.packages(cfg)
  if cfg.libc=='musl' then return {'base/busybox-musl'} end
  local out,seen={},{}
  append_unique(out,seen,base)
  -- A native KDE install is fully Radix-managed. The preview mode instead
  -- installs a prebuilt stage-0 KDE userspace after the Radix base generation.
  if cfg.desktop=='kde' and cfg.kde_mode~='preview' then append_unique(out,seen,kde) end
  if cfg.gpu_driver=='nvidia' and cfg.kde_mode~='preview' then append_unique(out,seen,nvidia) end
  return out
end

local function missing_from(repo,values)
  local out={}
  if not repo or repo=='' then
    for _,id in ipairs(values) do out[#out+1]=id end
    return out
  end
  local f=io.open(repo..'/pkgs/base/busybox.janet','rb')
  if not f then
    for _,id in ipairs(values) do out[#out+1]=id end
    return out
  end
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
function M.native_kde_available(repo) return #M.kde_missing(repo)==0 end

function M.kde_mode(repo)
  if M.native_kde_available(repo) then return 'native' end
  if M.preview_available() then return 'preview' end
  return nil
end

return M
