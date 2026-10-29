-- One text-reading session across chapter switches, shared by all entry pages.
local M={}
function M.open(detail,episode,options)
    if detail._novel_task or detail.opening_reader then return end
    local UI=require("ui/uimanager")
    local Loading=require("ui.common.loading_task")
    local Info=require("ui/widget/infomessage")
    local Document=require("novel.document")
    local Library=require("util.offline_library")
    local base=require("util.cache").BASE_DIR.."/novels"
    local source=detail.source
    local book=tostring(detail.comic._id)
    local episodes=detail.episodes_data and detail.episodes_data.episodes or {episode}
    local state={closed=false,source=source,book=book}
    detail._novel_session=state
    local release=require("util.download_queue").instance():pause("novel reading")
    local function cancel_prefetch()
        local jobs=state.prefetch_jobs or {}
        state.prefetch_jobs={};state.prefetch_job=nil
        for _,job in ipairs(jobs)do
            job.cancelled=true
            if job.timer then UI:unschedule(job.timer)end
            if job.handle then job.handle:cancel()end
            if job.cleanup then job.cleanup();job.cleanup=nil end
        end
    end
    local function finish()
        if state.closed then return end
        state.closed=true
        cancel_prefetch()
        if state.unwatch then state.unwatch();state.unwatch=nil end
        if state.unwatch_prefetch then state.unwatch_prefetch();state.unwatch_prefetch=nil end
        if detail._novel_task then detail._novel_task:cancel() end
        if state.loading then Loading.close(state.loading);state.loading=nil end
        detail._novel_task=nil;detail.opening_reader=false;detail._novel_session=nil
        if detail.revealQuickEntry then detail:revealQuickEntry()end
        release()
        if not detail._closed then detail.resume_episode_order=nil;detail:refresh() end
    end
    local function record(ep,reader)
        local ok,saved=pcall(detail.comic_model.saveHistory,detail.comic_model,book,detail.comic.title,ep.order,detail.source_id,{
            episode_title=ep.title,thumb=detail.comic.thumb,content_type="novel",
            page=reader.document:getPageFromXPointer(reader.document:getXPointer()),pages=reader.document:getPageCount(),
        })
        if not ok or saved==false then
            require("util.logger").warn("Picayomi: 小说历史记录保存失败，保留阅读器与文本定位")
        end
    end
    local start
    local function index(ep)
        for i,item in ipairs(episodes) do if tostring(item.order)==tostring(ep.order) then return i end end
    end
    local function downloaded(ep)
        local entry=Library.entry(detail.source_id,book)
        local ch=entry and entry.chapters and entry.chapters[tostring(ep.order)]
        if ch and ch.document then
            local ok,doc=pcall(Document.load,base.."/downloads",ch.document.key,ch.document.generation)
            if ok and doc then return doc end
        end
        if ch and detail.offline then
            Library.updateChapter(detail.source_id,book,ep.order,
                {state="partial",error="下载内容缺失或损坏，请重新下载此章"},{force=true})
        end
    end
    local function prepare(ep,progress,cleanup)
        local chapter=tostring(ep._id or ep.id)
        local prepared=downloaded(ep) or Document.cached(base.."/reading",source.identifier,book,chapter)
        if prepared then return true,prepared end
        if detail.offline then return false,nil end
        return Document.prepare(require("novel.native").session(source,book,chapter),{
            root=base.."/reading",book=book,chapter=chapter,title=ep.title,
            call={deadline=require("socket").gettime()+60,isCancelled=function()return state.closed or detail._closed end},
            on_cleanup=cleanup,on_progress=progress,
            http=function(request,timeout,call,destination)
                local r,err=require("network.novel_http").image(request,timeout,destination,call and call.deadline)
                return r and {status=r.status_code,body=r.body},err
            end,
        })
    end
    local function prefetch(ep)
        cancel_prefetch()
        if state.closed or detail.offline or detail._closed then return end
        local count=require("novel.prefetch").count()
        local i=index(ep)
        if not i or count==0 or require("util.memory_guard").instance():under_pressure()then return end
        local jobs={}
        for offset=1,count do
            if episodes[i+offset]then jobs[#jobs+1]={episode=episodes[i+offset],status="scheduled"}end
        end
        state.prefetch_jobs=jobs
        local pump
        pump=function()
            if state.closed or detail._closed or state.episode~=ep or detail._novel_task or state.prefetch_jobs~=jobs then return end
            if require("util.memory_guard").instance():under_pressure()then return end
            local job
            for _,pending in ipairs(jobs)do if pending.status=="scheduled"then job=pending;break end end
            if not job then return end
            state.prefetch_job=job;job.status="running";job.timer=nil
            job.handle=Loading.background(nil,function()
                local ok,prepared,err=prepare(job.episode,function(p)
                    job.progress=p
                    if job.waiting and state.loading then state.loading:update(p)end
                end,function(fn)job.cleanup=fn end)
                job.cleanup=nil
                if job.cancelled then return end
                job.status=ok and "ready" or "failed";job.error=err
                if job.on_done then job.on_done(ok,prepared,err)
                elseif ok then
                    -- One chapter at a time; never exceed the configured window.
                    job.timer=function()job.timer=nil;pump()end
                    UI:scheduleIn(.2,job.timer)
                end
            end,{delay=.1,timeout=65,reuse_worker=true,
                on_cancel=function()if job.cleanup then job.cleanup();job.cleanup=nil end end,
                on_error=function()
                    if job.cleanup then job.cleanup();job.cleanup=nil end
                    job.status="failed"
                    if job.on_done then job.on_done(false,nil,{message="下一章加载失败，请重试"})end
                end})
        end
        if jobs[1]then jobs[1].timer=function()jobs[1].timer=nil;pump()end;UI:scheduleIn(.5,jobs[1].timer)end
    end
    state.unwatch_prefetch=require("novel.prefetch").watch(function()
        if not state.closed and not detail._novel_task and state.episode then prefetch(state.episode)end
    end)
    if source.watchSession then state.unwatch=source:watchSession(cancel_prefetch)end
    start=function(ep,from_beginning)
        if state.closed or detail._novel_task then return end
        local job
        for _,candidate in ipairs(state.prefetch_jobs or {})do if candidate.episode==ep then job=candidate;break end end
        local adopting=job and job.status=="running"
        if not adopting then cancel_prefetch()end
        local switching=state.reader~=nil
        local loading=require("novel.loading"):new{chapter_title=ep.title,covers_fullscreen=switching}
        state.loading=loading
        local function close_loading()
            if state.loading~=loading then return end
            state.loading=nil;Loading.close(loading)
            UI:setDirty(nil,"ui",require("device").screen:getSize())
        end
        UI:show(loading,"ui");detail.opening_reader=true
        local cleanup
        local function cancelled()
            close_loading()
            if cleanup then cleanup();cleanup=nil end
            detail._novel_task=nil
            if not state.reader then finish() end
        end
        if adopting then
            job.waiting=true
            loading:update(job.progress)
            job.on_done=function(ok,prepared,err)
                job.waiting=false;job.on_done=nil
                close_loading();detail._novel_task=nil
                if state.closed or detail._closed then finish();return end
                if ok then start(ep,from_beginning)
                else UI:show(Info:new{text=err and err.message or "下一章加载失败，请重试"},"ui")end
            end
            detail._novel_task={cancel=function()
                job.waiting=false;job.on_done=nil;cancel_prefetch();cancelled()
            end}
            loading.dismiss_callback=function()if detail._novel_task then detail._novel_task:cancel()end end
            return
        end
        detail._novel_task=Loading.background(loading,function()
            local ok,prepared,err=prepare(ep,function(p)loading:update(p)end,function(fn)cleanup=fn end)
            cleanup=nil;detail._novel_task=nil
            if state.closed or detail._closed then close_loading();finish();return end
            if not ok then
                close_loading()
                UI:show(Info:new{text=err and err.message or "本章尚未完整下载，暂时无法离线阅读"},"ui")
                if not state.reader then finish() end
                return
            end
            prepared.progress_root=base.."/progress"
            state.switching=switching
            local opened,failure=pcall(require("novel.reader").open,prepared,{
                source=source,from_beginning=from_beginning,is_switching=function()return state.switching end,
                on_closing=function()
                    if detail.revealQuickEntry then detail:revealQuickEntry()end
                end,
                ready=function(reader)
                    state.reader=reader;state.episode=ep;state.switching=false
                    record(ep,reader)
                    prefetch(ep)
                end,
                on_position=function(reader) record(ep,reader) end,
                on_close=function(reader) if state.reader==reader then finish() end end,
                navigation=function(reader)
                    local i=index(ep)
                    return {
                        {text="返回小说详情",callback=function()reader:onClose() end},
                        {text="上一章："..(i and episodes[i-1] and episodes[i-1].title or ""),enabled=i and i>1 or false,callback=function()if i and episodes[i-1] then start(episodes[i-1],true) end end},
                        {text="下一章："..(i and episodes[i+1] and episodes[i+1].title or ""),enabled=i and i<#episodes or false,callback=function()if i and episodes[i+1] then start(episodes[i+1],true) end end},
                        {text="章节目录",callback=function()reader:onClose() end},
                    }
                end,
            })
            if not opened then
                close_loading()
                state.switching=false
                UI:show(Info:new{text="小说阅读器打开失败，请返回详情重试"},"ui")
                local active=require("apps/reader/readerui").instance
                if not active or active~=state.reader then state.reader=nil;finish() end
            end
            -- The host queues opening before switchDocument returns. Close the
            -- cover only after that attempt reaches the reader window stack.
            UI:nextTick(close_loading)
        end,{delay=.1,timeout=65,reuse_worker=true,on_cancel=cancelled,on_error=function()cancelled();Loading.showFailure() end})
    end
    state.close=finish
    start(episode,options and options.from_beginning)
end
return M
