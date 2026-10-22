local json=require("rapidjson")
local Bundle=require("source.extensions.package")
local Storage=require("source.extensions.storage")
local Net=require("source.extensions.https")
local Catalog=require("source.extensions.catalog")
local sha=require("ffi/sha2").sha256
local Manager={}; Manager.__index=Manager
local function copy(v) return json.decode(json.encode(v)) end
local function version()
    local path=assert(debug.getinfo(1,"S").source:match("^@(.*)/[^/]+$"))
    return assert(dofile(path.."/../../_meta.lua").version)
end
local function blank() return {format=2,sources={},repositories={},removed={},archives={},auto_check=true} end
function Manager.new(opts)
    opts=opts or {}
    local self=setmetatable({root=opts.root or os.getenv("PICAYOMI_EXTENSION_DATA_DIR") or require("datastorage"):getDataDir().."/picayomi/extensions",
        host_version=opts.host_version or version(),fetch=opts.fetch or Net.get,now=opts.now or os.time,
        errors={},loaded={},contexts={},booted=false},Manager)
    local raw
    local ok,state=pcall(function()
        raw=Storage.read(self.root.."/state.json")
        if not raw then return blank() end
        local s=json.decode(raw)
        assert(type(s)=="table" and (s.format==1 or s.format==2) and type(s.sources)=="table" and type(s.repositories)=="table","扩展状态损坏")
        local migrating=s.format==1
        s.removed=s.removed or {}; s.archives=s.archives or {}; s.auto_check=s.auto_check~=false
        assert(type(s.archives)=="table","处理包信任记录损坏")
        for id,versions in pairs(s.archives) do
            assert(Bundle.id(id) and type(versions)=="table","处理包信任记录损坏")
            for hash,record in pairs(versions) do
                assert(Catalog.digest(hash) and type(record)=="table" and type(record.legacy)=="boolean","处理包信任记录损坏")
            end
        end
        assert(type(s.removed)=="table", "卸载状态损坏")
        for id,value in pairs(s.removed) do assert(Bundle.id(id) and value==true,"卸载状态损坏") end
        for id,r in pairs(s.sources) do
            assert(Bundle.id(id) and type(r)=="table" and Catalog.digest(r.current)
                and (not r.previous or Catalog.digest(r.previous)) and type(r.enabled)=="boolean" and type(r.origin)=="string","扩展状态条目损坏")
            Bundle.manifest(r.manifest,self.host_version,true); assert(r.manifest.id==id,"扩展状态 ID 不符")
            if migrating then r.pending=r.current; r.active=nil; r.last_good=r.previous end
            for _,key in ipairs({"active","pending","last_good","activating","failed"}) do
                assert(r[key]==nil or Catalog.digest(r[key]),"扩展版本状态损坏")
            end
            r.quarantine=r.quarantine or {}
            assert(type(r.quarantine)=="table", "失败隔离状态损坏")
        end
        for url,repo in pairs(s.repositories) do
            assert(Net.validURL(url) and type(repo)=="table" and type(repo.name)=="string" and type(repo.sources)=="table","订阅状态损坏")
            Catalog.validate({format=repo.public_key and 2 or 1,name=repo.name,sources=repo.sources,
                publisher_id=repo.publisher_id,revision=repo.revision})
            if repo.public_key then require("source.extensions.signature").unhex(repo.public_key,32) end
            repo.url=url; repo.auto_install=repo.auto_install==true
        end
        s.format=2
        if migrating then Storage.write(self.root.."/state.v1.backup.json",raw) end
        return s
    end)
    self.state=ok and state or blank()
    if not ok then self.state_error=tostring(state) end
    self.bundles=opts.bundles or {}
    if not opts.root and not opts.bundles then
        local read,bundles,errors=pcall(function() return require("source.extensions.bundled").read() end)
        if read then
            self.bundles=bundles
            for id,err in pairs(errors or {}) do self.errors[id]=err end
        else self.errors.bundled=tostring(bundles) end
    end
    if not self.state_error then
        local seeded,err=pcall(function() self:seed() end)
        if not seeded then self.state_error=tostring(err) end
    end
    self.initial=copy(self.state.sources)
    return self
