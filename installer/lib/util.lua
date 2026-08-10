local M = {}

function M.trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

function M.shell_quote(s)
  s = tostring(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

function M.join_argv(argv)
  local out = {}
  for i, v in ipairs(argv) do out[i] = M.shell_quote(v) end
  return table.concat(out, ' ')
end

function M.run(argv, opts)
  opts = opts or {}
  local cmd = type(argv) == 'table' and M.join_argv(argv) or argv
  if opts.print ~= false then io.stderr:write('+ ', cmd, '\n') end
  local a, b, c = os.execute(cmd)
  local ok = (a == true) or (type(a) == 'number' and a == 0)
  if not ok and not opts.allow_fail then
    error('command failed: ' .. cmd, 0)
  end
  return ok, c or a
end

function M.capture(argv, opts)
  opts = opts or {}
  local cmd = type(argv) == 'table' and M.join_argv(argv) or argv
  if opts.stderr == false then cmd = cmd .. ' 2>/dev/null' end
  local p = assert(io.popen(cmd, 'r'))
  local data = p:read('*a')
  local ok = p:close()
  if not ok and not opts.allow_fail then error('command failed: ' .. cmd, 0) end
  return M.trim(data)
end

function M.command_exists(name)
  return M.run({'sh','-c','command -v ' .. M.shell_quote(name) .. ' >/dev/null 2>&1'}, {print=false, allow_fail=true})
end

function M.exists(path)
  local f = io.open(path, 'rb')
  if f then f:close(); return true end
  return M.run({'test','-e',path},{print=false,allow_fail=true})
end

function M.mkdir(path)
  M.run({'mkdir','-p',path},{print=false})
end

function M.write(path, data, mode)
  local f = assert(io.open(path, 'wb'))
  f:write(data); f:close()
  if mode then M.run({'chmod', mode, path},{print=false}) end
end

function M.read_lines(path)
  local out = {}
  local f = io.open(path, 'r')
  if not f then return out end
  for line in f:lines() do table.insert(out, line) end
  f:close(); return out
end

function M.realpath(path)
  local p = M.capture({'realpath','-m',path},{allow_fail=true,stderr=false})
  return p ~= '' and p or path
end

function M.is_root()
  return M.capture({'id','-u'},{stderr=false}) == '0'
end

function M.sleep(seconds)
  M.run({'sleep', tostring(seconds)}, {print=false})
end

return M
