local u=require('util'); local ui=require('ui')
local M={}
local function prompt_secret(label)
  io.write(label,': '); io.flush()
  u.run({'stty','-echo'},{print=false,allow_fail=true})
  local v=io.read('*l') or ''
  u.run({'stty','echo'},{print=false,allow_fail=true}); io.write('\n')
  return v
end
local function prompt_confirmed(label,allow_empty)
  while true do
    local a=prompt_secret(label)
    if a=='' and not allow_empty then ui.warn('password cannot be empty')
    else
      local b=prompt_secret('confirm '..label)
      if a==b then return a end
      ui.warn('passwords did not match; try again')
    end
  end
end
local function hash_password(pw,busybox)
  if pw=='' then return '!' end
  local cmd=string.format("%s mkpasswd -m sha512 %s",u.shell_quote(busybox),u.shell_quote(pw))
  local h=u.capture({'sh','-c',cmd},{allow_fail=true,stderr=false})
  if h=='' then
    ui.warn('BusyBox mkpasswd is unavailable; account left locked. Run passwd after installing a login-capable userspace.')
    return '!'
  end
  return h
end

function M.write(cfg)
  local base=cfg.target..'/var/lib/radix/accounts'; u.mkdir(base)
  local bb=cfg.target..'/radix/profiles/system/bin/busybox'
  local root_hash='!'; local user_hash='!'
  if not cfg.noninteractive then
    if ui.yesno('Set a separate root password',false) then root_hash=hash_password(prompt_confirmed('root password',false),bb) end
    if cfg.username~='' then user_hash=hash_password(prompt_confirmed('password for '..cfg.username,false),bb) end
  end
  local passwd='root:x:0:0:root:/root:/bin/sh\n'..
    'messagebus:x:81:81:D-Bus system user:/var/empty:/bin/false\n'
  local shadow='root:'..root_hash..':1:0:99999:7:::\nmessagebus:!:1:0:99999:7:::\n'
  if cfg.desktop=='kde' then
    passwd=passwd..
      'polkitd:x:102:102:PolicyKit daemon:/var/lib/polkit-1:/bin/false\n'..
      'rtkit:x:133:133:RealtimeKit daemon:/var/empty:/bin/false\n'..
      'upower:x:134:134:UPower daemon:/var/lib/upower:/bin/false\n'..
      'sddm:x:973:973:SDDM display manager:/var/lib/sddm:/bin/false\n'
    shadow=shadow..
      'polkitd:!:1:0:99999:7:::\n'..
      'rtkit:!:1:0:99999:7:::\n'..
      'upower:!:1:0:99999:7:::\n'..
      'sddm:!:1:0:99999:7:::\n'
  end
  local member=(cfg.username or '')
  local wheel_member=(cfg.admin and member or '')
  local group=table.concat({
    'root:x:0:',
    'messagebus:x:81:',
    (cfg.desktop=='kde' and 'polkitd:x:102:' or ''),
    (cfg.desktop=='kde' and 'rtkit:x:133:' or ''),
    (cfg.desktop=='kde' and 'upower:x:134:' or ''),
    (cfg.desktop=='kde' and 'sddm:x:973:' or ''),
    'wheel:x:10:'..wheel_member,
    'audio:x:18:'..member,
    'video:x:27:'..member,
    'input:x:28:'..member,
    'render:x:29:'..member,
    'plugdev:x:46:'..member,
    'bluetooth:x:47:'..member,
    'users:x:100:'..member,
    '',
  },'\n')
  local gshadow=table.concat({
    'root:!::',
    'messagebus:!::',
    (cfg.desktop=='kde' and 'polkitd:!::' or ''),
    (cfg.desktop=='kde' and 'rtkit:!::' or ''),
    (cfg.desktop=='kde' and 'upower:!::' or ''),
    (cfg.desktop=='kde' and 'sddm:!::' or ''),
    'wheel:!::'..wheel_member,
    'audio:!::'..member,
    'video:!::'..member,
    'input:!::'..member,
    'render:!::'..member,
    'plugdev:!::'..member,
    'bluetooth:!::'..member,
    'users:!::'..member,
    '',
  },'\n')
  if cfg.username and cfg.username~='' then
    passwd=passwd..string.format('%s:x:1000:1000:%s:/home/%s:/bin/sh\n',cfg.username,cfg.username,cfg.username)
    shadow=shadow..string.format('%s:%s:1:0:99999:7:::\n',cfg.username,user_hash)
    group=group..string.format('%s:x:1000:\n',cfg.username)
    gshadow=gshadow..string.format('%s:!::\n',cfg.username)
    u.mkdir(cfg.target..'/home/'..cfg.username)
    u.run({'chown','1000:1000',cfg.target..'/home/'..cfg.username},{allow_fail=true,print=false})
  end
  if cfg.desktop=='kde' then
    u.mkdir(cfg.target..'/var/lib/polkit-1'); u.run({'chown','102:102',cfg.target..'/var/lib/polkit-1'},{allow_fail=true,print=false})
    u.mkdir(cfg.target..'/var/lib/upower'); u.run({'chown','134:134',cfg.target..'/var/lib/upower'},{allow_fail=true,print=false})
    u.mkdir(cfg.target..'/var/lib/sddm'); u.run({'chown','973:973',cfg.target..'/var/lib/sddm'},{allow_fail=true,print=false})
  end
  u.write(base..'/passwd',passwd,'0644'); u.write(base..'/shadow',shadow,'0600')
  u.write(base..'/group',group,'0644'); u.write(base..'/gshadow',gshadow,'0600')
end

local function chroot_run(target,argv,allow_fail)
  local cmd={'chroot',target}
  for _,v in ipairs(argv) do cmd[#cmd+1]=v end
  return u.run(cmd,{print=false,allow_fail=allow_fail})
end

function M.write_preview(cfg)
  -- The preview root is a complete stage-0 userspace, so preserve its system
  -- accounts instead of replacing /etc/passwd with the small native Radix
  -- account database.
  local bb=cfg.target..'/radix/profiles/system/bin/busybox'
  if cfg.username and cfg.username~='' then
    local groups={'audio','video','input','render','plugdev','bluetooth'}
    if cfg.admin then groups[#groups+1]='sudo' end
    for _,g in ipairs(groups) do chroot_run(cfg.target,{'groupadd','-f',g},true) end
    local joined=table.concat(groups,',')
    chroot_run(cfg.target,{'useradd','-m','-s','/bin/bash','-G',joined,cfg.username},false)
    if not cfg.noninteractive then
      local user_hash=hash_password(prompt_confirmed('password for '..cfg.username,false),bb)
      chroot_run(cfg.target,{'usermod','-p',user_hash,cfg.username},false)
    end
  end
  if not cfg.noninteractive and ui.yesno('Set a separate root password',false) then
    local root_hash=hash_password(prompt_confirmed('root password',false),bb)
    chroot_run(cfg.target,{'usermod','-p',root_hash,'root'},false)
  end
end

return M
