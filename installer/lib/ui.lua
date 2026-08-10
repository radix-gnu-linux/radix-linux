local M={}
local esc='\27['
local reset=esc..'0m'
local bold=esc..'1m'
local dim=esc..'2m'
local blue=esc..'38;5;39m'
local cyan=esc..'38;5;45m'
local green=esc..'38;5;42m'
local yellow=esc..'38;5;220m'
local red=esc..'38;5;196m'
local gray=esc..'38;5;245m'

local function is_tty()
  local ok=os.execute('[ -t 0 ] && [ -t 1 ] >/dev/null 2>&1')
  return ok==true or ok==0
end

M.tty=is_tty()

local function line(ch,n) return string.rep(ch,n or 68) end
function M.clear() if M.tty then io.write(esc..'2J'..esc..'H') end end
function M.banner(subtitle)
  M.clear()
  io.write(blue,bold,'Radix GNU/Linux',reset,'  ',dim,'installer',reset,'\n')
  io.write(gray,line('─'),reset,'\n')
  if subtitle then io.write(cyan,subtitle,reset,'\n\n') else io.write('\n') end
end
function M.screen(title,subtitle)
  M.banner(subtitle)
  io.write(bold,title,reset,'\n',gray,line('─',math.min(68,#title+8)),reset,'\n\n')
end
function M.note(s) io.write(green,'  ✓ ',reset,s,'\n') end
function M.info(s) io.write(cyan,'  • ',reset,s,'\n') end
function M.warn(s) io.stderr:write(yellow,'  ! ',reset,s,'\n') end
function M.die(s) io.stderr:write('\n',red,bold,'Installation stopped',reset,'\n',red,'  ',s,reset,'\n'); os.exit(1) end
function M.muted(s) io.write(dim,'  ',s,reset,'\n') end
function M.step(n,total,title)
  io.write('\n',blue,bold,string.format('[%d/%d] ',n,total),reset,bold,title,reset,'\n')
end
function M.kv(k,v)
  io.write('  ',gray,string.format('%-18s',k),reset,tostring(v or ''),'\n')
end
function M.hr() io.write(gray,line('─'),reset,'\n') end

function M.prompt(label,default)
  if default and default~='' then io.write(bold,label,reset,' [',cyan,default,reset,']: ')
  else io.write(bold,label,reset,': ') end
  io.flush()
  local v=io.read('*l')
  if not v or v=='' then return default or '' end
  return v
end

function M.choice(label,choices,default)
  io.write(bold,label,reset,'\n')
  for i,c in ipairs(choices) do
    local mark=(i==(default or 1)) and (green..'●'..reset) or (gray..'○'..reset)
    io.write(string.format('  %s %d) %s',mark,i,c.label or c[1] or tostring(c)),'\n')
    if c.description then io.write('       ',dim,c.description,reset,'\n') end
  end
  while true do
    local v=M.prompt('Choose',tostring(default or 1))
    local n=tonumber(v)
    if n and choices[n] then return choices[n].value or choices[n][2] or choices[n].label end
    M.warn('Choose one of the numbers shown above.')
  end
end

function M.yesno(label,default)
  local suffix=default and 'Y/n' or 'y/N'
  while true do
    local v=M.prompt(label..' ('..suffix..')',''):lower()
    if v=='' then return default end
    if v=='y' or v=='yes' then return true end
    if v=='n' or v=='no' then return false end
    M.warn('Please answer yes or no.')
  end
end

function M.pause(label)
  if not M.tty then return end
  io.write('\n',dim,(label or 'Press Enter to continue'),reset)
  io.flush(); io.read('*l')
end

function M.confirm_disk(disk,model,size)
  io.stderr:write('\n',red,bold,'ERASE CONFIRMATION',reset,'\n')
  io.stderr:write('  Target: ',bold,disk,reset,'\n')
  if model and model~='' then io.stderr:write('  Model:  ',model,'\n') end
  if size and size~='' then io.stderr:write('  Size:   ',size,'\n') end
  io.stderr:write(red,'  Everything on this disk will be destroyed.',reset,'\n\n')
  io.stderr:write('Type ',bold,disk,reset,' exactly to continue: '); io.stderr:flush()
  local v=io.read('*l') or ''
  if v~=disk then M.die('disk confirmation did not match; no disk changes were made') end
end

return M
