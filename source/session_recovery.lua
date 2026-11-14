-- Shared account policy; each source still implements its own login protocol.
local R={COOLDOWN=30,TIMEOUT=30}
local reads={getManga=true,getChapters=true,getPages=true,getChapterContent=true,getLatest=true,
 getRecommendations=true,search=true,getCategories=true,getCategoryComics=true,getRankingTypes=true,
 getRankings=true,getSortOptions=true,getFavorites=true,getComments=true,getCommentReplies=true,
 getCommentDetails=true,getUserProfile=true,getRandom=true}
local feature={getFavorites='favorites',getComments='comments',getCommentDetails='comment_details',
 getChapterContent='download',getLatest='latest',getRecommendations='recommendations',search='search'}
function R.wrap(source,ctx,hooks)
 assert(type(source.login)=='function' and type(source.logout)=='function','account protocol missing')
 local login,logout,session=source.login,source.logout,source.getSession
 local epoch,revision,flight,next_attempt=0,0,nil,0
 local disabled
 local function scope()return hooks.scope()end
 local function credentials()
  if disabled then return end
  local ok,value=pcall(ctx.secrets.get_json,'account_credentials')
  local v=ok and value or nil
  if type(v)=='table' and v.scope==scope() and type(v.username)=='string' and #v.username>0
   and #v.username<=256 and type(v.password)=='string' and #v.password>0 and #v.password<=512 then return v end
 end
 local function forget()
  disabled=true
  return ctx.secrets.clear('account_credentials')
 end
 local function error_result(code,text)return false,nil,ctx.error(code,text)end
 local function logged()
  local ok,success,state=pcall(session,source)
  return ok and success and type(state)=='table' and state.logged_in==true
 end
 local function run(fn,args,valid,timeout)
  if not valid()then return error_result('cancelled','登录状态已改变，请重试')end
  local called,ok,value,err=pcall(hooks.run,function()return fn(source,unpack(args,1,args.n))end,valid,timeout)
  if not valid()then return error_result('cancelled','登录状态已改变，请重试')end
  if not called then
   if type(ok)=='table' and ok.code then return false,nil,ok end
   return error_result('invalid_response','源请求未完成，请重试')
  end
  return ok,value,err
 end
 local function manual(fn,args,save)
  epoch=epoch+1;flight=nil;next_attempt=0
  local started,origin=epoch,scope()
  local function valid()return epoch==started and scope()==origin end
  local ok,data,err=run(fn,args,valid)
  if ok and save then
   -- Remove the old pair before storing the new one: never combine accounts.
   local cleared=forget()
   local value={username=args[1],password=args[2],scope=origin}
   if cleared and ctx.secrets.set_json('account_credentials',value)then
    disabled=false
   end
   revision=revision+1
  end
  return ok,data,err
 end
 function source:login(...)return manual(login,{n=select('#',...),...},true)end
 function source:logout(...)
  epoch=epoch+1;flight=nil;next_attempt=0;revision=revision+1
  local cleared=forget()
  local ok,data,err=logout(self,...)
  if not cleared then return error_result('invalid_response','无法清除保存的登录凭据，请重试退出')end
  return ok,data,err
 end
 if source.setCredential then
  local original=source.setCredential
  function source:setCredential(...)
   forget();return manual(original,{n=select('#',...),...},false)
  end
 end
 function source:canRecoverSession()return credentials()~=nil end
 local function recover(started,origin,seen)
  if epoch~=started or scope()~=origin then return error_result('cancelled','登录状态已改变，请重试')end
  if revision~=seen and logged()then return true end
  local now=ctx.clock.now()
  if flight and now<flight.until_at then return error_result('network','正在恢复登录，请稍后重试')end
  if now<next_attempt then return error_result('network','恢复登录暂未成功，请稍后重试')end
  local saved=credentials()
  if not saved then return error_result('auth_expired','登录已过期，请重新登录')end
  local attempt={until_at=now+R.TIMEOUT};flight=attempt;next_attempt=now+R.COOLDOWN
  local function valid()return epoch==started and scope()==origin and flight==attempt and ctx.clock.now()<attempt.until_at end
  local ok,data,err=run(login,{n=2,saved.username,saved.password},valid,R.TIMEOUT)
  if flight==attempt then
   flight=nil;next_attempt=ctx.clock.now()+R.COOLDOWN
   if ok then revision=revision+1
   elseif err and (err.code=='auth_required' or err.code=='auth_expired') then forget()end
  end
  return ok,data,err
 end
 for method in pairs(reads)do
  local original=source[method]
  if type(original)=='function'then
   source[method]=function(self,...)
    local args={n=select('#',...),...}
    local started,origin,seen=epoch,scope(),revision
    local function valid()return epoch==started and scope()==origin end
    local requires=method=='getUserProfile' or (source.capabilities or {}).requires_login
     or (source.access or {})[feature[method]]=='login'
    local recovered=false
    if requires and not logged() and credentials()then
     local ok,_,err=recover(started,origin,seen);if not ok then return false,nil,err end
     recovered=true
    end
    local ok,data,err=run(original,args,valid)
    if not ok and err and err.code=='auth_expired' and not recovered then
     local restored,_,failure=recover(started,origin,seen)
     if not restored then return false,nil,failure end
     local retried,result,retry_error=run(original,args,valid)
     if not retried and retry_error and retry_error.code=="auth_expired" then forget()end
     return retried,result,retry_error
    end
    return ok,data,err
   end
  end
 end
 return source
end
return R
