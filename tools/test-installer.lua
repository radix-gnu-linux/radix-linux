local root=assert(arg[1], 'usage: test-installer.lua REPO_ROOT')
package.path=root..'/installer/lib/?.lua;'..package.path

package.loaded.probe={
  firmware=function() return 'uefi' end,
  disks=function() return {{path='/dev/vda',size='20 GiB',bytes=20*1024^3,logical_sector=512,model='Radix test disk'}} end,
  disk_label=function(d) return d.path..' '..d.size end,
  gpu=function() return 'virtio' end,
  memory_mib=function() return 4096 end,
}

local answers=require('answers')
local profile=require('profile')
-- This unit test is about installer configuration, not the sibling package
-- checkout. Model a complete native KDE channel explicitly.
profile.kde_missing=function() return {} end
profile.kde_mode=function() return 'native' end
local config=require('config')
local defaults=require('defaults')
local a=answers.load(root..'/examples/ci-install.conf')
-- The source-only unit test does not mount the ISO live-tools payload. Keep
-- filesystem selection on the BusyBox formatter here; the QEMU install gate
-- exercises FILESYSTEM=ext4 from the real answer file.
a.FILESYSTEM='ext2'
local c=config.collect(a,{target='/tmp/radix-target',dry_run=true,noninteractive=true})
assert(c.firmware=='uefi')
assert(c.disk=='/dev/vda')
assert(c.fs=='ext2')
assert(c.libc=='glibc')
assert(c.kernel=='lts')
assert(c.desktop=='kde')
assert(c.kde_mode=='native')
assert(c.gpu_driver=='mesa')
assert(c.serial_console==true)
assert(c.core_repository==defaults.core_repository)
assert(c.packages_repository==defaults.packages_repository)

local have={}
for _,id in ipairs(c.packages) do have[id]=true end
assert(have['system/openrc'])
assert(have['libc/glibc'])
assert(have['libs/openssl'])
assert(have['libs/ncurses'])
assert(have['kde-plasma/plasma-desktop'])
assert(have['desktop/sddm'])
assert(have['graphics/mesa'])
assert(have['audio/pipewire'])

-- When native KDE is incomplete but the ISO carries the bootstrap payload,
-- the installer must still choose KDE while keeping staged KDE recipes out of
-- the Radix base profile.
profile.kde_missing=function() return {'kde-plasma/plasma-desktop'} end
profile.kde_mode=function() return 'preview' end
local pconfig=config.collect(a,{target='/tmp/radix-target',dry_run=true,noninteractive=true})
assert(pconfig.desktop=='kde')
assert(pconfig.kde_mode=='preview')
assert(pconfig.gpu_driver=='mesa')
local phave={}
for _,id in ipairs(pconfig.packages) do phave[id]=true end
assert(phave['system/openrc'])
assert(phave['libc/glibc'])
assert(not phave['kde-plasma/plasma-desktop'])
assert(not phave['desktop/sddm'])

local out=os.tmpname()
config.system_manifest(c,out)
local f=assert(io.open(out)); local s=f:read('*a'); f:close(); os.remove(out)
assert(s:find(':hostname "radix%-ci"'))
assert(s:find(':init%-system :openrc'))
assert(s:find(':recipe "base/linux%-lts"'))
assert(s:find('"kde%-plasma/plasma%-desktop"'))
assert(s:find('"desktop/sddm"'))
print('installer config: OK')
