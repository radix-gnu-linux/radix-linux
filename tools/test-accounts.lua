local root=assert(arg[1],'usage: test-accounts.lua REPO_ROOT TARGET')
local target=assert(arg[2],'usage: test-accounts.lua REPO_ROOT TARGET')
package.path=root..'/installer/lib/?.lua;'..package.path
local accounts=require('accounts')
accounts.write({target=target,desktop='kde',username='tester',admin=true,noninteractive=true})
local function read(path)
  local f=assert(io.open(path,'r')); local s=f:read('*a'); f:close(); return s
end
local base=target..'/var/lib/radix/accounts/'
local passwd=read(base..'passwd')
local group=read(base..'group')
assert(passwd:find('messagebus:x:81:81:',1,true))
assert(passwd:find('polkitd:x:102:102:',1,true))
assert(passwd:find('rtkit:x:133:133:',1,true))
assert(passwd:find('upower:x:134:134:',1,true))
assert(passwd:find('sddm:x:973:973:',1,true))
assert(passwd:find('tester:x:1000:1000:',1,true))
assert(group:find('wheel:x:10:tester',1,true))
assert(group:find('audio:x:18:tester',1,true))
assert(group:find('video:x:27:tester',1,true))
assert(group:find('render:x:29:tester',1,true))
assert(group:find('plugdev:x:46:tester',1,true))
print('account layout: OK')
