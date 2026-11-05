local U={}
local UI=require('ui/uimanager')
local Core=require('util.plugin_update')
local Style=require('ui.common.action_style')
local function info(text)UI:show(require('ui/widget/infomessage'):new{text=text},'ui')end
local function online()return require('ui/network/manager'):isConnected()end
local function manualCooling(state,now)
 local remaining=(tonumber(state.manual_check_after)or 0)-now
 return remaining>0 and remaining<=30
end
function U.cancel()
 if U.task then local task=U.task;U.task=nil;task:cancel()end
 U.busy=false;Core.cleanup()
 if U.prompt then UI:close(U.prompt,'ui');U.prompt=nil end
 if U.pending_dialog then UI:close(U.pending_dialog,'ui')end
end
local function run(message,fn,done)
 if U.busy then return end
 if not online()then info('当前未联网，请连接网络后重试。');return end
 U.busy=true
 U.task=require('ui.common.loading_task').run{message=message..'\n点击取消',async=true,delay=.1,timeout=90,
  fetch=function()return true,fn()end,
  set_busy=function(v)U.busy=v;if not v then U.task=nil end end,
  on_cancel=Core.cleanup,
  on_done=function(ok,result,err)
   Core.cleanup()
   if not ok then info('更新未完成，当前版本仍可使用。\n'..require('ui.common.error_message').describe(err,nil,'github'));return end
   done(result)
  end}
end
function U.pending()
 if U.pending_dialog then return end
 local dialog,finished
 local function close()
  if finished then return false end
  finished=true;UI:close(dialog,'ui');return true
 end
 local buttons={}
 if require('device'):canRestart() then
  buttons[#buttons+1]={{text='立即重启',callback=function()
   if not close()then return end
   info('正在重启 KOReader…');UI:forceRePaint()
   UI:nextTick(function()UI:broadcastEvent(require('ui/event'):new('Restart'))end)
  end}}
 end
 buttons[#buttons+1]={{text='稍后重启',callback=close}}
 buttons[#buttons+1]={{text='取消本次更新',callback=function()
  if not close()then return end
  local ok,err=pcall(Core.cancelPending)
  if not ok then info('无法取消更新：'..tostring(err))end
 end}}
 dialog=Style.ButtonDialog:new{is_picayomi_page=true,title='更新已准备好\n正常重启 KOReader 后启用，阅读数据保持不变。',buttons=buttons}
 U.pending_dialog=dialog
 local on_close=dialog.onCloseWidget
 dialog.onCloseWidget=function(self)
  finished=true
  if U.pending_dialog==self then U.pending_dialog=nil end
  if on_close then return on_close(self)end
 end
 UI:show(dialog,'ui')
end
function U.offer(release)
 U.prompt=Style.ConfirmBox:new{is_picayomi_page=true,text='发现 PicaYomi '..release.version..'\n下载并准备更新？完成后需正常重启 KOReader。',ok_text='下载更新',
  ok_callback=function()
   U.prompt=nil
   run('正在下载并校验更新…',function()return Core.prepare(release)end,U.pending)
  end,cancel_callback=function()U.prompt=nil end}
 local close=U.prompt.onCloseWidget
 U.prompt.onCloseWidget=function(self)if U.prompt==self then U.prompt=nil end;if close then return close(self)end end
 UI:show(U.prompt,'ui')
end
function U.rollback()
 UI:show(Style.ConfirmBox:new{is_picayomi_page=true,text='恢复上一版插件？正常重启 KOReader 后生效，阅读数据保持不变。',
  ok_text='准备恢复',ok_callback=function()
   local ok,err=pcall(Core.rollback)
   if ok then U.pending()else info('无法准备恢复：'..tostring(err))end
  end},'ui')
end
function U.check()
 if U.busy or U.prompt then return end
 local ok,state=pcall(Core.state)
 if not ok then info('更新状态异常，请重新安装插件以恢复更新功能。当前阅读不受影响。');return end
 if state.pending then U.pending();return end
 if not online()then info('当前未联网，请连接网络后重试。');return end
 local now=os.time()
 if manualCooling(state,now)then info('操作较频繁，请稍后重试。');return end
 -- Persist before admission: cancellation and controller reload cannot spam requests.
 -- A backward clock jump must not turn a short cooldown into a long lockout.
 state.manual_check_after=now+30
 if not pcall(Core.save,state)then info('无法保存更新状态，请稍后重试。');return end
 run('正在检查插件更新…',Core.check,function(result)
  if result.latest then info('已是最新版本（'..result.version..'）')else U.offer(result)end
 end)
end
local function idle()
 local Home=package.loaded['ui.home'];local top=UI._window_stack and UI._window_stack[#UI._window_stack]
 local Queue=package.loaded['util.download_queue']
 return Home and top and top.widget==Home.findShownMenu() and (not Queue or not Queue.instance():is_active())
end
function U.schedule()
 if U.busy or U.prompt or not Core.autoEnabled()then return end
 local ok,state=pcall(Core.state)
 local now=os.time()
 if not ok or state.pending or (tonumber(state.next_check)or 0)>now or manualCooling(state,now)or not idle()or not online()then return end
 U.busy=true
 -- Persist admission before networking: cancellation/crash must not loop checks.
 state.next_check=now+6*3600
 if not pcall(Core.save,state)then U.busy=false;return end
 U.task=require('ui.common.loading_task').background(nil,function()
  local result=Core.check();U.busy=false;U.task=nil
  if not result.latest and idle()then U.offer(result)end
 end,{timeout=30,is_cancelled=function()return not idle()end,
  on_cancel=function()U.busy=false;U.task=nil end,
  on_error=function()U.busy=false;U.task=nil end})
end
return U
