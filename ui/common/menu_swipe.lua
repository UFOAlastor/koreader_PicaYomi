-- ui/common/menu_swipe.lua
-- 全屏菜单 (Menu) 的左右滑动
--
-- 规则与漫画列表页 / 详情页一致 (见 ui/common/visual_comic_list.lua 的 onSwipe):
--   **只有边缘往中间划 = 返回** (左边缘右滑 / 右边缘左滑, 见 ui/common/swipe_rules.lua);
--   中间左滑 = 下一屏, 中间右滑 = 上一屏; 到边界就停住, **中间滑动永不退出**。
--
-- 为什么不能直接用 Menu 自带的 onSwipe (menu.lua:1518):
--   1) 它是"翻菜单页"的, 而且 **会循环**: onPrevPage 在第一页返回最后一页
--      (menu.lua:1429-1431 的 `self.page > 1 and self.page - 1 or self.page_num`)。
--      真机反馈: "下载页面第一页左滑, 怎么不是返回, 而是到了最后一页" ——
--      在只有一页的菜单上看不出来, 章节选择页/章节列表这种几十行的菜单就会
--      "一滑跳到末尾", 而且再也退不出去 (只能去找「返回」)。
--   2) 单屏菜单翻不动, 用户看到的是"左右滑完全没反应"。
-- 所以这里统一接管: 有下一页就翻页, 到边界就停住 —— 永不循环, 也不退出。
--
-- 竖划不关闭页面; 顶部下拉由 host_menu 接入宿主菜单。斜划仍可全刷。

local Device = require("device")
local SwipeRules = require("ui.common.swipe_rules")

local M = {}

--- 给一个菜单装上左右滑动
-- @param menu    Menu 实例 (必须已经构造完: ges_events 与 page_num 都在 Menu:init 里就绪)
-- @param on_back function 边缘滑动时执行的"返回"动作 (与页面里的「返回」项同一个函数)
-- @return menu
function M.attach(menu, on_back)
    if not menu or not Device:isTouchDevice() then return menu end
    require("ui.common.host_menu").attach(menu)

    -- Custom full-screen InputContainers do not inherit Menu's gesture range.
    menu.ges_events=menu.ges_events or {}
    menu.ges_events.Swipe=menu.ges_events.Swipe or {
        require("ui/gesturerange"):new{ges="swipe",range=menu.dimen or require("device").screen:getSize()},
    }
    local native = menu.onSwipe
    menu.onSwipe = function(self, arg, ges)
        local handled=SwipeRules.dispatchPageSwipe(ges,{
            back=on_back,
            next=function()if (self.page or 1)<(self.page_num or 1) then self:onNextPage()end end,
            prev=function()if (self.page or 1)>1 then self:onPrevPage()end end,
        })
        if handled then return true end
        local direction=ges and ges.direction

        -- Native Menu treats south as Close, which exits the plugin on Home.
        -- A top pull is intercepted before this handler; body swipes stay here.
        if not self.is_popout and (direction == "south" or direction == "north") then return true end
        if native then return native(self, arg, ges) end
        return true
    end

    -- 慢速边缘拖动也算返回: KOReader 的 swipe 有 900ms 上限, 划得慢一点就变成
    -- pan_release, onSwipe 根本不会被调用 (真机反馈"偶尔有用偶尔没用")。
    SwipeRules.installSlowDragBack(menu, function()
        if on_back then on_back() end
    end)
    return menu
end

return M
