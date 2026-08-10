local u=require('util')
local ui=require('ui')
local defaults=require('defaults')
local M={}

local function copy_tree(src,dst)
  u.mkdir(dst)
  u.run({'sh','-c','cd '..u.shell_quote(src)..' && tar --exclude=.git --exclude=build --exclude=dist -cf - . | tar -xf - -C '..u.shell_quote(dst)})
end

function M.prepare(cfg,opts)
  opts=opts or {}
  local runtime='/run/radix-installer'
  u.run({'rm','-rf',runtime},{allow_fail=true,print=false})
  u.mkdir(runtime..'/bin'); u.mkdir(runtime..'/repo'); u.mkdir(runtime..'/core')

  local radix=opts.radix or os.getenv('RADIX') or u.capture({'sh','-c','command -v radix'},{stderr=false})
  if radix=='' then ui.die('Radix executable not found in the live environment') end
  u.run({'cp',radix,runtime..'/bin/radix'},{print=false})

  local packages=opts.packages or os.getenv('RADIX_PACKAGES') or '/radix-live/packages'
  if not u.exists(packages..'/pkgs') then ui.die('the live package snapshot is missing: '..packages) end
  copy_tree(packages,runtime..'/repo')

  local core=opts.repo_root or os.getenv('RADIX_LINUX_ROOT') or '/radix-live/core'
  if not u.exists(core..'/installer') then ui.die('the live distro core snapshot is missing: '..core) end
  copy_tree(core,runtime..'/core')

  if cfg.online_install and opts.online then
    ui.note('official GitHub channels are reachable')
    ui.muted('installation remains pinned to the package snapshot that built this ISO')
  else
    ui.muted('using the package and distro snapshots embedded in this ISO')
  end

  return {root=runtime,radix=runtime..'/bin/radix',repo=runtime..'/repo',core=runtime..'/core'}
end

function M.write_installed_metadata(cfg,target)
  local dir=target..'/etc/radix'
  u.mkdir(dir)
  u.write(dir..'/channels.conf',table.concat({
    'core='..(cfg.core_repository or defaults.core_repository),
    'packages='..(cfg.packages_repository or defaults.packages_repository),
    'radix='..defaults.radix_repository,
    ''
  },'\n'),'0644')
  if u.exists('/radix-live/BUILD_INFO') then
    u.run({'cp','/radix-live/BUILD_INFO',dir..'/install-build-info'},{print=false})
  end
end

return M
