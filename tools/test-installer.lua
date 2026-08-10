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
local config=require('config')
local defaults=require('defaults')
local a=answers.load(root..'/examples/ci-install.conf')
local c=config.collect(a,{target='/tmp/radix-target',dry_run=true,noninteractive=true})
assert(c.firmware=='uefi')
assert(c.disk=='/dev/vda')
assert(c.fs=='ext2')
assert(c.libc=='glibc')
assert(c.kernel=='lts')
assert(c.desktop=='kde')
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

local out=os.tmpname()
config.system_manifest(c,out)
local f=assert(io.open(out)); local s=f:read('*a'); f:close(); os.remove(out)
assert(s:find(':hostname "radix%-ci"'))
assert(s:find(':init%-system :openrc'))
assert(s:find(':recipe "base/linux%-lts"'))
assert(s:find('"kde%-plasma/plasma%-desktop"'))
assert(s:find('"desktop/sddm"'))
print('installer config: OK')
