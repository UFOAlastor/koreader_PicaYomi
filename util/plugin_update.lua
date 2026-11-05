-- Release selection and persistent update policy. No source/account traffic.
local M={API='https://api.github.com/repos/UFOAlastor/koreader_PicaYomi/releases/latest',MAX_ZIP=16*1024*1024}
local Store=require('source.extensions.storage')
local json=require('rapidjson')
function M.context()
 local ctx=package.loaded['picayomi.boot.context']
 if ctx then return ctx end
 local root=assert(debug.getinfo(1,'S').source:match('^@(.*)/util/[^/]+$'))
 root=assert(require('ffi/util').realpath(root));return {root=root,runtime=root,boot=assert(loadfile(root..'/plugin_boot.lua'))()}
end
function M.autoEnabled()return require('util.config'):get('plugin_auto_update')==true end
function M.version()local c=M.context();return assert(c.boot.version(c.runtime))end
function M.root()return M.context().root end
function M.state()local c=M.context();return c.boot.state(c.root)end
function M.save(s)
 local c=M.context();Store.mkdir(c.root..'/.updates');c.boot.write(c.root..'/.updates/state.json',s)
end
function M.parse(data,current)
 local B=M.context().boot
 assert(type(data)=='table' and data.draft==false and data.prerelease==false,'发行信息无效')
 local version=type(data.tag_name)=='string' and data.tag_name:match('^v(%d+%.%d+%.%d+)$')
 assert(version and B.compare(version,version)==0,'发行版本无效')
 if B.compare(version,current)<=0 then return {latest=true,version=current}end
 local name='picayomi.koplugin-'..version..'.zip';local found
 assert(type(data.assets)=='table' and #data.assets<=32,'发行附件无效')
 for _,a in ipairs(data.assets)do
  if a.name==name then
   assert(not found,'发行附件重复')
   assert(a.state=='uploaded' and type(a.size)=='number' and a.size%1==0 and a.size>0 and a.size<=M.MAX_ZIP,'发行包大小无效')
   local digest=type(a.digest)=='string' and a.digest:match('^sha256:([0-9a-f]+)$')
   assert(digest and #digest==64,'发行包缺少可信校验值')
   local url='https://github.com/UFOAlastor/koreader_PicaYomi/releases/download/v'..version..'/'..name
   assert(a.browser_download_url==url,'发行包来源不符')
   found={version=version,url=url,size=a.size,digest=digest,notes=type(data.body)=='string' and data.body:sub(1,4000)or ''}
  end
 end
 assert(found,'没有可用的插件安装包');return found
end
function M.check()
 local s=M.state();local now=os.time()
 local ok,result=pcall(function()
  local raw=require('source.extensions.https').get(M.API,512*1024)
  return M.parse(json.decode(raw),M.version())
 end)
 s.checked_at=now;s.next_check=now+(ok and 24*3600 or 6*3600)
 M.save(s)
 if not ok then error(result,0)end
 if result.digest and result.digest==s.blocked then error('该版本曾启动失败，已停止重复安装，请等待后续版本',0)end
 return result
end
function M.prepare(release)
 assert(type(release)=='table','更新信息无效')
 -- Revalidate the selected immutable asset, not a newly fetched latest release.
 local selected=M.parse({draft=false,prerelease=false,tag_name='v'..release.version,assets={{name='picayomi.koplugin-'..release.version..'.zip',
  state='uploaded',size=release.size,digest='sha256:'..release.digest,browser_download_url=release.url}}},M.version())
 local root=M.root();local lfs=require('libs/libkoreader-lfs')
 local attr=lfs.symlinkattributes(root..'/.updates','mode');assert(not attr or attr=='directory','更新目录不安全')
 Store.mkdir(root..'/.updates')
 assert(not selected.latest,'当前已是最新版本')
 assert(pcall(require,'ffi/archiver'),'当前 KOReader 不支持在线安装，请手动更新插件')
 assert(not M.stage,'已有更新任务')
 local c=M.context();local state=M.state()
 assert(state.blocked~=release.digest,'该版本曾启动失败，请等待后续版本')
 assert(not state.pending,'已有待启用更新，请先取消或重启')
 local dest=root..'/.updates/'..release.digest
 if lfs.symlinkattributes(dest)then
  local _,version=c.boot.payload(root,release.digest)
  assert(version==release.version,'已下载更新版本不符')
  state.pending=release.digest;state.rollback=nil;M.save(state)
  return {digest=release.digest,version=version}
 end
 -- Retain only referenced generations; immutable abandoned payloads are safe
 -- to delete under their lease. Never traverse user data or unknown paths.
 local keep={[state.active]=true,[c.id or 'base']=true}
 for _,key in ipairs{'previous','pending','trial'}do if state[key]then keep[state[key]]=true end end
 for name in lfs.dir(root..'/.updates')do
  if name~='base'and c.boot.id(name)and not keep[name]then
   local valid=pcall(c.boot.payload,root,name)
   if valid then require('util.plugin_update_stage').remove(root..'/.updates/'..name)end
  end
 end
 local dir=require('util.plugin_update_stage').create(root);M.stage=dir
 local spec={kind='plugin_update',root=root,directory=dir,release=release}
 local Async=require('network.async_task')
 local result=Async.await(function()return require('network.plugin_update_worker').prepare(spec)end,spec)
 assert(result and result.digest==release.digest,'更新准备结果无效')
 local c=M.context();local s=M.state()
 assert(M.stage==dir,'更新已取消')
 local lease=assert(require('util.plugin_update_stage').acquire(dir),'后台更新尚未退出')
 local ok,err=pcall(function()
  local dest=root..'/.updates/'..result.digest
  assert(not lfs.symlinkattributes(dest),'该更新已准备，请重启后再检查')
  assert(os.rename(dir,dest),'无法保存更新包')
  assert(require('ffi/util').fsyncDirectory(root..'/.updates'))
  local _,version=c.boot.payload(root,result.digest)
  assert(version==release.version and c.boot.compare(version,M.version())>0,'更新版本已变化')
  s.pending=result.digest;s.rollback=nil;M.save(s)
 end)
 lease:close();M.cleanup();if not ok then error(err,0)end
 return result
end
function M.cleanup()
 local dir=M.stage;M.stage=nil
 if dir then pcall(require('util.plugin_update_stage').remove,dir)end
end
function M.collect()
 local ctx=M.context();local state=M.state()
 if state.trial then return end
 local keep={base=true}
 for _,id in ipairs{state.active,ctx.id or 'base'}do keep[id]=true end
 for _,key in ipairs{'previous','pending'}do if state[key]then keep[state[key]]=true end end
 local lfs=require('libs/libkoreader-lfs')
 local parent=ctx.root..'/.updates'
 if lfs.symlinkattributes(parent,'mode')~='directory'then return end
 local PluginUpdateStage=require('util.plugin_update_stage')
 for name in lfs.dir(parent)do
  if (ctx.boot.id(name) and name~='base' and not keep[name]) or name:match('^stage%-%x+$')then
   PluginUpdateStage.remove(parent..'/'..name)
  end
 end
end
function M.markHealthy()
 M.context().boot.healthy()
 M.collect()
end
function M.cancelPending()
 local s=M.state();s.pending=nil;s.rollback=nil;M.save(s)
 M.collect()
end
function M.rollback()
 local s=M.state();assert(s.previous and not s.pending,'没有可恢复版本')
 M.context().boot.payload(M.root(),s.previous);s.pending=s.previous;s.rollback=true;M.save(s)
end
return M
