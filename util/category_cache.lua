-- Persistent source-scoped category labels; failed refreshes retain old data.
local C={FRESH_SECONDS=86400,RETRY_SECONDS=60,MAX_AGE=30*86400,MAX_BYTES=256*1024,MAX_FILES=32}
local Storage=require('source.extensions.storage')
local json=require('rapidjson')
local lfs=require('libs/libkoreader-lfs')
local attempts={}
local function folder()return require('util.cache').DATA_CACHE_DIR..'/categories'end
local function path(key)return folder()..'/'..require('ffi/sha2').sha256(key)..'.json'end
function C.read(key)
 if not key then return end
 local ok,entry=pcall(function()
  local raw=Storage.read(path(key),C.MAX_BYTES);if not raw then return end
  local value=json.decode(raw)
  assert(value.key==key and type(value.time)=='number' and type(value.data)=='table' and #value.data>0)
  local age=os.time()-value.time;assert(age>=0 and age<C.MAX_AGE)
  return value
 end)
 if ok then return entry end
end
function C.write(key,data)
 if not key or type(data)~='table' or #data==0 then return false end
 local ok=pcall(function()
  local labels={}
  for i,item in ipairs(data)do
   assert(type(item)=='table' and type(item.title)=='string')
   labels[i]={id=item.id,_id=item._id,title=item.title,description=item.description,
    thumb=item.thumb,isWeb=item.isWeb,link=item.link}
  end
  local raw=json.encode{key=key,time=os.time(),data=labels};assert(#raw<=C.MAX_BYTES)
  local keep=path(key);Storage.write(keep,raw)
  local files={}
  for name in lfs.dir(folder())do if name:match('^[a-f0-9]+%.json$')then
   local file=folder()..'/'..name;files[#files+1]={path=file,time=lfs.attributes(file,'modification')or 0}
  end end
  table.sort(files,function(a,b)return a.time==b.time and a.path<b.path or a.time<b.time end)
  local count=#files
  for _,file in ipairs(files)do
   if count<=C.MAX_FILES then break end
   if file.path~=keep and os.remove(file.path)then count=count-1 end
  end
 end)
 if key then attempts[key]=nil end
 return ok
end
function C.admit(key,force)
 if not key then return true end
 local now=os.time();local previous=attempts[key]
 if previous and now<previous.deadline and (previous.busy or not force)then return false end
 local old=C.read(key)
 if not force and old and now-old.time<C.FRESH_SECONDS then return false end
 local count=0
 for k,v in pairs(attempts)do if now>=v.deadline then attempts[k]=nil else count=count+1 end end
 if count>=C.MAX_FILES then return false end
 attempts[key]={busy=true,deadline=now+60};return true
end
function C.failure(key)
 if key then attempts[key]={busy=false,deadline=os.time()+C.RETRY_SECONDS}end
end
return C