end
function Manager:_save(state)
    assert(not self.state_error,self.state_error)
    assert(#json.encode(state)<=2*1024*1024,"扩展目录总大小超限，请移除不用的订阅")
    Storage.json(self.root.."/state.json",state); self.state=state; return true
end
function Manager:seed()
    local state=copy(self.state); local changed=false
    state.archives=state.archives or {}
    for id,raw in pairs(self.bundles) do
        local old=state.sources[id]
        if not state.removed[id] then
            local valid,record=pcall(function()
                local pkg=Bundle.decode(raw,self.host_version); local hash=sha(raw)
                assert(pkg.manifest.id==id and Bundle.legacy(id) and pkg.manifest.publisher_id=="picayomi.legacy",
                    "附带源身份不符")
                if old then
                    -- Bundled host upgrades may migrate their own trusted seeds.
                    -- Signed repositories and user-pinned versions keep their policy.
                    if not old.bundled or old.origin~="bundled" or not old.legacy or old.pinned
                        or old.publisher_id~=pkg.manifest.publisher_id
                        or Bundle.compare(pkg.manifest.version,old.manifest.version)<=0
                        or (old.quarantine or {})[hash] then return nil end
                    assert((old.manifest.data_schema_version or 1)==(pkg.manifest.data_schema_version or 1),"附带源需要数据迁移器")
                end
                self:_store(id,hash,raw)
                local rec=old and copy(old) or {enabled=true,origin="bundled",legacy=true,bundled=true,quarantine={}}
                rec.previous=old and (old.active or old.current) or nil
                rec.current,rec.pending,rec.manifest=hash,hash,pkg.manifest
                rec.publisher_id=pkg.manifest.publisher_id
                return rec
            end)
            if valid and record then
                state.sources[id]=record
                state.archives[id]=state.archives[id] or {}
                state.archives[id][record.current]={legacy=true,publisher_id=record.publisher_id}
                if old then
                    for _,key in ipairs({"active","current","previous","last_good"}) do
                        if old[key] then state.archives[id][old[key]]={legacy=true,publisher_id=old.publisher_id} end
                    end
                end
                changed=true
            elseif not valid then self.errors[id]=tostring(record) end
        end
    end
    if changed then self:_save(state) end
end

function Manager:_package(id,hash)
    assert(Bundle.id(id) and Catalog.digest(hash),"源包路径无效")
    local raw=assert(Storage.read(self.root.."/packages/"..id.."/"..hash..".json",Bundle.MAX_BYTES),"源包文件不存在")
    assert(sha(raw)==hash,"已安装源包摘要不符")
    local pkg=Bundle.decode(raw,self.host_version); assert(pkg.manifest.id==id,"源包 ID 不符")
    return pkg
end
function Manager:_store(id,hash,raw)
    local path=self.root.."/packages/"..id.."/"..hash..".json"
    local existing=Storage.read(path,Bundle.MAX_BYTES)
    if existing then assert(sha(existing)==hash,"已有源包损坏"); return end
    local lfs=require("libs/libkoreader-lfs")
    local total=0
    local function size(dir)
        if lfs.attributes(dir,"mode")~="directory" then return end
        for n in lfs.dir(dir) do
            if n~="." and n~=".." then
                local p=dir.."/"..n
                if lfs.attributes(p,"mode")=="directory" then size(p)
                else total=total+(lfs.attributes(p,"size") or 0) end
            end
        end
    end
    size(self.root.."/packages")
    assert(total+#raw<=64*1024*1024,"源包存储达到 64 MiB 上限，请清理旧版本")
    local free=lfs.df and lfs.df(self.root)
    if type(free)=="table" and free.available then assert(free.available>#raw*2,"存储空间不足") end
    Storage.write(self.root.."/packages/"..id.."/"..hash..".json",raw)
end
function Manager:install(raw,origin,expected,trust_legacy)
    assert(not self.state_error,self.state_error)
    local pkg=Bundle.decode(raw,self.host_version); local m,hash=pkg.manifest,sha(raw)
    origin=origin or "local"
    local old=self.state.sources[m.id]
    local repo=self.state.repositories[origin]
    local bootstrap=trust_legacy==true and not old and origin=="local" and expected==nil
        and Bundle.legacy(m.id) and m.identity_policy=="legacy" and m.publisher_id=="picayomi.legacy"
    if expected then
        for _,k in ipairs({"id","version","api_version","min_app_version","max_app_version","publisher_id"}) do
            assert(expected[k]==m[k],"源包与订阅条目不符: "..k)
        end
        assert(expected.sha256==hash and (not expected.size or expected.size==#raw),"源包摘要或大小不符")
        if repo and repo.public_key then require("source.extensions.signature").verify(repo.public_key,expected.signature,"package",raw) end
    end
    if Bundle.legacy(m.id) and not bootstrap then
        assert(old and old.legacy and old.publisher_id==m.publisher_id,"此源 ID 的历史身份未获授权")
        assert(expected and repo and repo.public_key and repo.publisher_id==old.publisher_id,"历史源更新需要已绑定的签名订阅")
    end
    if old then
        if old.manifest.publisher_id then assert(old.manifest.publisher_id==m.publisher_id,"源发布者身份不能在更新时改变") end
        if old.publisher_id then
            assert(repo and repo.public_key and old.publisher_id==repo.publisher_id and old.public_key==repo.public_key,
                "源的发布者或密钥不符，请显式重新绑定")
        else assert(old.origin==origin,"源已绑定其他来源") end
        if old.current==hash then return true,"此版本已安装" end
        assert(Bundle.compare(m.version,old.manifest.version)>0,"新包版本必须高于已安装版本；旧版请使用回滚")
        assert((m.data_schema_version or 1)==(old.manifest.data_schema_version or 1),"源数据格式变化，需主程序提供迁移器")
    end
    self:_store(m.id,hash,raw)
    local state=copy(self.state)
    local r=old and copy(old) or {enabled=true,quarantine={}}
    r.current,r.pending,r.previous=hash,hash,r.active or r.current
    r.origin,r.manifest=origin,m
    r.public_key=repo and repo.public_key or old and old.public_key
    r.publisher_id=repo and repo.public_key and repo.publisher_id or old and old.publisher_id
    if bootstrap then r.legacy=true; r.publisher_id=m.publisher_id end
    state.sources[m.id]=r; state.removed[m.id]=nil
    state.archives=state.archives or {}; state.archives[m.id]=state.archives[m.id] or {}
    state.archives[m.id][hash]={legacy=r.legacy==true,publisher_id=m.publisher_id}
    self:_save(state); return true,"已准备更新，重启 KOReader 后生效"
end
function Manager:import(path) return self:install(assert(Storage.read(path,Bundle.MAX_BYTES),"无法读取源包")) end
-- Preview and confirm the same bytes: do not reread a selected path after trust.
function Manager:previewImport(path)
    local raw=assert(Storage.read(path,Bundle.MAX_BYTES),"无法读取源包")
    local manifest=Bundle.decode(raw,self.host_version).manifest
    local bootstrap=Bundle.legacy(manifest.id) and not self.state.sources[manifest.id]
    return {raw=raw,manifest=manifest,needs_legacy_trust=bootstrap}
end
function Manager:enable(id,enabled)
    local state=copy(self.state); assert(state.sources[id],"源未安装").enabled=enabled==true
    return self:_save(state)
end
function Manager:pin(id,pinned)
    local state=copy(self.state); assert(state.sources[id],"源未安装").pinned=pinned==true
    return self:_save(state)
end
function Manager:uninstall(id)
    local state=copy(self.state); assert(state.sources[id],"源未安装")
    -- Archive the verified active identity before removing the source record.
    local r=state.sources[id]
    state.archives=state.archives or {}; state.archives[id]=state.archives[id] or {}
    for _,key in ipairs({"active","current","previous","last_good"}) do
        if r[key] then state.archives[id][r[key]]={legacy=r.legacy==true,publisher_id=r.manifest.publisher_id} end
    end
    state.sources[id]=nil; state.removed[id]=true; return self:_save(state)
end
function Manager:rollback(id)
    local state=copy(self.state); local r=assert(state.sources[id],"源未安装")
    local hash=assert(r.last_good or r.previous,"没有可回滚版本")
    local pkg=self:_package(id,hash)
    assert((pkg.manifest.data_schema_version or 1)==(r.manifest.data_schema_version or 1),"旧版本无法读取当前数据")
    r.previous,r.current,r.pending=r.current,hash,hash; r.manifest=pkg.manifest
    r.pinned=true; return self:_save(state)
end
function Manager:restoreBundled(id)
    local raw=assert(self.bundles[id],"没有附带恢复包")
    local pkg=Bundle.decode(raw,self.host_version)
    local state=copy(self.state); local r=state.sources[id]
    assert(not r or (r.manifest.data_schema_version or 1)==(pkg.manifest.data_schema_version or 1),"附带版本无法读取现有数据")
    local hash=sha(raw); self:_store(id,hash,raw)
    r=r or {enabled=true,quarantine={}}
    r.previous=r.active or r.current
    r.current,r.pending,r.manifest=hash,hash,pkg.manifest
    r.origin,r.publisher_id,r.public_key="bundled",pkg.manifest.publisher_id,nil
    r.legacy,r.bundled,r.pinned=true,true,true
    r.quarantine[hash]=nil
    state.sources[id],state.removed[id]=r,nil
    return self:_save(state)
end
function Manager:retry(id,hash)
    local state=copy(self.state); local r=assert(state.sources[id],"源未安装")
    hash=hash or r.failed or r.current
    local pkg=self:_package(id,hash)
    assert((pkg.manifest.data_schema_version or 1)==(r.manifest.data_schema_version or 1),"数据格式不兼容")
    r.quarantine[hash]=nil; r.current,r.pending,r.manifest=hash,hash,pkg.manifest
    return self:_save(state)
end
function Manager:pending(id)
    local a,b=self.initial[id],self.state.sources[id]
    return (a and a.current)~=(b and b.current) or (a and a.enabled)~=(b and b.enabled)
        or b and b.pending~=nil or false
end
function Manager:_context(id,hash,rec)
    if not self.contexts[hash] then
        local pkg=self:_package(id,hash)
        self.contexts[hash]=require("source.extensions.loader").open(pkg,hash,function(key,default)
            local v=require("util.config"):get("extensions_settings."..id.."."..key)
            return v==nil and default or v
        end,rec.legacy==true)
    end
    return self.contexts[hash]
end
function Manager:module(id,name)
    local r=assert(self.initial[id],"源未安装: "..id)
    return self:_context(id,r.active or r.current,r).require(name)
end
function Manager:processorContext(desc)
    local id,hash=desc.source_id,desc.digest
    local rec=(self.state.archives or {})[id] and self.state.archives[id][hash]
    if not rec then
        local active=self.state.sources[id]
        if active then
            for _,key in ipairs({"active","current","previous","last_good"}) do if active[key]==hash then rec=active; break end end
        end
    end
    assert(rec,"离线处理包未经信任或已丢失，请重新安装原源包")
    local context=self:_context(id,hash,rec)
    if context.pkg.manifest.api_version>=3 and not context.processor_ready then
        require("source.extensions.loader").activate(context)
        context.processor_ready=true
    end
    return context
end
function Manager:loadSources(registry)
    if self.booted then
        for _,s in pairs(self.loaded) do if not registry.get or not registry:get(s.identifier) then registry:register(s) end end
        return
    end
    self.booted=true
    for id,initial in pairs(self.initial) do
        if initial.enabled then
            local r=self.state.sources[id]
            if r.activating then
                local state=copy(self.state); local current=state.sources[id]
                current.quarantine[current.activating]="上次激活未完成"; current.failed=current.activating; current.activating=nil
                current.pending=nil; current.current=current.active or current.last_good or current.current
                if current.active then
                    -- The previous package may also be corrupt. Let the guarded
                    -- activation below quarantine it without aborting other sources.
                    local readable,pkg=pcall(self._package,self,id,current.active)
                    if readable then current.manifest=pkg.manifest end
                end
                self:_save(state); r=self.state.sources[id]
                self.errors[id]="上次新版本激活未完成，已恢复旧版"
            end
            local hash=r.pending or r.active or r.current
            local function activate(target)
                assert(not r.quarantine[target],"此版本已隔离，请显式重试")
                local state=copy(self.state); state.sources[id].activating=target; self:_save(state)
                local source=require("source.extensions.loader").activate(self:_context(id,target,r))
                state=copy(self.state); local s=state.sources[id]
                if s.active and s.active~=target then s.last_good=s.active end
                s.active,s.current,s.pending,s.activating=target,target,nil,nil
                if s.failed==target then s.failed=nil end
                s.manifest=self:_package(id,target).manifest
                self:_save(state); return source
            end
            local ok,source=pcall(activate,hash)
            if not ok then
                self.errors[id]=tostring(source)
                local state=copy(self.state); local s=state.sources[id]
                s.activating=nil; s.pending=nil; s.quarantine[hash]=tostring(source); s.failed=hash
                self:_save(state)
                local fallback=r.active and r.active~=hash and r.active or r.last_good
                if fallback and fallback~=hash then
                    ok,source=pcall(activate,fallback)
                    if not ok then
                        local failed=copy(self.state); local item=failed.sources[id]
                        item.activating=nil; item.quarantine[fallback]=tostring(source)
                        self:_save(failed)
                        self.errors[id]=self.errors[id].."；旧版本也无法恢复："..tostring(source)
                    end
                end
            end
            if ok then self.loaded[id]=source; registry:register(source) end
        end
    end
    self.initial=copy(self.state.sources)
    self:collect()
end
function Manager:collect()
    -- Only at process boot, before this process can start workers. Never at update time.
    local lfs=require("libs/libkoreader-lfs")
    local dir=self.root.."/packages"
    if lfs.attributes(dir,"mode")~="directory" then return end
    local library=require("util.offline_library")
    local references=library.packageReferences()
    -- A corrupt offline manifest must never cause irreversible package deletion.
    if not references then return end
    for id in lfs.dir(dir) do
        if Bundle.id(id) and lfs.attributes(dir.."/"..id,"mode")=="directory" then
            local r=self.state.sources[id]; local keep={}
            if r then for _,k in ipairs({"active","pending","last_good","current","previous","failed"}) do if r[k] then keep[r[k]]=true end end end
            for hash in pairs(references[id] or {}) do keep[hash]=true end
            for n in lfs.dir(dir.."/"..id) do
                local h=n:match("^([0-9a-f]+)%.json$")
                if h and #h==64 and not keep[h] then os.remove(dir.."/"..id.."/"..n) end
            end
        end
    end
end
function Manager:addRepository(url)
    assert(Net.validURL(url),"请输入 HTTPS 订阅地址")
    local state=copy(self.state); assert(not state.repositories[url],"订阅已存在")
    local count=0; for _ in pairs(state.repositories) do count=count+1 end
    assert(count<20,"订阅数量已达上限")
    state.repositories[url]={url=url,name=url,sources={},auto_install=false}
    return self:_save(state)
end
function Manager:removeRepository(url)
    local state=copy(self.state); state.repositories[url]=nil; return self:_save(state)
end
function Manager:_previewRepository(url)
    local raw=self.fetch(url,512*1024); local envelope=json.decode(raw)
    local data,key
    if envelope and envelope.signed==1 then
        assert(type(envelope.payload)=="string" and #envelope.payload<=480*1024,"签名目录过大")
        key=envelope.public_key
        require("source.extensions.signature").verify(key,envelope.signature,"index",envelope.payload)
        data=Catalog.validate(json.decode(envelope.payload)); assert(data.format==2,"签名目录格式无效")
    else data=Catalog.validate(envelope); assert(data.format==1,"新版目录必须签名") end
    return {data=data,key=key,payload_hash=key and sha(envelope.payload),envelope=envelope}
end
function Manager:checkFailure(url,err)
    local state=copy(self.state); local r=state.repositories[url]
    if r then
        r.last_attempt=self.now(); r.failures=(r.failures or 0)+1; r.error=tostring(err)
        r.next_check=self.now()+({900,3600,21600,86400})[math.min(r.failures,4)]
        self:_save(state)
    end
end
function Manager:previewRepository(url)
    if self.state.repositories[url] then
        local state=copy(self.state); state.repositories[url].last_attempt=self.now(); self:_save(state)
    end
    local ok,result=pcall(self._previewRepository,self,url)
    if not ok then self:checkFailure(url,result); error(result) end
    return result
end
function Manager:acceptRepository(url,preview,confirm_identity)
    local state=copy(self.state); local r=assert(state.repositories[url],"订阅已移除")
    local data,key=preview.data,preview.key
    if r.public_key then
        assert(key,"签名订阅不能降级为未签名")
        assert(r.publisher_id==data.publisher_id,"订阅发布者改变")
        if key~=r.public_key then
            assert(confirm_identity,"发布者密钥已改变，请确认指纹")
            if preview.envelope.rotation then
                require("source.extensions.signature").verify(r.public_key,preview.envelope.rotation,"rotation",data.publisher_id.."\n"..key)
            else assert(confirm_identity=="reset","缺少旧密钥签名，请显式重新信任发布身份") end
        end
        assert(data.revision>=(r.revision or 0),"拒绝回放旧订阅目录")
        if data.revision==r.revision then assert(preview.payload_hash==r.payload_hash,"同一修订号内容发生变化") end
    elseif key then assert(confirm_identity,"首次签名订阅需要确认发布者及指纹") end
    for _,e in ipairs(data.sources) do
        for _,old in ipairs(r.sources or {}) do
            assert(e.id~=old.id or e.version~=old.version or e.sha256==old.sha256,"同一源版本内容发生变化")
        end
    end
    if r.public_key and key~=r.public_key then
        for _,source in pairs(state.sources) do
            if source.origin==url and source.public_key==r.public_key then source.public_key=key end
        end
    end
    r.public_key,r.publisher_id,r.revision,r.payload_hash=key,data.publisher_id,data.revision,preview.payload_hash
    r.name,r.sources,r.refreshed_at,r.last_success=data.name,data.sources,self.now(),self.now()
    r.failures,r.error,r.next_check=0,nil,self.now()+24*3600
    return self:_save(state)
end
function Manager:refreshRepository(url)
    assert(self.state.repositories[url],"订阅不存在")
    local state=copy(self.state); state.repositories[url].last_attempt=self.now(); self:_save(state)
    local ok,result=pcall(function() return self:acceptRepository(url,self:previewRepository(url)) end)
    if ok then return result end
    local repo=self.state.repositories[url]
    if repo and repo.error~=tostring(result) then self:checkFailure(url,result) end
    error(result)
end
function Manager:bind(id,url)
    local state=copy(self.state); local r=assert(state.sources[id],"源未安装")
    local repo=assert(state.repositories[url],"订阅不存在")
    assert(repo.public_key and repo.publisher_id,"请先确认签名订阅身份")
    assert(not r.publisher_id or r.publisher_id==repo.publisher_id,"发布身份不符")
    local found=false
    for _,e in ipairs(repo.sources) do if e.id==id then found=true end end
    assert(found,"订阅没有此源")
    r.publisher_id,r.public_key,r.origin=repo.publisher_id,repo.public_key,url; return self:_save(state)
end
function Manager:moveRepository(url,new_url,preview)
    assert(Net.validURL(new_url) and not self.state.repositories[new_url], "新订阅地址无效或已存在")
    local old=assert(self.state.repositories[url], "订阅不存在")
    assert(old.public_key and preview.key==old.public_key and preview.data.publisher_id==old.publisher_id,
        "更换地址必须保持发布者与密钥身份")
    local state=copy(self.state)
    state.repositories[new_url]=copy(old); state.repositories[new_url].url=new_url
    local checker=setmetatable({state=state,now=self.now,_save=function(self,s) self.state=s; return true end},Manager)
    checker:acceptRepository(new_url,preview)
    state=checker.state; state.repositories[url]=nil
    for _,r in pairs(state.sources) do if r.origin==url then r.origin=new_url end end
    return self:_save(state)
end
function Manager:setPolicy(url,key,value)
    local state=copy(self.state)
    if not url then assert(key=="auto_check"); state.auto_check=value==true
    else
        local r=assert(state.repositories[url],"订阅不存在")
        assert(key=="auto_install","未知更新策略")
        assert(not value or r.public_key,"未签名订阅不能自动安装")
        r.auto_install=value==true
    end
    return self:_save(state)
end
function Manager:candidate(url,id)
    local repo=assert(self.state.repositories[url],"订阅不存在")
    return Catalog.candidate(repo,self.state.sources[id],id,self.host_version)
end
function Manager:installFromRepository(url,id,automatic)
    local repo=assert(self.state.repositories[url],"订阅不存在")
    local status=self:candidate(url,id)
    assert(status.code=="update" and status.entry,status.label)
    if automatic then assert(repo.public_key and repo.auto_install,"未授权自动安装") end
    local raw=self.fetch(status.entry.url,Bundle.MAX_BYTES)
    assert(self.state.repositories[url] and self.state.repositories[url].public_key==repo.public_key,"订阅已移除或身份改变")
    local fresh=self:candidate(url,id)
    assert(fresh.code=="update" and fresh.entry and fresh.entry.sha256==status.entry.sha256,
        "更新候选或版本策略已经改变，请重新检查")
    return self:install(raw,url,status.entry)
end
function Manager:updateAll(url,automatic)
    local results={}; local repo=assert(self.state.repositories[url],"订阅不存在"); local seen={}
    for _,entry in ipairs(repo.sources) do
        if not seen[entry.id] and self.state.sources[entry.id] then
            seen[entry.id]=true
            if self:candidate(url,entry.id).code=="update" then
                local ok,err=pcall(self.installFromRepository,self,url,entry.id,automatic)
                results[#results+1]={id=entry.id,ok=ok,error=not ok and tostring(err) or nil}
            end
        end
    end
    return results
end
function Manager:updateCount()
    local seen={}; local count=0
    for url,repo in pairs(self.state.repositories) do
        for _,entry in ipairs(repo.sources) do
            if self.state.sources[entry.id] and not seen[entry.id] and self:candidate(url,entry.id).code=="update" then
                seen[entry.id]=true; count=count+1
            end
        end
    end
    return count
end
function Manager:due(url,force)
    local r=self.state.repositories[url]; if not r then return false end
    if force then return true end
    if not self.state.auto_check then return false end
    local now=self.now()
    if r.last_attempt and now<r.last_attempt then
        local s=copy(self.state); s.repositories[url].last_attempt=now; s.repositories[url].next_check=now+900
        s.repositories[url].last_success=nil; self:_save(s); return false
    end
    return now>=(r.next_check or 0)
end
local instance
function Manager.instance() if not instance then instance=Manager.new() end; return instance end
return Manager
