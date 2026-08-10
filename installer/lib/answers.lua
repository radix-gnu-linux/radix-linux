local M={}
function M.load(path)
  local out={}
  if not path then return out end
  local f=assert(io.open(path,'r'))
  for line in f:lines() do
    line=line:gsub('^%s+',''):gsub('%s+$','')
    if line~='' and not line:match('^#') then
      local k,v=line:match('^([A-Z0-9_]+)%s*=%s*(.*)$')
      if k then out[k]=v end
    end
  end
  f:close(); return out
end
function M.bool(v,default)
  if v==nil or v=='' then return default end
  v=v:lower(); return v=='1' or v=='yes' or v=='true' or v=='on'
end
return M
