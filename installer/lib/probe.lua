local u=require('util')
local M={}

local function read_one(path)
  local f=io.open(path,'r')
  if not f then return '' end
  local s=f:read('*l') or ''; f:close()
  return u.trim(s)
end

local function human_bytes(bytes)
  local units={'B','KiB','MiB','GiB','TiB'}
  local n=bytes; local i=1
  while n>=1024 and i<#units do n=n/1024; i=i+1 end
  if i<=2 then return string.format('%.0f %s',n,units[i]) end
  return string.format('%.1f %s',n,units[i])
end

local function supported_disk_name(name)
  return name:match('^sd[a-z]+$') or name:match('^vd[a-z]+$') or
         name:match('^xvd[a-z]+$') or name:match('^nvme%d+n%d+$') or
         name:match('^mmcblk%d+$')
end

function M.firmware()
  return u.exists('/sys/firmware/efi') and 'uefi' or 'bios'
end

function M.disks()
  local out,seen={},{}
  local f=io.open('/proc/partitions','r')
  if not f then return out end
  for line in f:lines() do
    local _,_,_,name=line:match('^%s*(%d+)%s+(%d+)%s+(%d+)%s+(%S+)%s*$')
    if name and not seen[name] and supported_disk_name(name) and not u.exists('/sys/class/block/'..name..'/partition') then
      seen[name]=true
      local sectors=tonumber(read_one('/sys/class/block/'..name..'/size')) or 0
      local model=read_one('/sys/class/block/'..name..'/device/model')
      if model=='' then model=read_one('/sys/class/block/'..name..'/device/name') end
      local removable=read_one('/sys/class/block/'..name..'/removable')=='1'
      table.insert(out,{path='/dev/'..name,name=name,size=human_bytes(sectors*512),sectors=sectors,model=model,removable=removable})
    end
  end
  f:close()
  table.sort(out,function(a,b) return a.path<b.path end)
  return out
end

function M.disk_label(d)
  local model=(d.model or ''):gsub('^%s+',''):gsub('%s+$','')
  return string.format('%s  %-9s  %s%s',d.path,d.size or '?',model,(d.removable and ' [removable]' or ''))
end

local function gpu_from_sysfs()
  local p=io.popen("for d in /sys/bus/pci/devices/*; do [ -r \"$d/class\" ] || continue; c=$(cat \"$d/class\" 2>/dev/null); case \"$c\" in 0x0300*|0x0302*|0x0380*) cat \"$d/vendor\" 2>/dev/null; esac; done")
  if not p then return nil end
  for vendor in p:lines() do
    vendor=vendor:lower()
    if vendor=='0x10de' then p:close(); return 'nvidia' end
    if vendor=='0x1002' or vendor=='0x1022' then p:close(); return 'amd' end
    if vendor=='0x8086' then p:close(); return 'intel' end
  end
  p:close(); return nil
end

function M.gpu()
  local sys=gpu_from_sysfs()
  if sys then return sys end
  if u.command_exists('lspci') then
    local x=u.capture({'sh','-c',"lspci -nn | grep -Ei 'VGA|3D|Display' || true"},{stderr=false})
    if x:lower():find('nvidia') then return 'nvidia' end
    if x:lower():find('amd') or x:lower():find('ati') then return 'amd' end
    if x:lower():find('intel') then return 'intel' end
    return x=='' and 'unknown' or 'other'
  end
  return 'unknown'
end

function M.memory_mib()
  local f=io.open('/proc/meminfo','r'); if not f then return 0 end
  for line in f:lines() do
    local kb=line:match('^MemTotal:%s*(%d+)')
    if kb then f:close(); return math.floor(tonumber(kb)/1024) end
  end
  f:close(); return 0
end

return M
