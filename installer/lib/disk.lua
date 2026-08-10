local u=require('util')
local gpt=require('gpt')
local M={}

local function part(disk,n)
  if disk:match('%d$') then return disk..'p'..n end
  return disk..n
end
M.partition_path=part

local function parent_disk(dev)
  if not dev or dev=='' then return nil end
  if dev:match('^/dev/nvme%d+n%d+p%d+$') then return dev:gsub('p%d+$','') end
  if dev:match('^/dev/mmcblk%d+p%d+$') then return dev:gsub('p%d+$','') end
  if dev:match('^/dev/[sv]d[a-z]+%d+$') or dev:match('^/dev/xvd[a-z]+%d+$') then return dev:gsub('%d+$','') end
  if dev:match('^/dev/nvme%d+n%d+$') or dev:match('^/dev/mmcblk%d+$') or dev:match('^/dev/[sv]d[a-z]+$') or dev:match('^/dev/xvd[a-z]+$') then return dev end
  return nil
end

local function basename(path)
  return path and path:match('([^/]+)$') or nil
end

local function sysfs_block_name(devno)
  if not devno or devno=='' then return nil end
  local p=u.capture({'readlink','-f','/sys/dev/block/'..devno},{allow_fail=true,stderr=false})
  if p=='' then return nil end
  return basename(p)
end

local function block_parents(name,seen,out)
  if not name or seen[name] then return end
  seen[name]=true
  local direct=parent_disk('/dev/'..name)
  if direct then out[direct]=true; return end
  local slaves='/sys/class/block/'..name..'/slaves'
  if not u.exists(slaves) then return end
  local names=u.capture({'sh','-c','for x in '..u.shell_quote(slaves)..'/*; do [ -e "$x" ] && basename "$x"; done'},
                        {allow_fail=true,stderr=false})
  for child in names:gmatch('[^\n]+') do block_parents(u.trim(child),seen,out) end
end

local function mounted_whole_disks()
  local out={}
  local f=io.open('/proc/self/mountinfo','r')
  if not f then return out end
  for line in f:lines() do
    local left=line:match('^(.-) %- ')
    if left then
      local devno=left:match('^%S+%s+%S+%s+(%d+:%d+)')
      local name=sysfs_block_name(devno)
      if name then block_parents(name,{},out) end
    end
  end
  f:close(); return out
end

local function read_number(path)
  local f=io.open(path,'r'); if not f then return nil end
  local n=tonumber(f:read('*l') or ''); f:close(); return n
end

function M.assert_safe(cfg)
  if not u.run({'test','-b',cfg.disk},{print=false,allow_fail=true}) then error('not a block disk: '..cfg.disk,0) end
  if mounted_whole_disks()[cfg.disk] then
    error('refusing to erase '..cfg.disk..'; it backs a currently mounted filesystem',0)
  end
  local name=cfg.disk:match('^/dev/(.+)$')
  local logical=name and read_number('/sys/class/block/'..name..'/queue/logical_block_size') or nil
  if logical and logical~=512 then
    error('guided GPT writer currently supports 512-byte logical sectors only; '..cfg.disk..' reports '..logical,0)
  end
end

local function disk_sectors(disk)
  local name=disk:match('^/dev/(.+)$')
  if not name then return nil end
  local n=read_number('/sys/class/block/'..name..'/size')
  if n then return n end
  local s=u.capture({'blockdev','--getsz',disk},{allow_fail=true,stderr=false})
  return tonumber(s)
end

function M.erase_layout(cfg)
  M.assert_safe(cfg)
  if cfg.firmware~='uefi' then error('guided whole-disk install currently requires UEFI firmware',0) end
  local sectors=disk_sectors(cfg.disk)
  if not sectors or sectors<8388608 then error('could not determine disk size, or disk is smaller than 4 GiB',0) end

  local layout=gpt.write(cfg.disk,sectors,cfg.swap_gib or 0)
  u.run({'sync'},{print=false})
  u.run({'blockdev','--rereadpt',cfg.disk})
  u.run({'mdev','-s'},{allow_fail=true})
  u.sleep(1)

  cfg.esp=part(cfg.disk,1)
  if layout.swap_number then cfg.swap=part(cfg.disk,layout.swap_number) end
  cfg.root=part(cfg.disk,layout.root_number)
  cfg.esp_partuuid=layout.parts[1].unique_guid
  cfg.root_partuuid=layout.parts[layout.root_number].unique_guid
  if layout.swap_number then cfg.swap_partuuid=layout.parts[layout.swap_number].unique_guid end
  if not u.run({'test','-b',cfg.esp},{print=false,allow_fail=true}) or not u.run({'test','-b',cfg.root},{print=false,allow_fail=true}) then
    error('kernel did not expose the new partition devices after GPT write',0)
  end
end

function M.format(cfg)
  u.run({'mkfs.vfat','-n','RADIX_EFI',cfg.esp})
  if cfg.swap then u.run({'mkswap','-L','RADIX_SWAP',cfg.swap}) end
  if cfg.fs=='btrfs' then
    if not u.command_exists('mkfs.btrfs') then error('mkfs.btrfs is not in this live image yet',0) end
    u.run({'mkfs.btrfs','-f','-L','RADIX_ROOT',cfg.root})
  elseif cfg.fs=='ext4' then
    if not u.command_exists('mkfs.ext4') then error('mkfs.ext4 is not in this live image yet; choose ext2',0) end
    u.run({'mkfs.ext4','-F','-L','RADIX_ROOT',cfg.root})
  else
    u.run({'mkfs.ext2','-L','RADIX_ROOT',cfg.root})
  end
end

function M.mount(cfg)
  u.mkdir(cfg.target)
  u.run({'mount',cfg.root,cfg.target})
  u.mkdir(cfg.target..'/boot/efi')
  u.run({'mount',cfg.esp,cfg.target..'/boot/efi'})
  if cfg.swap then u.run({'swapon',cfg.swap},{allow_fail=true}) end
end

function M.unmount(cfg)
  u.run({'umount','-R',cfg.target},{allow_fail=true})
  if cfg.swap then u.run({'swapoff',cfg.swap},{allow_fail=true}) end
end
return M
