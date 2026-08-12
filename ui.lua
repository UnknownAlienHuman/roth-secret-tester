-- RothSecretTester 2 UI
-- Spec:
--   - Open UI => start a session
--   - Select an entry (module / suite / pack) => run immediately
--   - No "Run/Load/Start" button clutter

local Addon = _G.RothSecretTesterCore
if not Addon then return end

local UI = {}
Addon.UI = UI

local CreateFrame = CreateFrame
local UIParent = UIParent
local type = type
local tostring = tostring
local pairs = pairs
local ipairs = ipairs
local strlower = string.lower
local strfind = string.find
local table_sort = table.sort

-- ---------------------------
-- Helpers
-- ---------------------------
local function createLabel(parent, template)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    fs:SetJustifyH("LEFT")
    return fs
end

local function createButton(parent, text, w, h)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h)
    b:SetText(text)
    return b
end

local function createDropdown(parent, label, width, getItems, onSelect)
    local dd = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
    dd:SetSize(width + 40, 32)
    dd._label = createLabel(parent, "GameFontNormalSmall")
    dd._label:SetText(label)
    dd._selectedValue = nil
    dd._selectedText = nil
    dd._getItems = getItems
    dd._onSelect = onSelect

    UIDropDownMenu_SetWidth(dd, width)
    UIDropDownMenu_SetText(dd, label)

    UIDropDownMenu_Initialize(dd, function(self, level)
        if level ~= 1 then return end
        local items = {}
        if type(dd._getItems) == "function" then
            items = dd._getItems() or {}
        end
        for i = 1, #items do
            local it = items[i]
            local info = UIDropDownMenu_CreateInfo()
            info.text = it.text
            info.value = it.value
            info.func = function()
                dd._selectedValue = it.value
                dd._selectedText = it.text
                UIDropDownMenu_SetText(dd, it.text)
                if type(dd._onSelect) == "function" then
                    dd._onSelect(it.value, it.text)
                end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    function dd:SetSelectedValue(value, text)
        dd._selectedValue = value
        dd._selectedText = text or value
        UIDropDownMenu_SetText(dd, dd._selectedText or label)
    end

    return dd
end

local function normalize(s)
    if type(s) ~= "string" then return "" end
    return strlower(s)
end

-- ---------------------------
-- Entry model
-- ---------------------------
local function buildEntries()
    local entries = {}

    -- Modules only
    for id, mod in pairs(Addon.modules or {}) do
        entries[#entries + 1] = {
            key = "module:" .. tostring(id),
            kind = "module",
            id = tostring(id),
            name = tostring(mod.name or id),
            desc = tostring(mod.desc or ""),
            group = 1,
        }
    end

    table_sort(entries, function(a, b)
        return a.name < b.name
    end)

    return entries
end

local function filterEntries(all, kindFilter, search)
    kindFilter = kindFilter or "all"
    search = normalize(search)
    local out = {}
    for i = 1, #all do
        local e = all[i]
        if kindFilter == "all" or e.kind == kindFilter then
            if search == "" then
                out[#out + 1] = e
            else
                local hay = normalize(e.name .. " " .. (e.desc or "") .. " " .. e.key)
                if strfind(hay, search, 1, true) then
                    out[#out + 1] = e
                end
            end
        end
    end
    return out
end

-- ---------------------------
-- UI: list + run
-- ---------------------------
function UI:Init()
    if self.frame then return end

    local f = CreateFrame("Frame", "RothSecretTester2Frame", UIParent, "BackdropTemplate")
    f:SetSize(980, 560)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 }
    })
    f:SetBackdropColor(0, 0, 0, 0.90)
    self.frame = f

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("Roth Secret Tester 2")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function() f:Hide() end)

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    status:SetPoint("TOPLEFT", 16, -40)
    status:SetText("Status: ...")
    self.status = status

    -- Left pane (entries)
    local left = CreateFrame("Frame", nil, f)
    left:SetPoint("TOPLEFT", 14, -64)
    left:SetSize(330, 480)

    local db = Addon:GetDB()
    db.settings = db.settings or {}
    db.settings.ui = db.settings.ui or {}
    local uiDB = db.settings.ui

    -- Search box
    -- Place search on its own row below the filter to avoid overlap across UI scales.
    local searchBox = CreateFrame("EditBox", nil, left, "InputBoxTemplate")
    searchBox:SetAutoFocus(false)
    -- InputBoxTemplate can render taller on some UI scales; force a compact height and texture sizing.
    searchBox:SetSize(300, 18)
    searchBox:SetPoint("TOPLEFT", left, "TOPLEFT", 10, -14)
    searchBox:SetTextInsets(6, 6, 2, 2)
    if searchBox.Left and searchBox.Middle and searchBox.Right then
        searchBox.Left:SetHeight(18)
        searchBox.Middle:SetHeight(18)
        searchBox.Right:SetHeight(18)
    end
    searchBox:SetText(uiDB.search or "")
    searchBox:SetScript("OnTextChanged", function(self)
        uiDB.search = self:GetText() or ""
        UI:Rebuild()
    end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    self.searchBox = searchBox

    local searchLabel = createLabel(left, "GameFontNormalSmall")
    searchLabel:SetPoint("BOTTOMLEFT", searchBox, "TOPLEFT", 0, 2)
    searchLabel:SetText("Search")

    -- Scroll list
    local listFrame = CreateFrame("Frame", nil, left, "BackdropTemplate")
    -- Modules-only UI: search row only.
    listFrame:SetPoint("TOPLEFT", 10, -56)
    listFrame:SetSize(310, 360)
    listFrame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    listFrame:SetBackdropColor(0, 0, 0, 0.5)

    local scroll = CreateFrame("ScrollFrame", "RST2EntryScroll", listFrame, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -2)
    scroll:SetPoint("BOTTOMRIGHT", -28, 2)
    self.scroll = scroll

    local ROW_H = 22
    local ROWS = 16
    self.rowButtons = {}

    for i = 1, ROWS do
        local b = CreateFrame("Button", nil, listFrame, "BackdropTemplate")
        b:SetHeight(ROW_H)
        b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * ROW_H)
        b:SetPoint("TOPRIGHT", -32, -6 - (i - 1) * ROW_H)
        b:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
        })
        b:SetBackdropColor(0, 0, 0, 0.0)

        local t = createLabel(b, "GameFontHighlightSmall")
        t:SetPoint("LEFT", 6, 0)
        t:SetText("")
        b.text = t

        b:SetScript("OnEnter", function(self)
            self:SetBackdropColor(1, 1, 1, 0.06)
            if self.entry and self.entry.desc and self.entry.desc ~= "" then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(self.entry.name, 1, 1, 1)
                GameTooltip:AddLine(self.entry.desc, 0.9, 0.9, 0.9, true)
                GameTooltip:AddLine(self.entry.key, 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end
        end)
        b:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
            local db = Addon:GetDB()
            local uiDB = db.settings and db.settings.ui or {}
            if self.entry and uiDB.selectedKey == self.entry.key then
                self:SetBackdropColor(1, 1, 1, 0.10)
            else
                self:SetBackdropColor(0, 0, 0, 0.0)
            end
        end)

        b:SetScript("OnClick", function(self)
            local e = self.entry
            if not e then return end
            uiDB.selectedKey = e.key

            Addon:StartModule(e.id)

            UI:RefreshStatus()
            UI:UpdateList()
        end)

        self.rowButtons[i] = b
    end

    scroll:SetScript("OnVerticalScroll", function(_, offset)
        FauxScrollFrame_OnVerticalScroll(scroll, offset, ROW_H, function() UI:UpdateList() end)
    end)

    -- Buttons (minimal)
    local bExport = createButton(left, "Export", 90, 22)
    bExport:SetPoint("BOTTOMLEFT", 10, 0)
    bExport:SetScript("OnClick", function()
        UI:OpenExport()
    end)

    local bReset = createButton(left, "Reset DB", 90, 22)
    bReset:SetPoint("BOTTOMLEFT", 110, 0)
    bReset:SetScript("OnClick", function()
        StaticPopup_Show("RST_RESET_DB")
    end)

    -- Right pane: log output
    local right = CreateFrame("Frame", nil, f)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 10, 0)
    right:SetPoint("BOTTOMRIGHT", -16, 16)

    local msg = CreateFrame("ScrollingMessageFrame", nil, right, "BackdropTemplate")
    msg:SetPoint("TOPLEFT", 0, 0)
    msg:SetPoint("BOTTOMRIGHT", 0, 0)
    msg:SetFontObject("GameFontHighlightSmall")
    msg:SetJustifyH("LEFT")
    msg:SetFading(false)
    msg:SetMaxLines(8000)
    msg:EnableMouseWheel(true)
    msg:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then self:ScrollUp() else self:ScrollDown() end
    end)
    msg:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    msg:SetBackdropColor(0, 0, 0, 0.6)
    self.msg = msg

    -- Reset popup (kept, but now accessed via one button)
    if not StaticPopupDialogs["RST_RESET_DB"] then
        StaticPopupDialogs["RST_RESET_DB"] = {
            text = "Reset RST data? This wipes SavedVariables (sessions + schema) and reloads UI.",
            button1 = "Reset",
            button2 = "Cancel",
            hideOnEscape = true,
            whileDead = true,
            preferredIndex = 3,
            OnAccept = function()
                Addon:ResetAll()
                ReloadUI()
            end,
        }
    end

    f:SetScript("OnShow", function()
        Addon:AutoLoadOnUIOpen()
        Addon:NewSession("ui")
        UI:Rebuild()
        UI:RefreshStatus()
    end)

    self:RefreshStatus()
    self:Rebuild()
