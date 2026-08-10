local u=require('util')
local ui=require('ui')
local disk=require('disk')
local config=require('config')
local accounts=require('accounts')
local repositories=require('repositories')
local network=require('network')
local profile=require('profile')
local M={}

local function need(cmds)
  local bad={}
  for _,c in ipairs(cmds) do if not u.command_exists(c) then bad[#bad+1]=c end end
  if #bad>0 then ui.die('live environment is missing required tools: '..table.concat(bad,', ')) end
end

local function recipe_path(repo,id) return repo..'/pkgs/'..id..'.janet' end
local function ensure_recipe_set(cfg,runtime)
  if cfg.kde_mode~='preview' and cfg.gpu_driver=='nvidia' and not u.exists(recipe_path(runtime.repo,'drivers/nvidia')) then
    ui.warn('the NVIDIA package is not present in this package-channel snapshot')
    ui.warn('falling back to the Mesa/Nouveau graphics path for this install')
    cfg.gpu_driver='mesa'; cfg.packages=profile.packages(cfg)
  end
  local missing={}
  for _,id in ipairs(cfg.packages) do if not u.exists(recipe_path(runtime.repo,id)) then missing[#missing+1]=id end end
  if #missing>0 then
    ui.die('this ISO/package snapshot cannot satisfy the selected '..cfg.desktop..' profile. Missing recipes: '..table.concat(missing,', '))
  end
end

local function first_existing(root,paths)
  for _,rel in ipairs(paths) do
    if u.exists(root..'/'..rel) then return root..'/'..rel end
  end
  return nil
end

local function verify_profile_layout(cfg,profile_path)
  if cfg.libc=='musl' then
    if not u.exists(profile_path..'/bin/busybox') then ui.die('musl rescue profile is missing bin/busybox') end
    return
  end
  local required={
    'bin/busybox','bin/bash','sbin/openrc-run','bin/dbus-daemon',
    'sbin/dhcpcd','bin/seatd'
  }
  if cfg.desktop=='kde' and cfg.kde_mode~='preview' then
    for _,rel in ipairs({'bin/sddm','bin/startplasma-wayland','bin/kwin_wayland','bin/pipewire','bin/wireplumber'}) do
      required[#required+1]=rel
    end
  end
  local missing={}
  for _,rel in ipairs(required) do if not u.exists(profile_path..'/'..rel) then missing[#missing+1]=rel end end
  if cfg.libc=='glibc' and not first_existing(profile_path,{'lib64/ld-linux-x86-64.so.2','lib/ld-linux-x86-64.so.2'}) then
    missing[#missing+1]='glibc dynamic loader'
  end
  if cfg.desktop=='kde' and cfg.kde_mode~='preview' then
    if not first_existing(profile_path,{'lib/elogind/elogind','libexec/elogind','usr/lib/elogind/elogind','usr/libexec/elogind'}) then
      missing[#missing+1]='elogind daemon'
    end
    if not first_existing(profile_path,{'lib/polkit-1/polkitd','libexec/polkit-1/polkitd','usr/lib/polkit-1/polkitd','usr/libexec/polkit-1/polkitd'}) then
      missing[#missing+1]='polkitd'
    end
    local daemon_checks={
      {'NetworkManager',{'sbin/NetworkManager','bin/NetworkManager'}},
      {'udevd',{'lib/udev/udevd','sbin/udevd','lib/systemd/systemd-udevd'}},
      {'udevadm',{'bin/udevadm','sbin/udevadm'}},
      {'upowerd',{'libexec/upowerd','lib/upower/upowerd','sbin/upowerd'}},
      {'udisksd',{'libexec/udisks2/udisksd','lib/udisks2/udisksd','sbin/udisksd'}},
      {'bluetoothd',{'libexec/bluetooth/bluetoothd','lib/bluetooth/bluetoothd','sbin/bluetoothd'}}
    }
    for _,check in ipairs(daemon_checks) do
      if not first_existing(profile_path,check[2]) then missing[#missing+1]=check[1] end
    end
  end
  if #missing>0 then
    ui.die('the selected package closure builds, but its merged system profile is incomplete: '..table.concat(missing,', '))
  end
end

local function package_preflight(cfg,runtime)
  local r=runtime.radix
  local kernel=cfg.kernel=='stable' and 'base/linux-stable' or 'base/linux-lts'
  local selected={kernel}
  for _,id in ipairs(cfg.packages) do selected[#selected+1]=id end
  local env='RADIX_ROOT=/radix RADIX_REPOSITORY='..u.shell_quote(runtime.repo)..' RADIX_ALLOW_HOST_BOOTSTRAP=0 RADIX_SANDBOX=strict '
  ui.step(2,7,'Verify package payload')
  ui.info(string.format('checking %d selected packages before disk changes',#selected))
  for i,id in ipairs(selected) do
    if i==1 or i==#selected or i%10==0 then ui.muted(string.format('%d/%d  %s',i,#selected,id)) end
    local libc=(i==1) and 'glibc' or cfg.libc
    u.run({'sh','-c',env..u.shell_quote(r)..' build '..u.shell_quote(id)..' --libc='..libc},{print=false})
  end

  -- Building roots one-by-one is not enough: the installed profile must also
  -- merge without collisions and expose the runtime paths the desktop needs.
  local manifest=runtime.root..'/preflight-system.janet'
  config.preflight_manifest(cfg,manifest)
  local output=u.capture({'sh','-c',env..u.shell_quote(r)..' system build '..u.shell_quote(manifest)},{stderr=false})
  local profile_path=output:match('%[radix%] system closure:%s*(/radix/store/%S+)')
  if not profile_path then ui.die('Radix built the preflight system but did not report its system closure path') end
  u.run({'sh','-c',env..u.shell_quote(r)..' store verify '..u.shell_quote(profile_path)},{print=false})
  verify_profile_layout(cfg,profile_path)
  ui.note('selected system is present, mergeable and runtime-complete in the live store')
end

local function seed_store(cfg)
  u.mkdir(cfg.target..'/radix/store')
  u.run({'cp','-a','/radix/store/.',cfg.target..'/radix/store/'},{print=false})
end
local function bind_canonical_store(cfg)
  u.mkdir(cfg.target..'/radix'); u.mkdir('/radix'); u.run({'mount','--bind',cfg.target..'/radix','/radix'},{print=false})
end
local function unbind_canonical_store() u.run({'umount','/radix'},{allow_fail=true,print=false}) end

local function preview_archive()
  local p=os.getenv('RADIX_KDE_PREVIEW_ROOTFS') or '/run/radix-media/radix/payload/kde-preview-rootfs.tar.gz'
  return p
end

local function copy_if_dir(src,dst)
  if not u.exists(src) then return end
  u.mkdir(dst)
  u.run({'cp','-a',src..'/.',dst..'/'},{print=false})
end

local function install_kde_preview(cfg)
  local archive=preview_archive()
  if not u.exists(archive) then ui.die('KDE bootstrap preview payload disappeared before installation: '..archive) end
  local checksum=archive..'.sha256'
  if not u.exists(checksum) then ui.die('KDE bootstrap preview checksum is missing: '..checksum) end
  local dir=archive:match('^(.*)/[^/]+$') or '.'
  ui.info('verifying KDE bootstrap preview payload')
  u.run({'sh','-c','cd '..u.shell_quote(dir)..' && sha256sum -c kde-preview-rootfs.tar.gz.sha256'},{print=false})
  ui.info('installing KDE bootstrap preview userspace from the ISO')
  u.run({'tar','-xzf',archive,'-C',cfg.target,'--numeric-owner'},{print=false})

  -- The preview userspace boots the exact Radix kernel selected above. Make its
  -- matching modules and Radix firmware visible at conventional runtime paths.
  local system=cfg.target..'/radix/profiles/system'
  u.run({'rm','-rf',cfg.target..'/lib/modules'},{allow_fail=true,print=false})
  copy_if_dir(system..'/lib/modules',cfg.target..'/lib/modules')
  copy_if_dir(system..'/lib/firmware',cfg.target..'/lib/firmware')

  local rootdev=cfg.root_partuuid and ('PARTUUID='..cfg.root_partuuid) or cfg.root
  local espdev=cfg.esp_partuuid and ('PARTUUID='..cfg.esp_partuuid) or cfg.esp
  local fstab=rootdev..' / '..cfg.fs..' defaults 0 1\n'..
    espdev..' /boot/efi vfat umask=0077 0 2\n'
  if cfg.swap then
    local swapdev=cfg.swap_partuuid and ('PARTUUID='..cfg.swap_partuuid) or cfg.swap
    fstab=fstab..swapdev..' none swap sw 0 0\n'
  end
  u.write(cfg.target..'/etc/fstab',fstab,'0644')
  u.write(cfg.target..'/etc/hostname',cfg.hostname..'\n','0644')
  u.write(cfg.target..'/etc/hosts','127.0.0.1 localhost\n127.0.1.1 '..cfg.hostname..'\n::1 localhost ip6-localhost ip6-loopback\n','0644')
  u.write(cfg.target..'/etc/timezone',cfg.timezone..'\n','0644')
  if u.exists(cfg.target..'/usr/share/zoneinfo/'..cfg.timezone) then
    u.run({'ln','-sfn','/usr/share/zoneinfo/'..cfg.timezone,cfg.target..'/etc/localtime'},{print=false})
  end
  u.write(cfg.target..'/etc/default/locale','LANG='..cfg.locale..'\n','0644')

  u.mkdir(cfg.target..'/etc/radix')
  u.write(cfg.target..'/etc/radix/kde-bootstrap-preview',
    'This system uses the temporary KDE bootstrap preview userspace.\n'..
    'Radix still owns the kernel, boot artifacts, package store, channels and installer state.\n',
    '0644')
  u.mkdir(cfg.target..'/etc/profile.d')
  u.write(cfg.target..'/etc/profile.d/radix.sh',
    'export RADIX_ROOT=/radix\n'..
    'export RADIX_REPOSITORY=/var/lib/radix/repository\n'..
    'export RADIX_SANDBOX=strict\n'..
    'export PATH=/radix/bin:$PATH\n', '0644')
end

local function root_layout(cfg)
  for _,d in ipairs({'var','home','root','tmp','run','boot','etc','dev','proc','sys','var/log','var/lib','var/cache'}) do u.mkdir(cfg.target..'/'..d) end
  u.run({'chmod','1777',cfg.target..'/tmp'},{print=false})
  for _,name in ipairs({'bin','sbin','lib','lib64','usr'}) do
    u.run({'rm','-rf',cfg.target..'/'..name},{allow_fail=true,print=false})
    u.run({'ln','-s','/run/current-system/'..name,cfg.target..'/'..name},{print=false})
  end
end

local function install_bootstrap_tools(cfg,runtime)
  u.mkdir(cfg.target..'/radix/bin')
  u.run({'cp',runtime.radix,cfg.target..'/radix/bin/radix'},{print=false})
  u.run({'chmod','0755',cfg.target..'/radix/bin/radix'},{print=false})
  local sync=runtime.core..'/sbin/radix-channel-sync'
  if u.exists(sync) then
    u.run({'cp',sync,cfg.target..'/radix/bin/radix-channel-sync'},{print=false})
    u.run({'chmod','0755',cfg.target..'/radix/bin/radix-channel-sync'},{print=false})
  end
  u.mkdir(cfg.target..'/var/lib/radix/repository')
  u.run({'cp','-a',runtime.repo..'/.',cfg.target..'/var/lib/radix/repository/'},{print=false})
  if u.exists(runtime.core..'/installer') then
    u.mkdir(cfg.target..'/var/lib/radix/distro')
    u.run({'cp','-a',runtime.core..'/.',cfg.target..'/var/lib/radix/distro/'},{print=false})
  end
end

local function run_radix(cfg,runtime,manifest)
  u.mkdir(cfg.target..'/run')
  local prefix=table.concat({'RADIX_ROOT=/radix','RADIX_RUN_ROOT='..u.shell_quote(cfg.target..'/run'),'RADIX_REPOSITORY='..u.shell_quote(runtime.repo),'RADIX_ALLOW_HOST_BOOTSTRAP=0','RADIX_SANDBOX=strict'},' ')
  local r=runtime.radix
  u.run({'sh','-c',prefix..' '..u.shell_quote(r)..' system validate '..u.shell_quote(manifest)},{print=false})
  u.run({'sh','-c',prefix..' '..u.shell_quote(r)..' system reconfigure '..u.shell_quote(manifest)},{print=false})
  u.run({'sh','-c',prefix..' '..u.shell_quote(r)..' system verify'},{print=false})
end

local function machine_identity(cfg)
  local p=cfg.target..'/etc/machine-id'
  if u.exists(p) then return end
  local id=u.capture({'sh','-c',"cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-'"},{allow_fail=true,stderr=false})
  if #id~=32 then id=string.format('%032d',os.time()) end
  u.write(p,id..'\n','0444')
end

local function configure_desktop(cfg,repo_root)
  u.run({repo_root..'/scripts/configure-openrc.sh',cfg.target,cfg.desktop,cfg.gpu_driver,cfg.username,cfg.keymap},{print=false})
end

function M.go(cfg,opts)
  opts=opts or {}
  local required={'mount','umount','mkfs.vfat','mkswap','cpio','blockdev','mdev','tar'}
  if cfg.desktop=='kde' and cfg.kde_mode=='preview' then required[#required+1]='sha256sum' end
  if cfg.fs=='ext4' then required[#required+1]='mkfs.ext4'
  elseif cfg.fs=='btrfs' then required[#required+1]='mkfs.btrfs'
  else required[#required+1]='mkfs.ext2' end
  need(required)
  config.summary(cfg)

  ui.step(1,7,'Network and repositories')
  local online=false
  if cfg.online_install then online=network.ensure(opts.noninteractive) end
  if online then ui.note('Internet connection available') else ui.info('offline install mode: using package snapshot embedded in the ISO') end
  local runtime=repositories.prepare(cfg,{radix=opts.radix,packages=opts.packages,repo_root=opts.repo_root,online=online})
  ensure_recipe_set(cfg,runtime)
  package_preflight(cfg,runtime)

  if cfg.dry_run then ui.note('dry run complete: selected payload is available; no disk changes made'); return end
  if cfg.mode~='erase' then ui.die('only guided whole-disk mode is wired in this release') end
  if opts.noninteractive then
    if cfg.erase_confirm~=cfg.disk then ui.die('non-interactive erase requires ERASE_CONFIRM to exactly match DISK') end
  else
    ui.pause('Press Enter to continue to the disk erase confirmation')
    ui.confirm_disk(cfg.disk,cfg.disk_info and cfg.disk_info.model,cfg.disk_info and cfg.disk_info.size)
  end

  ui.step(3,7,'Partition and format disk')
  disk.erase_layout(cfg); disk.format(cfg); disk.mount(cfg)
  ui.note('disk layout created and mounted')

  local bound=false
  local ok,err=xpcall(function()
    ui.step(4,7,'Install Radix system')
    seed_store(cfg); bind_canonical_store(cfg); bound=true
    local manifest=runtime.root..'/system.janet'; config.system_manifest(cfg,manifest)
    run_radix(cfg,runtime,manifest)
    if cfg.desktop=='kde' and cfg.kde_mode=='preview' then
      install_kde_preview(cfg)
    else
      root_layout(cfg)
    end
    install_bootstrap_tools(cfg,runtime)
    ui.note('immutable Radix system generation installed')

    ui.step(5,7,'Create users and machine configuration')
    cfg.noninteractive=opts.noninteractive
    if cfg.desktop=='kde' and cfg.kde_mode=='preview' then
      accounts.write_preview(cfg)
      u.run({opts.repo_root..'/scripts/configure-kde-preview.sh',cfg.target,cfg.gpu_driver,cfg.username,cfg.keymap},{print=false})
    else
      accounts.write(cfg)
      u.run({opts.repo_root..'/scripts/sync-etc.sh',cfg.target},{print=false})
      if cfg.admin and cfg.username~='' then
        u.mkdir(cfg.target..'/etc/sudoers.d')
        u.write(cfg.target..'/etc/sudoers.d/10-wheel','%wheel ALL=(ALL:ALL) ALL\n','0440')
      end
      if cfg.libc~='musl' then
        configure_desktop(cfg,opts.repo_root)
      else
        u.mkdir(cfg.target..'/etc/radix')
        u.write(cfg.target..'/etc/radix/desktop.conf','desktop=console\ngpu_driver=none\n','0644')
      end
    end
    machine_identity(cfg)
    repositories.write_installed_metadata(cfg,cfg.target)
    u.mkdir(cfg.target..'/etc/radix')
    u.run({'cp',manifest,cfg.target..'/etc/radix/system.janet'},{print=false})
    u.write(cfg.target..'/etc/radix/installed','Radix GNU/Linux\n'..(cfg.kde_mode=='preview' and 'desktop-bootstrap=debian-sid-kde\n' or ''),'0644')
    ui.note(cfg.desktop=='kde' and (cfg.kde_mode=='preview' and 'KDE Plasma bootstrap preview configured as the default desktop' or 'KDE Plasma session configured as the default desktop') or 'console system configured')

    ui.step(6,7,'Install bootloader')
    u.run({opts.repo_root..'/scripts/install-bootloader.sh',cfg.target,cfg.disk,cfg.root,cfg.firmware,cfg.kernel,cfg.root_partuuid or '',cfg.serial_console and '1' or '0'},{print=false})
    ui.note('UEFI fallback bootloader installed')
  end,debug.traceback)

  if bound then unbind_canonical_store() end
  disk.unmount(cfg)
  if not ok then error(err,0) end

  ui.step(7,7,'Finished')
  ui.note('Radix GNU/Linux is installed')
  if cfg.desktop=='kde' then ui.info('KDE Plasma will be started by SDDM on the first normal boot.') end
  ui.info('Core channel: '..cfg.core_repository)
  ui.info('Remove the live media, then reboot.')
end

return M
