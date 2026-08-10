#!/usr/bin/env lua
local here=arg[0]:match('^(.*)/[^/]+$') or '.'
local lib=here..'/lib'
package.path=lib..'/?.lua;'..package.path
local ui=require('ui')
local answers=require('answers')
local config=require('config')
local install=require('install')
local util=require('util')

local opts={repo_root=(os.getenv('RADIX_LINUX_ROOT') or here..'/..')}
local answer_file=nil
for _,a in ipairs(arg) do
  if a=='--dry-run' then opts.dry_run=true
  elseif a=='--non-interactive' then opts.noninteractive=true
  elseif a=='--offline' then opts.offline=true
  elseif a:match('^%-%-answers=') then answer_file=a:match('=(.*)$')
  elseif a:match('^%-%-target=') then opts.target=a:match('=(.*)$')
  elseif a=='--version' then
    local f=io.open(opts.repo_root..'/VERSION','r'); print('setup-radix '..((f and f:read('*l')) or 'development')); if f then f:close() end; os.exit(0)
  elseif a=='--help' then
    print([[
setup-radix - Radix GNU/Linux guided installer

Usage:
  setup-radix
  setup-radix --dry-run
  setup-radix --answers=FILE --non-interactive

Options:
  --offline          Skip network/channel reachability checks during installation
  --dry-run          Probe and verify the selected payload without touching disks
  --answers=FILE     Read installer answers from a KEY=value file
  --non-interactive  Require all destructive choices from the answer file
  --target=DIR       Mount target (default /mnt/radix)
  --version          Print installer version
]])
    os.exit(0)
  else
    ui.die('unknown option: '..a)
  end
end

if not util.is_root() and not opts.dry_run then ui.die('run setup-radix as root') end
local a=answers.load(answer_file)
if opts.offline then a.ONLINE_INSTALL='no' end
local ok,result=xpcall(function()
  local c=config.collect(a,opts)
  return install.go(c,{radix=os.getenv('RADIX'),packages=os.getenv('RADIX_PACKAGES'),repo_root=opts.repo_root,noninteractive=opts.noninteractive})
end,debug.traceback)
if not ok then
  if os.getenv('RADIX_INSTALLER_DEBUG')=='1' then io.stderr:write(result,'\n'); os.exit(1) end
  local first=tostring(result):match('([^\n]+)') or tostring(result)
  ui.die(first)
end