end

function UI:Rebuild()
    local db = Addon:GetDB()
    db.settings = db.settings or {}
    db.settings.ui = db.settings.ui or {}
    local uiDB = db.settings.ui

    self.entriesAll = buildEntries()
    self.entries = filterEntries(self.entriesAll, "all", uiDB.search or "")
    FauxScrollFrame_Update(self.scroll, #self.entries, #self.rowButtons, 22)
    self:UpdateList()
end

function UI:UpdateList()
    if not self.entries then return end
    local db = Addon:GetDB()
    local uiDB = db.settings and db.settings.ui or {}

    local offset = FauxScrollFrame_GetOffset(self.scroll) or 0
    for i = 1, #self.rowButtons do
        local idx = offset + i
        local b = self.rowButtons[i]
        local e = self.entries[idx]
        b.entry = e
        if e then
            b:Show()
            local prefix = "[M] "
            b.text:SetText(prefix .. e.name)
            if uiDB.selectedKey == e.key then
                b:SetBackdropColor(1, 1, 1, 0.10)
            else
                b:SetBackdropColor(0, 0, 0, 0.0)
            end
        else
            b.entry = nil
            b:Hide()
        end
    end
end

function UI:AppendLine(line)
    if not self.msg then return end
    self.msg:AddMessage(tostring(line))
end

function UI:RefreshStatus()
    if not self.status then return end
    local db = Addon:GetDB()
    local sc = (db and db.sessions and #db.sessions) or 0
    local schemaRows = 0
    if Addon.Schema and Addon.Schema.CountSummaryRows then
        schemaRows = Addon.Schema:CountSummaryRows()
    end

    local sess = Addon.activeSession
    local sid = sess and sess.id or 0
    local slabel = sess and sess.label or "-"
    local activeMod = Addon.activeModuleId or "-"

    self.status:SetText(("DB: sessions=%d schema_rows=%d  active_session=#%d (%s)  active_module=%s"):format(sc, schemaRows, sid, slabel, activeMod))
end

function UI:Toggle(show)
    if not self.frame then self:Init() end
    if show == nil then
        show = not self.frame:IsShown()
    end
    if show then
        self.frame:Show()
    else
        self.frame:Hide()
    end
end

-- ---------------------------
-- Export window (copy text)
-- ---------------------------

-- Modes:
--   log   : operational UI log (same lines as main window)
--   report: filtered schema report (human-readable)
--   full  : report + audit (no raw dump)
--   entity: machine-friendly Lua summary
--   raw   : raw schema dump (heavy)

local function _export_cache_key(mode)
    local db = Addon:GetDB()
    local dirty = (db and db.meta and tonumber(db.meta.dirtyWrites)) or 0
    local schemaUpd = (db and db.schema and db.schema.meta and tonumber(db.schema.meta.updated)) or 0
    local sess = Addon.activeSession
    local nLines = (sess and sess.lines and #sess.lines) or 0
    if mode == 'log' then
        return tostring(dirty) .. ':' .. tostring(schemaUpd) .. ':L' .. tostring(nLines)
    end
    return tostring(dirty) .. ':' .. tostring(schemaUpd)
end

local function buildExportText(mode)
    mode = tostring(mode or 'log')

    -- Fast path: session log export (default).
    if mode == 'log' then
        local out = {}
        out[#out + 1] = ('RothSecretTester Log v%s'):format(tostring(Addon.version or 'unknown'))
        local sess = Addon.activeSession
        if sess then
            out[#out + 1] = ('Session #%d  label=%s  created=%s'):format(sess.id or 0, tostring(sess.label or ''), tostring(sess.createdAt or ''))
        end
        out[#out + 1] = ''
        out[#out + 1] = '[LOG]'

        local lines = sess and sess.lines
        if type(lines) == 'table' and #lines > 0 then
            for i = 1, #lines do
                out[#out + 1] = tostring(lines[i])
            end
        elseif type(Addon._preLines) == 'table' and #Addon._preLines > 0 then
            for i = 1, #Addon._preLines do
                out[#out + 1] = tostring(Addon._preLines[i])
            end
        else
            out[#out + 1] = '(no log lines)'
        end

        return table.concat(out, '\n')
    end

    local out = {}

    -- Header
    local db = Addon:GetDB()
    local sc = (db and db.sessions and #db.sessions) or 0
    local schemaRows = (Addon.Schema and Addon.Schema.CountSummaryRows and Addon.Schema:CountSummaryRows()) or 0
    out[#out + 1] = ('RothSecretTester Core v%s'):format(tostring(Addon.version or 'unknown'))
    out[#out + 1] = ('DB: sessions=%d schema_rows=%d (kept until manual reset)'):format(sc, schemaRows)
    local dirtyWrites = (db and db.meta and tonumber(db.meta.dirtyWrites)) or 0
    local lastDirtyAt = (db and db.meta and db.meta.lastDirtyAt) or '-'
    out[#out + 1] = ('DB writes: dirty=%d last_dirty=%s (SavedVariables persist after /reload/logout)'):format(dirtyWrites, tostring(lastDirtyAt))

    -- Session
    local sess = Addon.activeSession
    if sess then
        out[#out + 1] = ('Session #%d  label=%s  created=%s'):format(sess.id or 0, tostring(sess.label or ''), tostring(sess.createdAt or ''))
        if sess.context then
            out[#out + 1] = ('Context: combat=%s instance=%s(%s) zone=%s subzone=%s player=%s'):format(
                tostring(sess.context.combat and 'yes' or 'no'),
                tostring(sess.context.inInstance and 'yes' or 'no'),
                tostring(sess.context.instanceType2 or sess.context.instanceType or 'none'),
                tostring(sess.context.zone or ''),
                tostring(sess.context.subzone or ''),
                tostring(sess.context.player or '')
            )
        end

        local q = sess.quality
        if q then
            local sev = q.sev or {}
            local cause = q.cause or {}
            out[#out + 1] = ('Data quality: %s%s  (CRITICAL=%d ERROR=%d WARN=%d tested_api=%d addon_bug=%d unknown=%d)'):format(
                q.dirty and 'DIRTY' or 'CLEAN',
                q.dirtyCritical and ' (CRITICAL)' or '',
                tonumber(sev.CRITICAL) or 0,
                tonumber(sev.ERROR) or 0,
                tonumber(sev.WARN) or 0,
                tonumber(cause.tested_api) or 0,
                tonumber(cause.addon_bug) or 0,
                tonumber(cause.unknown) or 0
            )
        else
            out[#out + 1] = 'Data quality: CLEAN'
        end
    end

    out[#out + 1] = ''
    out[#out + 1] = '[ERRORS]'
    if sess and sess.errors and #sess.errors > 0 then
        for i = 1, #sess.errors do
            local e = sess.errors[i]
            if type(e) == 'table' then
                local at = tostring(e.at or '')
                local origin = tostring(e.origin or '?')
                local phase = tostring(e.phase or '?')
                local cause = tostring(e.cause or '?')
                local sev = tostring(e.severity or '?')
                local crit = (e.critical and ' (CRITICAL)') or ''
                local msg = tostring(e.message or '')

                local cnt = tonumber(e.count) or 1
                local lastSeen = tostring(e.lastSeen or e.at or '')
                local cntS = (cnt > 1) and (' x' .. tostring(cnt) .. ' last=' .. lastSeen) or ''

                out[#out + 1] = ('--- %s [%s/%s sev=%s%s cause=%s]%s ---'):format(at, origin, phase, sev, crit, cause, cntS)
                if msg ~= '' then
                    out[#out + 1] = msg
                else
                    out[#out + 1] = '(no message)'
                end
            else
                out[#out + 1] = tostring(e)
            end
        end
    else
        out[#out + 1] = '(none)'
    end
    if sess and tonumber(sess.errorsDropped) and sess.errorsDropped > 0 then
        out[#out + 1] = string.format('(dropped %d additional unique error keys due to cap)', tonumber(sess.errorsDropped) or 0)
    end

    out[#out + 1] = ''

    local function addReportSection()
        out[#out + 1] = '[REPORT]'
        out[#out + 1] = '(one entry per spell/aura id; per-field secrecy and contexts; aggregated; minimal duplicates)'
        if Addon.Schema and Addon.Schema.BuildReportText then
            local db2 = Addon.GetDB and Addon:GetDB() or nil
            local ropts = db2 and db2.settings and db2.settings.export and db2.settings.export.report or {}
            local opts = { maxCtxPerPath = 8 }
            if type(ropts) == 'table' then
                for k, v in pairs(ropts) do opts[k] = v end
            end
            out[#out + 1] = Addon.Schema:BuildReportText(opts)
        else
            out[#out + 1] = '(schema not available)'
        end
    end

    if mode == 'report' then
        addReportSection()
        return table.concat(out, '\n')
    end

    if mode == 'full' then
        addReportSection()
        out[#out + 1] = ''
        out[#out + 1] = '[AUDIT]'
        if Addon.Schema and Addon.Schema.BuildAuditText then
            out[#out + 1] = Addon.Schema:BuildAuditText({ topN = 10 })
        else
            out[#out + 1] = '(audit not available)'
        end
        out[#out + 1] = ''
        out[#out + 1] = '(Use Raw for full schema dump; Entity for machine-friendly summary.)'
        return table.concat(out, '\n')
    end

    if mode == 'raw' then
        out[#out + 1] = '[SCHEMA RAW (HEAVY)]'
        if Addon.Schema and Addon.Schema.ExportSummaryLua then
            out[#out + 1] = Addon.Schema:ExportSummaryLua()
        else
            out[#out + 1] = '(schema not available)'
        end
        out[#out + 1] = ''
        out[#out + 1] = '[AUDIT]'
        if Addon.Schema and Addon.Schema.BuildAuditText then
            out[#out + 1] = Addon.Schema:BuildAuditText({ topN = 10 })
        else
            out[#out + 1] = '(audit not available)'
        end
        return table.concat(out, '\n')
    end

    -- entity
    out[#out + 1] = '[SCHEMA ENTITY SUMMARY]'
    out[#out + 1] = '(machine-friendly Lua table; 1 row per spell/aura id, with context classifications)'
    if Addon.Schema and Addon.Schema.ExportEntitySummaryLua then
        out[#out + 1] = Addon.Schema:ExportEntitySummaryLua({ includeContexts = true, includeAPIs = true })
    else
        out[#out + 1] = '(schema not available)'
    end

    return table.concat(out, '\n')
end

function UI:Export(mode)
    -- Slash command entry point.
    self:OpenExport(mode)
end

function UI:_SetExportText(text)
    if not self.exportBox then return end
    local box = self.exportBox
    local scroll = self.exportScroll

    text = tostring(text or '')

    -- Update text first.
    box:SetText(text)

    -- Resize cheaply (avoid expensive fontstring layout on very large blobs).
    local _, fontSize = box:GetFont()
    fontSize = tonumber(fontSize) or 12
    local _, nl = text:gsub('\n', '\n')
    local lines = nl + 1
    local h = (lines * (fontSize + 2)) + 24
    if h < 32 then h = 32 end
    if h > 2000000 then h = 2000000 end
    box:SetHeight(h)

    if scroll and scroll.UpdateScrollChildRect then
        scroll:UpdateScrollChildRect()
    end

    -- Reset cursor + scroll to top so the window never "opens empty" at the bottom.
    pcall(function() box:SetCursorPosition(0) end)
    if scroll and scroll.ScrollBar and scroll.ScrollBar.SetValue then
        pcall(function() scroll.ScrollBar:SetValue(0) end)
    end
    if scroll and scroll.SetVerticalScroll then
        pcall(function() scroll:SetVerticalScroll(0) end)
    end
end

function UI:_FocusExportBox()
    if not self.exportBox then return false end
    if InCombatLockdown and InCombatLockdown() then
        return false
    end
    pcall(function() self.exportBox:SetFocus() end)
    return true
end

function UI:_HighlightAllExport()
    if not self.exportBox then return end
    local n = 0
    if self.exportBox.GetNumLetters then
        n = tonumber(self.exportBox:GetNumLetters()) or 0
    end
    pcall(function()
        self.exportBox:SetCursorPosition(0)
        self.exportBox:HighlightText(0, n)
    end)
end

function UI:SelectAllExport()
    if not self.exportBox then return end
    if not self:_FocusExportBox() then
        Addon:Warn('EXPORT', 'Select/Copy is disabled in combat.')
        return
    end
    self:_HighlightAllExport()
end

function UI:CopyExport()
    if not self.exportBox then return end
    if not self:_FocusExportBox() then
        Addon:Warn('EXPORT', 'Select/Copy is disabled in combat.')
        return
    end
    self:_HighlightAllExport()
    Addon:Info('EXPORT', 'Text selected. Press Ctrl+C to copy.')
end

function UI:RefreshExport()
    if not self.exportBox then return end

    local mode = tostring(self.exportMode or 'log')
    self._exportCache = self._exportCache or {}
    local key = _export_cache_key(mode)
    local cached = self._exportCache[mode]

    -- If cached and key matches, reuse.
    if cached and cached.key == key and type(cached.text) == 'string' then
        self:_SetExportText(cached.text)
        return
    end

    -- Show placeholder quickly, then generate in next frame (avoids "blank" + reduces spike perception).
    self:_SetExportText(('(generating %s...)'):format(mode))

    self._exportGenToken = (tonumber(self._exportGenToken) or 0) + 1
    local token = self._exportGenToken

    local function gen()
        if token ~= self._exportGenToken then return end
        
        local co = coroutine.create(function()
            -- in Lua 5.1 xpcall across yields can sometimes fail depending on the patch, 
            -- but we can just let resume handle the error catching.
            return buildExportText(mode)
        end)
        
        local function pump()
            if token ~= self._exportGenToken then return end
            
            local ok, res = coroutine.resume(co)
            
            if not ok then
                local err = tostring(res)
                self._exportCache[mode] = { key = key, text = err }
                self:_SetExportText(err)
            elseif coroutine.status(co) == "suspended" then
                if type(C_Timer) == 'table' and type(C_Timer.After) == 'function' then
                    C_Timer.After(0, pump)
                else
                    pump()
                end
            else
                local text = tostring(res or '')
                self._exportCache[mode] = { key = key, text = text }
                self:_SetExportText(text)
            end
        end
        pump()
    end

    local defer = (mode ~= 'log')
    if defer and type(C_Timer) == 'table' and type(C_Timer.After) == 'function' then
        C_Timer.After(0, gen)
    else
        gen()
    end
end

function UI:OpenExport(mode)
    -- Opens a large export window. Default mode is configured via db.settings.export.defaultMode (default: "log").
    local db = Addon.GetDB and Addon:GetDB() or nil
    local m = tostring(mode or (db and db.settings and db.settings.export and db.settings.export.defaultMode) or 'log')
    if m == '' then m = 'log' end
    self.exportMode = m

    if self.exportFrame then
        local wasShown = self.exportFrame:IsShown()
        self.exportFrame:Show()
        self:SetExportMode(m, true)
        if wasShown then
            self:RefreshExport()
        end
        return
    end

    local ef = CreateFrame('Frame', 'RST2ExportFrame', UIParent, 'BackdropTemplate')
    ef:SetSize(900, 600)
    ef:SetPoint('CENTER')
    ef:SetMovable(true)
    ef:EnableMouse(true)
    ef:RegisterForDrag('LeftButton')
    ef:SetScript('OnDragStart', ef.StartMoving)
    ef:SetScript('OnDragStop', ef.StopMovingOrSizing)
    ef:SetBackdrop({
        bgFile = 'Interface\\DialogFrame\\UI-DialogBox-Background',
        edgeFile = 'Interface\\DialogFrame\\UI-DialogBox-Border',
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 }
    })
    ef:SetBackdropColor(0, 0, 0, 0.95)

    local title = ef:CreateFontString(nil, 'OVERLAY', 'GameFontNormalLarge')
    title:SetPoint('TOPLEFT', 16, -14)
    title:SetText('RST2 Export')
    ef._title = title

    local close = CreateFrame('Button', nil, ef, 'UIPanelCloseButton')
    close:SetPoint('TOPRIGHT', -6, -6)
    close:SetScript('OnClick', function() ef:Hide() end)

    -- Mode buttons
    local btnW, btnH = 70, 22

    local modeRaw = CreateFrame('Button', nil, ef, 'UIPanelButtonTemplate')
    modeRaw:SetSize(btnW, btnH)
    modeRaw:SetText('Raw')
    modeRaw:SetPoint('TOPRIGHT', close, 'TOPLEFT', -6, 0)

    local modeFull = CreateFrame('Button', nil, ef, 'UIPanelButtonTemplate')
    modeFull:SetSize(btnW, btnH)
    modeFull:SetText('Full')
    modeFull:SetPoint('TOPRIGHT', modeRaw, 'TOPLEFT', -6, 0)

    local modeReport = CreateFrame('Button', nil, ef, 'UIPanelButtonTemplate')
    modeReport:SetSize(btnW, btnH)
    modeReport:SetText('Report')
    modeReport:SetPoint('TOPRIGHT', modeFull, 'TOPLEFT', -6, 0)

    local modeEntity = CreateFrame('Button', nil, ef, 'UIPanelButtonTemplate')
    modeEntity:SetSize(btnW, btnH)
    modeEntity:SetText('Entity')
    modeEntity:SetPoint('TOPRIGHT', modeReport, 'TOPLEFT', -6, 0)

    local modeLog = CreateFrame('Button', nil, ef, 'UIPanelButtonTemplate')
    modeLog:SetSize(btnW, btnH)
    modeLog:SetText('Log')
    modeLog:SetPoint('TOPRIGHT', modeEntity, 'TOPLEFT', -6, 0)

    local selectBtn = CreateFrame('Button', nil, ef, 'UIPanelButtonTemplate')
    selectBtn:SetSize(90, 22)
    selectBtn:SetText('Select All')
    selectBtn:SetPoint('TOPRIGHT', modeLog, 'TOPLEFT', -6, 0)
    selectBtn:SetScript('OnClick', function() UI:SelectAllExport() end)

    local copyBtn = CreateFrame('Button', nil, ef, 'UIPanelButtonTemplate')
    copyBtn:SetSize(70, 22)
    copyBtn:SetText('Copy')
    copyBtn:SetPoint('TOPRIGHT', selectBtn, 'TOPLEFT', -6, 0)
    copyBtn:SetScript('OnClick', function() UI:CopyExport() end)

    local scroll = CreateFrame('ScrollFrame', nil, ef, 'UIPanelScrollFrameTemplate')
    scroll:SetPoint('TOPLEFT', 18, -46)
    scroll:SetPoint('BOTTOMRIGHT', -30, 20)

    local box = CreateFrame('EditBox', nil, scroll)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject('ChatFontNormal')
    box:EnableMouse(true)
    box:SetTextInsets(8, 8, 8, 8)
    box:SetScript('OnEscapePressed', function(self) self:ClearFocus() end)
    box:SetScript('OnMouseDown', function(self)
        if InCombatLockdown and InCombatLockdown() then return end
        pcall(function() self:SetFocus() end)
    end)

    scroll:SetScrollChild(box)

    self.exportFrame = ef
    self.exportBox = box
    self.exportScroll = scroll
    self._exportModeBtns = { log = modeLog, report = modeReport, full = modeFull, entity = modeEntity, raw = modeRaw }

    modeLog:SetScript('OnClick', function() UI:SetExportMode('log') end)
    modeReport:SetScript('OnClick', function() UI:SetExportMode('report') end)
    modeFull:SetScript('OnClick', function() UI:SetExportMode('full') end)
    modeEntity:SetScript('OnClick', function() UI:SetExportMode('entity') end)
    modeRaw:SetScript('OnClick', function() UI:SetExportMode('raw') end)

    ef:SetScript('OnShow', function()
        UI:SetExportMode(UI.exportMode or 'log', true)
        -- Ensure the scroll metrics are valid before sizing.
        if type(C_Timer) == 'table' and type(C_Timer.After) == 'function' then
            C_Timer.After(0, function() UI:RefreshExport() end)
        else
            UI:RefreshExport()
        end
    end)

    ef:Show()
end

function UI:SetExportMode(mode, suppressRefresh)
    local m = tostring(mode or 'log')
    if m ~= 'log' and m ~= 'report' and m ~= 'full' and m ~= 'entity' and m ~= 'raw' then
        m = 'log'
    end
    self.exportMode = m

    if self.exportFrame and self.exportFrame._title then
        self.exportFrame._title:SetText('RST2 Export - ' .. (m:upper()))
    end

    if self._exportModeBtns then
        for k, b in pairs(self._exportModeBtns) do
            if b then
                if k == m then b:Disable() else b:Enable() end
            end
        end
    end

    if not suppressRefresh then
        self:RefreshExport()
    end
end
