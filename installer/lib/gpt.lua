local M = {}

local SECTOR = 512
local ENTRY_SIZE = 128
local ENTRY_COUNT = 128
local ENTRY_SECTORS = (ENTRY_SIZE * ENTRY_COUNT) // SECTOR
local ALIGN = 2048

local ESP_GUID  = 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B'
local SWAP_GUID = '0657FD6D-A4AB-43C4-84E5-0933C84B4F4F'
local ROOT_GUID = '0FC63DAF-8483-4772-8E79-3D69D8477DE4'

local crc_table = {}
for n = 0, 255 do
  local c = n
  for _ = 1, 8 do
    if (c & 1) ~= 0 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
  end
  crc_table[n] = c
end

local function crc32(data)
  local c = 0xFFFFFFFF
  for i = 1, #data do
    c = crc_table[(c ~ data:byte(i)) & 0xFF] ~ (c >> 8)
  end
  return (~c) & 0xFFFFFFFF
end
M.crc32 = crc32

local function align_up(n, a)
  return ((n + a - 1) // a) * a
end

local function uuid_text()
  local f = io.open('/proc/sys/kernel/random/uuid', 'r')
  if f then
    local s = f:read('*l'); f:close()
    if s and s:match('^[0-9a-fA-F%-]+$') then return s end
  end
  f = assert(io.open('/dev/urandom', 'rb'))
  local b = {f:read(16):byte(1,16)}; f:close()
  b[7] = (b[7] & 0x0F) | 0x40
  b[9] = (b[9] & 0x3F) | 0x80
  return string.format('%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x',
    table.unpack(b))
end

local function guid_bytes(text)
  local h = text:gsub('-', '')
  assert(#h == 32 and h:match('^[0-9A-Fa-f]+$'), 'bad GUID: '..tostring(text))
  local b = {}
  for i = 1, 32, 2 do b[#b+1] = tonumber(h:sub(i,i+1), 16) end
  local order = {4,3,2,1, 6,5, 8,7, 9,10,11,12,13,14,15,16}
  local out = {}
  for _,i in ipairs(order) do out[#out+1] = string.char(b[i]) end
  return table.concat(out)
end
M.guid_bytes = guid_bytes

local function utf16_name(s)
  local out = {}
  local n = 0
  for i = 1, #s do
    local c = s:byte(i)
    if c >= 0x80 then error('GPT partition names are ASCII-only in setup-radix', 0) end
    if n >= 36 then break end
    out[#out+1] = string.char(c, 0); n = n + 1
  end
  local data = table.concat(out)
  return data .. string.rep('\0', 72 - #data)
end

local function entry(p)
  return guid_bytes(p.type_guid)
      .. guid_bytes(p.unique_guid or uuid_text())
      .. string.pack('<I8I8I8', p.first_lba, p.last_lba, p.attributes or 0)
      .. utf16_name(p.name or '')
end

local function partition_array(parts)
  local out = {}
  for i = 1, ENTRY_COUNT do
    if parts[i] then out[i] = entry(parts[i]) else out[i] = string.rep('\0', ENTRY_SIZE) end
  end
  return table.concat(out)
end

local function header(args)
  local h = 'EFI PART'
      .. string.pack('<I4I4I4I4I8I8I8I8',
          0x00010000, 92, 0, 0,
          args.current_lba, args.backup_lba, args.first_usable, args.last_usable)
      .. guid_bytes(args.disk_guid)
      .. string.pack('<I8I4I4I4', args.entries_lba, ENTRY_COUNT, ENTRY_SIZE, args.entries_crc)
  assert(#h == 92)
  local crc = crc32(h)
  h = h:sub(1,16) .. string.pack('<I4', crc) .. h:sub(21)
  return h .. string.rep('\0', SECTOR - #h)
end

local function protective_mbr(last_lba)
  local n = math.min(last_lba, 0xFFFFFFFF)
  local p = string.char(0x00, 0x00,0x02,0x00, 0xEE, 0xFF,0xFF,0xFF)
      .. string.pack('<I4I4', 1, n)
  return string.rep('\0', 446) .. p .. string.rep('\0', 48) .. string.char(0x55,0xAA)
end

function M.plan(total_sectors, swap_gib)
  total_sectors = assert(math.tointeger(total_sectors), 'disk sector count must be an integer')
  swap_gib = math.tointeger(swap_gib or 0) or 0
  if swap_gib < 0 then error('swap size cannot be negative', 0) end

  local last_lba = total_sectors - 1
  local first_usable = 2 + ENTRY_SECTORS
  local last_usable = last_lba - ENTRY_SECTORS - 1
  local esp_first = ALIGN
  local esp_sectors = 512 * 1024 * 1024 // SECTOR
  local esp_last = esp_first + esp_sectors - 1
  local next_lba = align_up(esp_last + 1, ALIGN)
  local parts = {
    {name='Radix EFI', type_guid=ESP_GUID, first_lba=esp_first, last_lba=esp_last}
  }
  if swap_gib > 0 then
    local swap_sectors = swap_gib * 1024 * 1024 * 1024 // SECTOR
    local swap_last = next_lba + swap_sectors - 1
    parts[#parts+1] = {name='Radix swap', type_guid=SWAP_GUID, first_lba=next_lba, last_lba=swap_last}
    next_lba = align_up(swap_last + 1, ALIGN)
  end
  if next_lba + ALIGN > last_usable then
    error('disk is too small for the requested EFI/swap/root layout', 0)
  end
  parts[#parts+1] = {name='Radix root', type_guid=ROOT_GUID, first_lba=next_lba, last_lba=last_usable}
  return {
    total_sectors=total_sectors,
    last_lba=last_lba,
    first_usable=first_usable,
    last_usable=last_usable,
    parts=parts,
    root_number=#parts,
    swap_number=swap_gib > 0 and 2 or nil,
  }
end

local function write_at(f, offset, data)
  assert(f:seek('set', offset))
  assert(f:write(data))
end

function M.write(path, total_sectors, swap_gib)
  local layout = M.plan(total_sectors, swap_gib)
  local disk_guid = uuid_text()
  for _,p in ipairs(layout.parts) do p.unique_guid = uuid_text() end
  local entries = partition_array(layout.parts)
  local ecrc = crc32(entries)
  local backup_entries_lba = layout.last_lba - ENTRY_SECTORS
  local primary = header{
    current_lba=1, backup_lba=layout.last_lba,
    first_usable=layout.first_usable, last_usable=layout.last_usable,
    disk_guid=disk_guid, entries_lba=2, entries_crc=ecrc,
  }
  local backup = header{
    current_lba=layout.last_lba, backup_lba=1,
    first_usable=layout.first_usable, last_usable=layout.last_usable,
    disk_guid=disk_guid, entries_lba=backup_entries_lba, entries_crc=ecrc,
  }

  local f,err = io.open(path, 'r+b')
  if not f then error('cannot open disk for GPT write: '..tostring(err), 0) end
  local ok,msg = pcall(function()
    write_at(f, 0, protective_mbr(layout.last_lba))
    write_at(f, SECTOR, primary)
    write_at(f, 2 * SECTOR, entries)
    write_at(f, backup_entries_lba * SECTOR, entries)
    write_at(f, layout.last_lba * SECTOR, backup)
    assert(f:flush())
  end)
  f:close()
  if not ok then error(msg, 0) end
  return layout
end

M.constants = {
  sector=SECTOR, entry_size=ENTRY_SIZE, entry_count=ENTRY_COUNT,
  esp_guid=ESP_GUID, swap_guid=SWAP_GUID, root_guid=ROOT_GUID,
}
return M
