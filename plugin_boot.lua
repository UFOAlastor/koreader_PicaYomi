-- Stable loader protocol 1. Updates are immutable payloads; the outer plugin
-- and user data never move. Only an fsynced pointer changes between boots.
local B={PROTOCOL=1}
local lfs=require('libs/libkoreader-lfs')
local json=require('rapidjson')
local util=require('ffi/util')
function B.id(v)return v=='base' or type(v)=='string' and #v==64 and v:match('^[0-9a-f]+$')~=nil end
function B.read(path)
 local f=io.open(path,'rb');if not f then return nil end
 local s=f:read(65537);f:close();assert(s and #s<=65536,'更新状态过大')
 local v=json.decode(s);assert(type(v)=='table','更新状态无效');return v
end
function B.write(path,v)
 local tmp=path..'.tmp';local f=assert(io.open(tmp,'wb'),'无法保存更新状态')
 local ok,err=pcall(function()assert(f:write(json.encode(v)));assert(util.fsyncOpenedFile(f,true))end)
 local closed=f:close();if not ok or not closed then os.remove(tmp);error(err or '无法保存更新状态',0)end
 assert(os.rename(tmp,path),'无法提交更新状态');assert(util.fsyncDirectory(path),'无法同步更新状态')
end
function B.version(path)
 local f=io.open(path..'/_meta.lua','rb');if not f then return end
 local s=f:read(16384);f:close();return s and s:match('version%s*=%s*"(%d+%.%d+%.%d+)"')
end
function B.compare(a,b)
 local function parts(v)
  local x,y,z
  if type(v)=='string'then x,y,z=v:match('^(%d+)%.(%d+)%.(%d+)$')end
  assert(x and #v<32,'版本号无效');return {tonumber(x),tonumber(y),tonumber(z)}
 end
 local x,y=parts(a),parts(b);for i=1,3 do if x[i]~=y[i]then return x[i]<y[i]and -1 or 1 end end;return 0
end
function B.state(root)
 local mode=lfs.symlinkattributes(root..'/.updates','mode');assert(not mode or mode=='directory','更新目录不安全')
 local s=B.read(root..'/.updates/state.json')or {format=1,active='base'}
 assert(s.format==1,'更新状态格式不支持')
 for _,k in ipairs{'active','previous','pending','trial','blocked'}do assert(s[k]==nil or B.id(s[k]),'更新路径无效')end
 s.active=s.active or 'base';return s
end
function B.path(root,id)
 assert(B.id(id),'更新路径无效')
 return id=='base' and root or root..'/.updates/'..id..'/picayomi.koplugin'
end
function B.payload(root,id)
 local path=B.path(root,id)
 if id=='base'then return path,B.version(path)end
 assert(lfs.symlinkattributes(root..'/.updates/'..id,'mode')=='directory','更新目录无效')
 assert(lfs.symlinkattributes(path,'mode')=='directory','更新目录无效')
 local meta=B.read(path..'/plugin_update.json')
 assert(meta and meta.format==1 and meta.bootstrap==1 and meta.id=='picayomi','更新包不兼容')
 assert(meta.version==B.version(path) and lfs.symlinkattributes(path..'/main.lua','mode')=='file','更新包不完整')
 B.compare(meta.version,meta.version)
 return path,meta.version
end
function B.installLoader()
 if package.loaded['picayomi.boot.loader']then return end
 local function loader(name)
  local ctx=package.loaded['picayomi.boot.context']
  if not ctx or ctx.runtime==ctx.root or type(name)~='string' or name:find('..',1,true)
      or name:find('[^%w_./%-]')then return '\n\tno selected PicaYomi module'end
  local rel=name:gsub('%.','/')..'.lua'
  local path=ctx.runtime..'/'..rel
  if lfs.symlinkattributes(path,'mode')=='file'then
   local chunk,err=loadfile(path)
   return chunk or function()error(err,0)end
  end
  if lfs.symlinkattributes(ctx.root..'/'..rel,'mode')=='file'then
   return function()error('模块不属于当前插件版本: '..name,0)end
  end
  return '\n\tno selected PicaYomi module'
 end
 -- KOReader resets package.path after plugin discovery. This scoped searcher
 -- keeps later imports on the selected immutable version without changing host
 -- modules or monkey-patching PluginLoader.
 table.insert(package.loaders,2,loader)
 package.loaded['picayomi.boot.loader']=loader
end
function B.select(root)
 root=assert(util.realpath(root),'插件路径不可用')
 local ctx=package.loaded['picayomi.boot.context']
 if ctx then
  if root==ctx.runtime then return nil end
  assert(root==ctx.root,'插件安装路径冲突');return ctx.runtime~=root and ctx.runtime or nil
 end
 local ok,s=pcall(B.state,root)
 if not ok then s={format=1,active='base',error='更新状态损坏，已使用安装版本'}end
 local changed=false
 if not ok and lfs.symlinkattributes(root..'/.updates','mode')=='directory'then
  -- Keep the damaged state for diagnosis, then recover to the installed base.
  local preserved=os.rename(root..'/.updates/state.json',root..'/.updates/state.bad')
  if preserved then changed=true end
 end
 if s.trial then
  s.blocked=s.trial;s.active=s.previous or 'base';s.previous=nil;s.pending=nil;s.trial=nil
  s.error='上次新版启动未完成，已恢复上一版';changed=true
 end
 local base=B.version(root)
 if s.active~='base'then
  local valid,path,version=pcall(B.payload,root,s.active)
  if not valid or B.compare(base,version)>=0 then s.active='base';s.previous=nil;changed=true end
 end
 if s.pending then
  local valid,path,version=pcall(B.payload,root,s.pending)
  local _,current=B.payload(root,s.active)
  if valid and (s.rollback or B.compare(version,current)>0)then
   s.previous=s.active;s.active=s.pending;s.trial=s.active;s.error=nil
  else s.error='待安装更新已失效，继续使用原版本'end
  s.pending=nil;s.rollback=nil;changed=true
 end
 if changed then
  local saved=pcall(B.write,root..'/.updates/state.json',s)
  if not saved then s.active='base';s.error='无法保存更新状态，继续使用安装版本'end
 end
 local runtime=B.payload(root,s.active)
 ctx={root=root,runtime=runtime,id=s.active,boot=B};package.loaded['picayomi.boot.context']=ctx
 B.installLoader()
 return runtime~=root and runtime or nil
end
function B.healthy()
 local ctx=package.loaded['picayomi.boot.context'];if not ctx then return end
 local s=B.state(ctx.root)
 if s.trial==ctx.id then s.trial=nil;B.write(ctx.root..'/.updates/state.json',s)end
end
return B
