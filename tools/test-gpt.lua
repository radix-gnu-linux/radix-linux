local root=assert(arg[1], 'usage: test-gpt.lua REPO_ROOT [IMAGE]')
package.path=root..'/installer/lib/?.lua;'..package.path
local gpt=require('gpt')
local path=arg[2] or '/tmp/radix-gpt-test.img'
local sectors=4*1024*1024
local f=assert(io.open(path,'wb')); assert(f:seek('set',sectors*512-1)); f:write('\0'); f:close()
local l=gpt.write(path,sectors,0)
assert(l.root_number==2 and #l.parts==2)
print(path)
