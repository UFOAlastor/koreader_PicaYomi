-- Independent per-source requests, one batch deadline, durable partial results.
-- UI and HTTP lifecycle are supplied by the existing cooperative task system.
local M={REQUEST_TIMEOUT=15,BATCH_TIMEOUT=45,PAGE_DELAY=5.1,CONCURRENCY=2}
local Caps=require("source.capabilities")
local last_request=setmetatable({},{__mode="k"})
function M.sources(registry,current)
    local out={};local kind=current and current.content_type or "comic"
    for _,entry in ipairs(registry:list())do
        local source=registry:get(entry.identifier)
        if source and not source._offline and (source.content_type or "comic")==kind
            and ((source.capabilities or {}).search or source.hasCapability and source:hasCapability("search"))then
            out[#out+1]=source
        end
    end
    return out
end
function M.new(sources,keyword,previous)
    local self={keyword=keyword,states={},items={},seen={}}
    for _,source in ipairs(sources)do
        local old=previous and previous.states[source.identifier]
        local same=old and old.source==source
        local state={source=source,status=same and old.status=="complete"and "complete"or "queued",
            page=same and old.page or 1,count=same and old.count or 0,pages_seen={}}
        if same then for key,value in pairs(old.pages_seen or {})do state.pages_seen[key]=value end end
        self.states[source.identifier]=state
    end
    if previous then
        for _,item in ipairs(previous.items)do
            self.items[#self.items+1]=item;self.seen[item.source_id.."\0"..tostring(item._id)]=true
        end
    end
    self.sources=sources
    return setmetatable(self,{__index=M})
end
function M:summary()
    local finished,complete,failed=0,0,0
    for _,source in ipairs(self.sources)do
        local state=self.states[source.identifier]
        if state.status=="complete"then complete=complete+1;finished=finished+1
        elseif state.status=="failed"then failed=failed+1;finished=finished+1 end
    end
    return {finished=finished,total=#self.sources,complete=complete,failed=failed,count=#self.items}
end
function M:wake()
    local signal=self.signal;self.signal=nil
    if signal and signal._on_done then signal._on_done()end
end
function M:await()
    if not self.active then return end
    local signal={};self.signal=signal
    coroutine.yield({join={signal},ready=function()return not self.active end})
end
function M:cancel()
    self.active=false
    if self._stop then self._stop();self._stop=nil end
    self:wake()
end
function M:start(opts)
    opts=opts or {}
    local UI=opts.ui or require("ui/uimanager")
    local Async=opts.async or require("network.async_task")
    local clock=opts.clock or require("socket").gettime
    self.active=true;self.tasks={};self.timers={};self.running=0
    local deadline=clock()+(opts.batch_timeout or M.BATCH_TIMEOUT)
    local pump,finish
    local function schedule(delay,fn)
        self.timers[fn]=true
        UI:scheduleIn(delay,fn)
    end
    local function progress()if opts.on_progress then opts.on_progress(self:summary())end end
    local function stop_tasks()
        for fn in pairs(self.timers)do UI:unschedule(fn)end;self.timers={}
        for _,state in pairs(self.states)do
            local task=state.task;state.task=nil
            if task then task.nonblocking=true;task:cancel()end
        end
    end
    self._stop=stop_tasks
    finish=function(timeout)
        if not self.active then return end
        self.active=false
        if timeout then for _,state in pairs(self.states)do
            if state.status~="complete"and state.status~="failed"then state.status="failed";state.error="搜索超时，已保留取得的结果"end
        end end
        stop_tasks();self._stop=nil;progress();self:wake()
        if opts.on_done then opts.on_done(self)end
    end
    local function failed(state,err)
        if not self.active or state.status~="running"then return end
        state.task=nil;state.status="failed"
        state.error=require("ui.common.error_message").describe(err)
        self.running=self.running-1;progress();schedule(0,pump)
    end
    local function receive(state,data)
        assert(type(data)=="table"and type(data.comics)=="table","搜索结果格式错误")
        local added=0
        for _,raw in ipairs(data.comics)do
            assert(type(raw)=="table"and raw._id~=nil and type(raw.title)=="string","搜索条目格式错误")
            state.count=state.count+1
            local key=state.source.identifier.."\0"..tostring(raw._id)
            if not self.seen[key]then
                local item={};for k,v in pairs(raw)do item[k]=v end
                item.source_id=state.source.identifier;item.source_text=state.source.name or item.source_id
                item.content_type=state.source.content_type or "comic";item.search_rank=state.count
                self.items[#self.items+1]=item;self.seen[key]=true;added=added+1
            end
        end
        local more=data.has_more
        if more==nil and tonumber(data.pages)then more=state.page<tonumber(data.pages)end
        if more==nil then
            if #data.comics==0 then more=false else error("无法确认搜索是否完整，已保留取得的结果")end
        end
        -- Detect repeated pages within this attempt, independently of retained retry items.
        local ids={};for _,item in ipairs(data.comics)do ids[#ids+1]=tostring(item._id)end
        table.sort(ids);local signature=table.concat(ids,"\0")
        state.pages_seen=state.pages_seen or {}
        if more and (#ids==0 or state.pages_seen[signature])then error("搜索续页重复，已保留取得的结果")end
        state.pages_seen[signature]=true
        return more
    end
    pump=function()
        if not self.active then return end
        if clock()>=deadline then finish(true);return end
        for _,source in ipairs(self.sources)do
            if self.running>=(opts.concurrency or M.CONCURRENCY)then break end
            local state=self.states[source.identifier]
            if state.status=="queued"and last_request[source] then
                local remaining=(opts.page_delay or M.PAGE_DELAY)-(clock()-last_request[source])
                if remaining>0 then
                    state.status="waiting"
                    schedule(remaining,function()
                        if self.active then state.status="queued";pump()end
                    end)
                end
            end
            if state.status=="queued"then
                state.status="running";self.running=self.running+1
                local task=Async.run(function()
                    if Caps.needsLogin(source,"search")then error("请先登录"..(source.name or source.identifier).."账号")end
                    if opts.admit and not opts.admit()then error("可用内存不足，已保留取得的结果")end
                    last_request[source]=clock()
                    local ok,data,err=source:search(self.keyword,state.page)
                    if not self.active or state.status~="running"then return end
                    if clock()>=deadline then finish(true);return end
                    if not ok then error(require("ui.common.error_message").describe(err))end
                    local more=receive(state,data)
                    state.task=nil;self.running=self.running-1
                    if more then
                        state.page=state.page+1;state.status="waiting"
                        local ready=function()
                            if not self.active then return end
                            state.status="queued";pump()
                        end
                        schedule(opts.page_delay or M.PAGE_DELAY,ready)
                    else state.status="complete"end
                    progress();schedule(0,pump)
                end,{timeout=math.min(opts.request_timeout or M.REQUEST_TIMEOUT,deadline-clock()),
                    on_error=function(err)failed(state,err)end,
                    on_cancel=function()failed(state,"搜索已中断，请重试")end})
                task.nonblocking=true
                if state.status=="running"then state.task=task end
            end
        end
        if self:summary().finished==#self.sources then finish(false)end
    end
    schedule(opts.batch_timeout or M.BATCH_TIMEOUT,function()finish(true)end)
    progress();schedule(0,pump)
    return self
end
return M
