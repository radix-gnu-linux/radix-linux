local u=require('util')
local ui=require('ui')
local probe=require('probe')
local ans=require('answers')
local defaults=require('defaults')
local profile=require('profile')
local M={}

local function safe_hostname(s) return s and s:match('^[%w][%w%-%.]*$') and not s:find('%.%.') end
local function safe_user(s) return s and s:match('^[a-z_][a-z0-9_-]*$') and #s<=31 end
local function one_of(v,allowed) for _,x in ipairs(allowed) do if v==x then return true end end return false end
local function answer(a,key) local v=a[key]; return (v and v~='') and v or nil end
local function interactive(opts) return not opts.noninteractive end

local function suggested_swap()
  local m=probe.memory_mib()
  if m<=0 then return 2 end
  if m<=8192 then return 4 end
  if m<=32768 then return 4 end
  return 2
end

local function collect_desktop(a,opts)
  local repo=os.getenv('RADIX_PACKAGES') or '/radix-live/packages'
  local kde_missing=profile.kde_missing(repo)
  local kde_available=#kde_missing==0
  local v=answer(a,'DESKTOP')
  if v then
    if v=='kde' and not kde_available then
      ui.die('this image does not contain the complete KDE payload ('..#kde_missing..' recipe(s) missing)')
    end
    return v
  end
  if not interactive(opts) then return kde_available and defaults.desktop or 'console' end
  if not kde_available then
    ui.warn('KDE is not complete in this development image; console mode is the only installable profile.')
    return 'console'
  end
  return ui.choice('Desktop environment',{
    {label='KDE Plasma '..defaults.kde_plasma..' (recommended)',value='kde',description='Wayland desktop, SDDM, PipeWire and the standard Radix desktop profile.'},
    {label='Console only',value='console',description='OpenRC base system without a graphical desktop.'}
  },1)
end

function M.collect(a,opts)
  opts=opts or {}
  local c={target=opts.target or '/mnt/radix'}
  c.core_repository=answer(a,'CORE_REPOSITORY') or defaults.core_repository
  c.packages_repository=answer(a,'PACKAGES_REPOSITORY') or defaults.packages_repository

  c.firmware=answer(a,'FIRMWARE') or probe.firmware()
  if c.firmware~='uefi' then ui.die('the guided installer currently supports x86_64 UEFI systems only') end

  if interactive(opts) then
    ui.screen('Welcome','A guided install of Radix GNU/Linux')
    ui.info('KDE Plasma is the default desktop. The installer verifies its complete package payload before touching the disk.')
    ui.info('The installation uses the immutable Radix store and creates a rollback-capable system generation.')
    ui.pause()
    ui.screen('Hardware detected','A quick look before choosing the system')
    ui.kv('Firmware',c.firmware:upper())
    ui.kv('Memory',string.format('%.1f GiB',probe.memory_mib()/1024))
    ui.kv('Graphics',probe.gpu())
    ui.kv('Install disks',tostring(#probe.disks()))
    ui.pause()
    ui.screen('System','Choose what Radix should install')
  end

  c.desktop=collect_desktop(a,opts)
  if not one_of(c.desktop,{'kde','console'}) then ui.die('DESKTOP must be kde or console') end

  c.hostname=answer(a,'HOSTNAME') or (interactive(opts) and ui.prompt('Computer name',defaults.hostname) or defaults.hostname)
  if not safe_hostname(c.hostname) then ui.die('invalid hostname') end
  c.timezone=answer(a,'TIMEZONE') or (interactive(opts) and ui.prompt('Timezone',defaults.timezone) or defaults.timezone)
  c.locale=answer(a,'LOCALE') or (interactive(opts) and ui.prompt('Locale',defaults.locale) or defaults.locale)
  c.keymap=answer(a,'KEYMAP') or (interactive(opts) and ui.prompt('Console keyboard layout','us') or 'us')
  if not c.keymap:match('^[%w_+%-]+$') then ui.die('invalid KEYMAP') end

  c.libc=answer(a,'LIBC')
  if not c.libc then
    if interactive(opts) then
      c.libc=ui.choice('C library',{
        {label='glibc (recommended)',value='glibc',description='Default desktop and compatibility target.'},
        {label='musl (console / experimental)',value='musl',description='Smaller libc path. KDE is not offered on this path yet.'}
      },1)
    else c.libc=defaults.libc end
  end
  if not one_of(c.libc,{'glibc','musl'}) then ui.die('LIBC must be glibc or musl') end
  if c.desktop=='kde' and c.libc~='glibc' then ui.die('KDE installation currently requires glibc; choose glibc or console mode') end

  c.kernel=answer(a,'KERNEL')
  if not c.kernel then
    if interactive(opts) then
      c.kernel=ui.choice('Kernel',{
        {label='Linux LTS (recommended)',value='lts',description='Conservative default for a new Radix installation.'},
        {label='Linux stable',value='stable',description='Newest kernel tracked by the package channel.'}
      },1)
    else c.kernel=defaults.kernel end
  end
  if not one_of(c.kernel,{'lts','stable'}) then ui.die('KERNEL must be lts or stable') end

  c.gpu=probe.gpu()
  local requested=answer(a,'GPU_DRIVER') or 'auto'
  if not one_of(requested,{'auto','mesa','nvidia','none'}) then ui.die('GPU_DRIVER must be auto, mesa, nvidia, or none') end
  if c.desktop=='console' then c.gpu_driver='none'
  elseif requested~='auto' then c.gpu_driver=requested
  elseif c.gpu=='nvidia' then c.gpu_driver='nvidia'
  else c.gpu_driver='mesa' end

  c.fs=answer(a,'FILESYSTEM')
  if not c.fs then
    if interactive(opts) then
      local choices={}
      if u.command_exists('mkfs.ext4') then
        choices[#choices+1]={label='ext4 (recommended when available)',value='ext4',description='Journaling filesystem for normal installations.'}
      end
      choices[#choices+1]={label='ext2 (closed-live default)',value='ext2',description='Formatter is provided by the static BusyBox rescue environment.'}
      if u.command_exists('mkfs.btrfs') then
        choices[#choices+1]={label='btrfs',value='btrfs',description='Copy-on-write filesystem; shown only when btrfs-progs is present.'}
      end
      c.fs=ui.choice('Root filesystem',choices,1)
    else c.fs=defaults.filesystem end
  end
  if not one_of(c.fs,{'ext2','ext4','btrfs'}) then ui.die('FILESYSTEM must be ext2, ext4, or btrfs') end
  if c.fs=='ext4' and not u.command_exists('mkfs.ext4') then ui.die('FILESYSTEM=ext4 was requested, but this live image does not contain mkfs.ext4') end
  if c.fs=='btrfs' and not u.command_exists('mkfs.btrfs') then ui.die('FILESYSTEM=btrfs was requested, but this live image does not contain mkfs.btrfs') end

  local swap_default=tostring(suggested_swap())
  c.swap_gib=tonumber(answer(a,'SWAP_GIB') or (interactive(opts) and ui.prompt('Swap size in GiB (0 disables)',swap_default) or swap_default))
  if not c.swap_gib or c.swap_gib<0 or c.swap_gib~=math.floor(c.swap_gib) or c.swap_gib>256 then ui.die('SWAP_GIB must be an integer from 0 through 256') end

  c.mode=answer(a,'MODE') or 'erase'
  if c.mode~='erase' then ui.die('only guided whole-disk installation is supported in this release') end
  if interactive(opts) then ui.screen('Storage','Choose the disk Radix GNU/Linux will use') end
  local disks=probe.disks()
  if #disks==0 then ui.die('no supported installation disks found') end
  if answer(a,'DISK') then
    c.disk=a.DISK
    for _,d in ipairs(disks) do if d.path==c.disk then c.disk_info=d end end
    if not c.disk_info then ui.die('DISK is not one of the detected installable disks: '..c.disk) end
  else
    local choices={}
    for _,d in ipairs(disks) do choices[#choices+1]={label=probe.disk_label(d),value=d.path,description=d.removable and 'Removable media' or nil} end
    c.disk=ui.choice('Installation disk',choices,1)
    for _,d in ipairs(disks) do if d.path==c.disk then c.disk_info=d end end
  end
  c.erase_confirm=answer(a,'ERASE_CONFIRM') or ''

  if interactive(opts) then ui.screen('User account','Create the account you will use after reboot') end
  c.username=answer(a,'USERNAME')
  if not c.username then
    c.username=interactive(opts) and ui.prompt(c.desktop=='kde' and 'Your username' or 'Normal user name (blank skips)',c.desktop=='kde' and 'user' or '') or ''
  end
  if c.desktop=='kde' and c.username=='' then ui.die('KDE installations require a normal user account') end
  if c.username~='' and not safe_user(c.username) then ui.die('invalid user name') end
  c.admin=ans.bool(answer(a,'ADMIN'),true)
  c.serial_console=ans.bool(answer(a,'SERIAL_CONSOLE'),false)
  c.online_install=ans.bool(answer(a,'ONLINE_INSTALL'),true)
  c.dry_run=opts.dry_run
  c.packages=profile.packages(c)
  return c
end

local function q(s) return string.format('%q',s) end
local function package_vector(values)
  local out={}
  for _,v in ipairs(values) do out[#out+1]=q(v) end
  return table.concat(out,' ')
end

function M.system_manifest(c,path)
  local kernel=c.kernel=='stable' and 'base/linux-stable' or 'base/linux-lts'
  local swap=''
  local rootdev=c.root_partuuid and ('PARTUUID='..c.root_partuuid) or c.root
  if c.swap then
    local swapdev=c.swap_partuuid and ('PARTUUID='..c.swap_partuuid) or c.swap
    swap=string.format('\n    "/swap" {:device %s :type "swap" :options ["sw"] :dump 0 :pass 0}',q(swapdev))
  end
  local init_system=c.libc=='musl' and ':radix-rescue' or ':openrc'
  local data=string.format([[
(system-configuration
  :hostname %s
  :timezone %s
  :locale %s
  :init-system %s
  :libc :%s
  :kernel {:recipe %s :libc :glibc}
  :packages [%s]
  :boot-image false
  :file-systems {
    "/" {:device %s :type %s :options ["defaults"] :dump 0 :pass 1}%s}
  :services []
  :bootloader {:type :none}
  :keep-generations 12)
]],q(c.hostname),q(c.timezone),q(c.locale),init_system,c.libc,q(kernel),package_vector(c.packages),q(rootdev),q(c.fs),swap)
  u.write(path,data)
end

function M.preflight_manifest(c,path)
  local kernel=c.kernel=='stable' and 'base/linux-stable' or 'base/linux-lts'
  local data=string.format([[
(system-configuration
  :hostname %s
  :timezone %s
  :locale %s
  :init-system %s
  :libc :%s
  :kernel {:recipe %s :libc :glibc}
  :packages [%s]
  :boot-image false
  :file-systems {}
  :services []
  :bootloader {:type :none}
  :keep-generations 1)
]],q(c.hostname),q(c.timezone),q(c.locale),c.libc=='musl' and ':radix-rescue' or ':openrc',c.libc,q(kernel),package_vector(c.packages))
  u.write(path,data)
end

function M.summary(c)
  ui.screen('Review installation','Nothing has been written to disk yet')
  ui.kv('Desktop',c.desktop=='kde' and ('KDE Plasma '..defaults.kde_plasma) or 'Console')
  ui.kv('Kernel',c.kernel=='lts' and 'Linux LTS' or 'Linux stable')
  ui.kv('C library',c.libc)
  ui.kv('Graphics',c.gpu..' / '..c.gpu_driver)
  ui.kv('Hostname',c.hostname)
  ui.kv('Timezone',c.timezone)
  ui.kv('Locale',c.locale)
  ui.kv('Keyboard',c.keymap)
  ui.kv('Disk',c.disk..(c.disk_info and ('  '..c.disk_info.size) or ''))
  ui.kv('Filesystem',c.fs)
  ui.kv('Swap',c.swap_gib==0 and 'disabled' or (c.swap_gib..' GiB'))
  ui.kv('User',c.username~='' and (c.username..(c.admin and ' (administrator)' or '')) or 'root only')
  ui.kv('Core channel',c.core_repository)
  ui.kv('Package channel',c.packages_repository)
  ui.hr()
end

return M
