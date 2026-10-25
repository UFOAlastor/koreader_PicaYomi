-- Open the live KOReader menu above a plugin page. Only this menu instance and
-- this page's gesture handler are adapted; no global input/host hooks change.
local Device = require("device")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local M = {}

local function shown(widget)
    return widget and require("util.widget_sweep").isInStack(widget)
end

local function closePages(state)
    for index = #state.pages, 1, -1 do
        local widget = state.pages[index]
        if shown(widget) then
            widget.sweeping = true
            UIManager:close(widget, "ui")
        end
    end
end

local function closeMenu(state)
    if shown(state.container) then state.menu:closeMenu() end
end

function M.backToBooks(state)
    state = state or M.active
    if not state then return end
    closeMenu(state)
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI.instance and shown(ReaderUI.instance) then ReaderUI.instance:onClose() end
    -- A reader may have closed FileManager when the book opened. Keep a live
    -- base before removing plugin pages, so the window stack is never empty.
    local fm = require("util.widget_sweep").ensureBase()
    closePages(state)
    UIManager:setDirty(fm, "full")
end

local function navigated(state, before, width, height)
    if Screen:getWidth() ~= width or Screen:getHeight() ~= height or not shown(state.host) then return true end
    local reader = require("apps/reader/readerui").instance
    if reader and reader ~= state.host and not before[reader] then return true end
    for _, entry in ipairs(UIManager._window_stack) do
        local widget = entry.widget
        if not before[widget] and widget ~= state.container and not widget.is_picayomi_page then
            local size = widget.getSize and widget:getSize()
            if widget.covers_fullscreen or widget.is_popout == false and size and size.h >= Screen:getHeight() then
                return true
            end
        end
    end
    return false
end

local function wrapSelection(state, method)
    local native = state.menu[method]
    if not native then return end
    state.menu[method] = function(menu, ...)
        local before = {}
        for _, entry in ipairs(UIManager._window_stack) do before[entry.widget] = true end
        local width, height = Screen:getWidth(), Screen:getHeight()
        local item = ...
        local tab = menu.tab_item_table[menu.cur_tab]
        -- A native Tools action can open its plugin asynchronously, after the
        -- menu has closed. Leave our pages before that explicit switch, while
        -- preserving checkboxes and nested configuration menus.
        if method == "onMenuSelect" and tab and tab.id == "tools" and item
            and (item.callback or item.callback_func) and item.checked == nil and not item.checked_func
            and not item.keep_menu_open and not item.checkmark_callback
            and not item.sub_item_table and not item.sub_item_table_func then
            closePages(state)
        end
        local result = native(menu, ...)
        -- Settings toggles and small dialogs keep the plugin underneath. A new
        -- full-screen book/history/plugin view must not reveal old plugin pages
        -- on its next Back, and must not be swept away with those old pages.
        if navigated(state, before, width, height) then closePages(state) end
        return result
    end
end

function M.open(owner)
    if not (owner and owner.is_picayomi_page and shown(owner)) then return false end
    if M.active and shown(M.active.container) then return true end
    local Sweep = require("util.widget_sweep")
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    local host = reader and shown(reader) and reader or Sweep.ensureBase()
    if not (host and host.menu and host.menu.onShowMenu) then return false end
    local controller = host.menu
    if controller.menu_container and shown(controller.menu_container) then return true end
    local state = { host = host, pages = Sweep.list() }
    -- Construct without showing, so no half-built menu is ever painted.
    controller:onShowMenu(nil, true)
    state.container = controller.menu_container
    state.menu = state.container and state.container[1]
    if not (state.menu and state.menu.tab_item_table) then return false end

    local tabs = {}
    for index, original in ipairs(state.menu.tab_item_table) do
        local tab = {}
        for key, value in pairs(original) do tab[key] = value end
        tabs[index] = tab
        if original.id == "tools" then
            -- Reuse the existing plugin entry for this overlay only. Ordinary
            -- KOReader menus retain their Picayomi launcher; the Main tab gets
            -- no extra plugin navigation entry.
            for row, item in ipairs(tab) do
                if item.id == "picayomi" or item.id == "picayomi_return" then
                    local exit = {}
                    for key, value in pairs(item) do exit[key] = value end
                    exit.text = require("gettext")("退出 Picayomi")
                    exit.callback = function() M.backToBooks(state) end
                    tab[row] = exit
                    break
                end
            end
        end
    end
    state.menu.tab_item_table = tabs
    state.menu:switchMenuTab(state.menu.last_index)
    state.menu.onHome = function() M.backToBooks(state); return true end
    wrapSelection(state, "onMenuSelect")
    wrapSelection(state, "onMenuHold")
    wrapSelection(state, "switchMenuTab")
    local on_close = state.container.onCloseWidget
    state.container.onCloseWidget = function(widget)
        if M.active == state then M.active = nil end
        if on_close then return on_close(widget) end
    end
    M.active = state
    UIManager:show(state.container, "ui")
    return true
end

local function topPull(gesture)
    local start = gesture.start_pos or gesture.pos
    if not (start and start.x and start.y and start.x >= 0 and start.x <= Screen:getWidth()
        and start.y >= 0 and start.y <= math.min(Screen:scaleBySize(64), Screen:getHeight() * 0.12)) then
        return false
    end
    local finish = gesture.end_pos or gesture.start_pos and gesture.pos
    if finish then
        local dx, dy = finish.x - start.x, finish.y - start.y
        return dy >= Screen:scaleBySize(24) and dy > math.abs(dx)
    end
    return gesture.direction == "south"
end

function M.attach(widget)
    if not (widget and widget.is_picayomi_page and not widget.is_popout and Device:isTouchDevice())
        or widget._picayomi_host_menu_attached then return end
    widget._picayomi_host_menu_attached = true
    local function handle(gesture)
        -- Do not act through a confirmation/input dialog or another native UI.
        local top = UIManager._window_stack[#UIManager._window_stack]
        if top and top.widget == widget then
            if gesture.ges == "swipe" and topPull(gesture) then
                M.open(widget)
                return true
            elseif gesture.ges == "pan" and gesture.start_pos then
                widget._picayomi_top_pull = topPull(gesture)
                if widget._picayomi_top_pull then return true end
            elseif gesture.ges == "pan_release" then
                local pull = widget._picayomi_top_pull
                widget._picayomi_top_pull = nil
                if pull then M.open(widget); return true end
            end
        end
        return false
    end
    -- Use ordinary page-owned touch zones, so KOReader's touch-input lock and
    -- resume filtering remain in charge of input dispatch.
    widget:registerTouchZones({
        { id = "picayomi_host_menu_pull", ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1,
                ratio_h = math.min(Screen:scaleBySize(64) / Screen:getHeight(), 0.12) }, handler = handle },
        { id = "picayomi_host_menu_drag", ges = "pan",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }, handler = handle },
        { id = "picayomi_host_menu_release", ges = "pan_release",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }, handler = handle },
    })
end

return M
