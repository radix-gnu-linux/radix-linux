local u=require('util')
local ui=require('ui')
local M={}

local function interfaces()
  local out={}
  local p=io.popen("ls -1 /sys/class/net 2>/dev/null")
  if not p then return out end
  for name in p:lines() do
    if name~='lo' then out[#out+1]=name end
  end
  p:close(); table.sort(out); return out
end

local function wireless(name)
  return u.exists('/sys/class/net/'..name..'/wireless') or u.exists('/sys/class/net/'..name..'/phy80211')
end

function M.online()
  if u.command_exists('wget') then
    return u.run({'wget','-q','--spider','--timeout=5','https://github.com/'},{print=false,allow_fail=true})
  end
  return false
end

function M.summary()
  local out={}
  for _,name in ipairs(interfaces()) do
    out[#out+1]={name=name,wireless=wireless(name)}
  end
  return out
end

function M.try_wired()
  local have_dhcpcd=u.command_exists('dhcpcd')
  local have_udhcpc=u.command_exists('udhcpc')
  if not have_dhcpcd and not have_udhcpc then return false end
  local did=false
  for _,name in ipairs(interfaces()) do
    if not wireless(name) then
      if u.command_exists('ip') then
        u.run({'ip','link','set',name,'up'},{print=false,allow_fail=true})
      elseif u.command_exists('ifconfig') then
        u.run({'ifconfig',name,'up'},{print=false,allow_fail=true})
      end
      if have_dhcpcd then
        u.run({'dhcpcd','-4','-w','-t','8',name},{print=false,allow_fail=true})
      else
        u.run({'udhcpc','-q','-n','-t','5','-i',name},{print=false,allow_fail=true})
      end
      did=true
      if M.online() then return true end
    end
  end
  return did and M.online()
end

local function wifi_interface()
  for _,name in ipairs(interfaces()) do if wireless(name) then return name end end
  return nil
end

function M.configure_wifi(noninteractive)
  local iface=wifi_interface()
  if not iface then return false,'no wireless interface detected' end
  if not (u.command_exists('iw') and u.command_exists('wpa_supplicant') and u.command_exists('wpa_passphrase')) then
    return false,'Wi-Fi tools are missing from the live image'
  end
  if noninteractive then return false,'Wi-Fi setup needs SSID credentials in interactive mode' end
  ui.screen('Network','Connect the live environment before installation')
  ui.info('Wireless interface: '..iface)
  u.run({'ip','link','set',iface,'up'},{print=false,allow_fail=true})
  local scan=u.capture({'sh','-c',"iw dev "..u.shell_quote(iface).." scan 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p' | awk 'NF && !seen[$0]++' | head -n 20"},{allow_fail=true,stderr=false})
  local ssids={}
  for s in scan:gmatch('[^\n]+') do ssids[#ssids+1]=s end
  local ssid
  if #ssids>0 then
    local choices={}
    for _,s in ipairs(ssids) do choices[#choices+1]={label=s,value=s} end
    choices[#choices+1]={label='Enter a network name manually',value='__manual__'}
    ssid=ui.choice('Wi-Fi network',choices,1)
    if ssid=='__manual__' then ssid=ui.prompt('SSID','') end
  else
    ssid=ui.prompt('SSID','')
  end
  if ssid=='' then return false,'SSID cannot be empty' end
  io.write('Wi-Fi password: '); io.flush()
  u.run({'stty','-echo'},{print=false,allow_fail=true})
  local pass=io.read('*l') or ''
  u.run({'stty','echo'},{print=false,allow_fail=true}); io.write('\n')
  local conf='/run/radix-installer-wpa.conf'
  local generated=u.capture({'wpa_passphrase',ssid,pass},{allow_fail=true,stderr=false})
  if generated=='' then return false,'could not create wpa_supplicant configuration' end
  u.write(conf,generated,'0600')
  u.run({'pkill','wpa_supplicant'},{print=false,allow_fail=true})
  u.run({'wpa_supplicant','-B','-i',iface,'-c',conf},{print=false})
  u.run({'dhcpcd','-4','-w','-t','20',iface},{print=false,allow_fail=true})
  if M.online() then return true end
  return false,'connected to Wi-Fi but Internet access was not detected'
end

function M.ensure(noninteractive)
  if M.online() then return true end
  ui.info('No Internet connection detected. Trying wired DHCP...')
  if M.try_wired() and M.online() then ui.note('wired network connected'); return true end
  if noninteractive then return false end
  local ok,err=M.configure_wifi(false)
  if ok then ui.note('network connected'); return true end
  ui.warn(err or 'network setup failed')
  return false
end

return M
