-- A bounded, verified download and archive inspection in a separate process.
local W={MAX_EXPANDED=32*1024*1024,MAX_FILES=512}
local lfs=require('libs/libkoreader-lfs')
local util=require('ffi/util')
local Store=require('source.extensions.storage')
local function safe_path(path)
 if type(path)~='string' or #path>240 or path:find('[^%w%._/%-]') or path:find('//',1,true) then return end
 local rel=path:match('^picayomi%.koplugin/(.+)$')
 if not rel then return end
 for p in rel:gmatch('[^/]+')do if p=='.'or p=='..'or p=='.updates'then return end end
 return rel
end
W.safe_path=safe_path
function W.download(url,path,size,digest)
 local Net=require('source.extensions.https')
 for redirects=0,3 do
  local host=url:match('^https://([^/]+)')
  assert(Net.validURL(url) and (host=='github.com' or host=='release-assets.githubusercontent.com'),'更新重定向来源不符')
  local f=assert(io.open(path,'wb'),'无法写入更新文件');local hash=require('ffi/sha2').sha256();local count=0
  local ok,body,status,headers=pcall(Net.request,url,size,function(chunk)
   count=count+#chunk;hash(chunk);local wrote,err=f:write(chunk);return wrote and 1 or nil,err
  end)
  local synced=ok and status==200 and util.fsyncOpenedFile(f,true);local closed=f:close()
  assert(ok and closed,'更新下载失败')
  if status==200 then assert(synced and count==size and hash()==digest,'更新包大小或校验值不符');return true end
  assert((status==301 or status==302 or status==303 or status==307 or status==308)and redirects<3,'更新下载失败')
  url=headers and (headers.location or headers.Location);assert(type(url)=='string','更新重定向无效')
 end
end
function W.extract(archive,directory,version)
 local ffi=require('ffi');require('ffi/libarchive_h')
 pcall(ffi.cdef,'const char *archive_entry_hardlink(struct archive_entry *); const char *archive_entry_symlink(struct archive_entry *);')
 local lib=ffi.loadlib('archive','13');local arc=require('ffi/archiver').Reader:new()
 local files,total,seen={},0,{}
 local ok,err=pcall(function()
  assert(arc:open(archive),'无法打开更新包')
  for entry in arc:iterate()do
   local rel=safe_path(entry.path)
   if entry.path=='picayomi.koplugin/'and entry.mode=='directory'then rel=''end
   assert(rel and not seen[entry.path]and (entry.mode=='file'or entry.mode=='directory'),'更新包路径或文件类型无效')
   assert(lib.archive_entry_hardlink(arc.archive_entry)==nil and lib.archive_entry_symlink(arc.archive_entry)==nil,'更新包不允许链接')
   seen[entry.path]=true
   local size=tonumber(entry.size);assert(size and size>=0 and size<=8*1024*1024,'更新文件过大')
   total=total+size;files[#files+1]=entry.path;assert(total<=W.MAX_EXPANDED and #files<=W.MAX_FILES,'更新解包超限')
   -- Never use archive-owned permissions/paths for filesystem extraction.
   if entry.mode=='directory'then Store.mkdir(directory..'/'..entry.path)
   else
    local raw=assert(arc:extractToMemory(entry.path),'更新文件不完整');assert(#raw==size,'更新文件长度不符')
    local path=directory..'/'..entry.path;Store.write(path,raw)
    if path:match('%.lua$')then assert(loadfile(path),'更新脚本语法错误')end
    local f=assert(io.open(path,'rb'));local synced=util.fsyncOpenedFile(f,true);f:close();assert(synced,'无法同步更新文件')
   end
  end
  assert(not arc.err,'更新压缩包损坏')
  local root=directory..'/picayomi.koplugin'
  local meta=require('rapidjson').decode(assert(Store.read(root..'/plugin_update.json',4096)))
  assert(meta.format==1 and meta.bootstrap==1 and meta.id=='picayomi' and meta.version==version,'更新包不兼容')
  local y,m
  if type(meta.min_koreader)=='string'then y,m=meta.min_koreader:match('^(%d%d%d%d)%.(%d%d)$')end
  local host=require('version'):getNormalizedCurrentVersion()
  assert(y and m and tonumber(m)>=1 and tonumber(m)<=12 and host and host>=tonumber(y..m)*1000000,'请先升级 KOReader 后再更新插件')
  local Boot=assert(loadfile(assert(debug.getinfo(1,'S').source:match('^@(.*)/network/[^/]+$'))..'/plugin_boot.lua'))()
  assert(Boot.version(root)==version,'更新版本不符')
  for _,p in ipairs{'main.lua','plugin_boot.lua','ui/settings/plugin_update.lua'}do assert(lfs.symlinkattributes(root..'/'..p,'mode')=='file','更新包缺少必需文件')end
  local function syncdirs(path)
   for name in lfs.dir(path)do if name~='.'and name~='..'and lfs.symlinkattributes(path..'/'..name,'mode')=='directory'then syncdirs(path..'/'..name)end end
   assert(util.fsyncDirectory(path),'无法同步更新目录')
  end
  syncdirs(root)
 end)
 arc:close();if not ok then error(err,0)end
 return total
end
-- Stable KOReader returns total/free; newer hosts also return available space.
-- Prefer available when supplied, and keep an unreadable filesystem distinct from low space.
function W.availableSpace(path)
 local total,free,available=util.df(path)
 local bytes=available
 if bytes==nil then bytes=free end
 assert(type(total)=='number' and type(bytes)=='number' and bytes==bytes and bytes>=0,
  '无法读取存储空间，请稍后重试')
 return bytes
end
function W.prepare(spec)
 local r=spec.release
 assert(type(spec.directory)=='string' and spec.directory:sub(1,#spec.root+16)==spec.root..'/.updates/stage-' and spec.directory:sub(#spec.root+17):match('^%x+$') and util.realpath(spec.root)==spec.root,'更新目标路径无效')
 assert(lfs.symlinkattributes(spec.directory,'mode')=='directory','更新暂存目录无效')
 local free=W.availableSpace(spec.directory);assert(free>=W.MAX_EXPANDED+r.size+4*1024*1024,'存储空间不足，无法准备更新')
 local lease=assert(require('util.plugin_update_stage').acquire(spec.directory),'更新任务已取消或正在使用')
 local ok,result=pcall(function()
  local file=spec.directory..'/update.zip';W.download(r.url,file,r.size,r.digest)
  W.extract(file,spec.directory,r.version);assert(os.remove(file))
  assert(util.fsyncDirectory(spec.directory))
  return {digest=r.digest,version=r.version}
 end)
 lease:close();if not ok then error(result,0)end
 return result
end
return W
