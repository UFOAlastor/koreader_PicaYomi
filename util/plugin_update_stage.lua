-- A lease is held for the entire writer lifetime. Cancellation never removes
-- a directory still owned by a worker. Unique names isolate late arrivals.
local S={}
local lfs=require('libs/libkoreader-lfs')
local util=require('ffi/util')
local function remove(path)
 local mode=lfs.symlinkattributes(path,'mode')
 if mode=='directory'then
  for f in lfs.dir(path)do if f~='.'and f~='..'then remove(path..'/'..f)end end
  assert(lfs.rmdir(path))
 elseif mode then assert(os.remove(path))end
end
function S.acquire(dir)
 if lfs.symlinkattributes(dir,'mode')~='directory' or lfs.symlinkattributes(dir..'/lease','mode')~='file'then return nil end
 local before=lfs.attributes(dir..'/lease')
 local f=io.open(dir..'/lease','r+b');if not f then return nil end
 if not lfs.lock(f,'w')then f:close();return nil end
 local after=lfs.attributes(dir..'/lease')
 if not after or before.ino~=after.ino or before.dev~=after.dev then f:close();return nil end
 return f
end
function S.remove(dir)
 if lfs.symlinkattributes(dir,'mode')=='directory'and not lfs.symlinkattributes(dir..'/lease')then
  -- Interrupted between mkdir and lease creation: a worker cannot own it.
  remove(dir);return true
 end
 local f=S.acquire(dir);if not f then return false end
 local ok,err=pcall(remove,dir);f:close();if not ok then error(err,0)end
 return true
end
function S.create(root)
 local parent=root..'/.updates';local count=0
 for name in lfs.dir(parent)do
  if name:match('^stage%-%x+$')then
   if not S.remove(parent..'/'..name)then count=count+1 end
  end
 end
 assert(count<3,'更新任务仍在退出，请稍后重试')
 local token=require('ffi/sha2').sha256(tostring({})..tostring(require('socket').gettime()))
 local dir=parent..'/stage-'..token
 assert(lfs.mkdir(dir),'无法创建更新暂存目录')
 local f=assert(io.open(dir..'/lease','wb'));assert(util.fsyncOpenedFile(f,true));assert(f:close())
 assert(util.fsyncDirectory(dir));return dir
end
return S
