-- RothSecretTester (Core)
-- Always-load core: DB + Doctor + logging + UI shell + module loader.

local ADDON_NAME = ...
local Addon = {}
_G.RothSecretTesterCore = Addon

-- Metadata (best-effort; used only for UI/export text)
Addon.addonName = ADDON_NAME
do
    local meta = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")) or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version"))
    Addon.version = meta or "unknown"
end


local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local GetRealZoneText, GetSubZoneText = GetRealZoneText, GetSubZoneText
local UnitName = UnitName
local date = date
local type = type
local tostring = tostring
local pcall = pcall
local xpcall = xpcall

local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
local LoadAddOn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn

Addon.VERSION = "1.6.4"

-- Forward decl modules (filled by other lua files)
Addon.Doctor = nil
Addon.Log = nil
Addon.UI = nil
Addon.Integration = nil

-- Finding helper (bridges Tester -> Log)
-- Supports multiple call signatures for backward compatibility.
function Addon:AddFinding(category, level, a, b, ctx)
    if not self.Log or type(self.Log.AddFinding) ~= "function" then return end

    local Safe = self.Safe
    local function keyStr(v, opts)
        if Safe and Safe.Key then
            return Safe:Key(v, opts)
        end
        if Safe and Safe.SafeToString then
            return Safe:SafeToString(v)
        end
        return tostring(v)
    end

    -- Legacy: (category, level, key)
    if b == nil and a ~= nil and ctx == nil then
        self.Log:AddFinding(keyStr(category, { nilPlaceholder = "unknown" }), level, "legacy", keyStr(a), nil)
        return
    end

    -- Common: (category, level, api, key, ctx)
    self.Log:AddFinding(
        keyStr(category, { nilPlaceholder = "unknown" }),
        level,
        keyStr(a, { nilPlaceholder = "api" }),
        keyStr(b, { nilPlaceholder = "key" }),
        ctx
    )
end

-- --------------------------------
-- DB
-- --------------------------------
local DEFAULTS = {
    version = 3,
    settings = {
        maxSessions = 0, -- 0 = unlimited; keep all data until manual reset
        maxFindingsPerKey = 8,
        maxCatalogCall0 = 75,
        maxLinesPerSession = 600, -- cap per-session UI/log lines to avoid huge SV
        bugGrabber = { enabled = true, reportProbe = false, reportFindings = false },
        doctor = {
            enabled = true,
            burstWindowSec = 10,
            burstInternalLimit = 5,
            autoDisableTesterPassive = true,
            -- Flood control: store one record per unique error key and cap unique keys.
            maxErrorsPerSession = 120,
            maxErrorMsgLen = 1800,
        },
        ui = {
            -- UI remembers only filtering/selection state.
            filter = "all",
            search = "",
            selectedKey = nil,
        },
        tester = {
            autoLoad = false,
            -- Output control (collection still happens regardless):
            -- - printSecretObs: print one log line per (api/case/path/ctx) when the value is secret
            -- - printClearObs:  print one log line per (api/case/path/ctx) when the value is non-secret
            -- Default: OFF. The in-addon "chat" is for operational logs; the schema DB is the source of truth.
            printSecretObs = false,
            printClearObs = false,
        },
        schema = {
            -- SavedVariables safety caps for the schema (observations DB).
            -- 0 disables a cap, but be careful: passive probes can generate enormous SV.
            maxRows = 60000,          -- total unique (api,case,path) rows
            maxPathsPerCase = 250,    -- unique paths per (api,case)
            maxCtxPerPath = 40,       -- unique contexts per (api,case,path)
            maxSourcesPerPath = 40,   -- unique sources per (api,case,path)
        },
        export = {
            defaultMode = "log",
            report = {
                -- Report text caps (UI readability). 0 disables.
                maxEntities = 400,
                maxApisPerEntity = 20,
                maxPathsPerApi = 80,
                maxCtxPerPath = 8,
                maxIdxAuras = 20,

                -- Report filters (human-readable by default).
                -- We still keep per-path details filtered to secret/mixed unless explicitly enabled.
                includeNonSecretEntities = true,
                includeUnknownEntities = true,
                includeNonSecretPaths = false,
                includeUnknownPaths = false,
                compact = true,
            },
        },
log = {
    -- Operational UI chat filtering (SavedVariables-friendly)
    -- Levels: DEBUG < INFO < WARN < ERROR < CRITICAL
    minLevel = "INFO",
    showTime = true,

    -- Findings output control (Log:AddFinding). Collection is ALWAYS on.
    -- Modes:
    --   "off"      : never print per-finding lines (recommended; use Export->Report)
    --   "unique"   : print only the first time per unique (category/level/api/key)
    --   "milestone": print at counts 1,2,4,8,... per key
    --   "all"      : print every finding (can flood)
    findingsMode = "off",
},
    },
    sessions = {},
    lastSessionId = 0,
    schema = {
        version = 1,
        contexts = {},
        obs = {},
        meta = { created = 0, updated = 0 },
    },
    catalog = { version = 1, systems = {}, meta = { updated = 0 } },
}

local function deepcopy(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            deepcopy(dst[k], v)
        else
            if dst[k] == nil then dst[k] = v end
        end
    end
end

function Addon:GetDB()
    if type(_G.RothSecretTesterDB) ~= "table" then _G.RothSecretTesterDB = {} end
    local db = _G.RothSecretTesterDB
    deepcopy(db, DEFAULTS)
    deepcopy(db.settings, DEFAULTS.settings)

    -- One-time migration for defaults / UX changes.
    -- We intentionally avoid rewriting user data except for explicitly requested defaults.
    local v = tonumber(db.version) or 0
    if v < 3 then
        -- User requested: Export window should default to Full.
        if type(db.settings) ~= "table" then db.settings = {} end
        db.settings.export = db.settings.export or {}
        db.settings.export.defaultMode = "log"

        -- Report should never look empty when everything is clear.
        db.settings.export.report = db.settings.export.report or {}
        if db.settings.export.report.includeNonSecretEntities == nil then db.settings.export.report.includeNonSecretEntities = true end
        if db.settings.export.report.includeUnknownEntities == nil then db.settings.export.report.includeUnknownEntities = true end
        if db.settings.export.report.compact == nil then db.settings.export.report.compact = true end

        db.version = 3
    end
    return db
end

-- Mark the persistent DB as updated.
-- Note: SavedVariables are written to disk by WoW on /reload, logout, or exit.
-- We keep this method extremely low-noise (one line per session by default).
function Addon:MarkDBDirty(reason)
    local db = self:GetDB()
    db.meta = db.meta or {}
    db.meta.dirtyWrites = (tonumber(db.meta.dirtyWrites) or 0) + 1
    db.meta.lastDirtyAt = date("%Y-%m-%d %H:%M:%S")
    db.meta.lastDirtyReason = tostring(reason or "update")

    local sess = self.activeSession
    if sess and not sess._dbDirtyNotified then
        sess._dbDirtyNotified = true
        self:Info("DB", string.format("updated (%s). SavedVariables persist after /reload/logout.", db.meta.lastDirtyReason))
    end
end

local function contextSnapshot()
    local inInstance, instanceType = IsInInstance()
    return {
        time = date("%Y-%m-%d %H:%M:%S"),
        combat = InCombatLockdown() and true or false,
        instance = inInstance and true or false,
        instanceType = instanceType or "none",
        zone = GetRealZoneText() or "unknown",
        subzone = GetSubZoneText() or "",
        player = UnitName("player") or "unknown",
    }
end

function Addon:ContextSnapshot()
    -- Robust, minimal snapshot intended for suites/UI (not for schema bookkeeping).
    local combat = false
    if UnitAffectingCombat then
        combat = UnitAffectingCombat("player") and true or false
    elseif InCombatLockdown then
        combat = InCombatLockdown() and true or false
    end

    local inInstance, instanceType = IsInInstance()
    local inGroup = IsInGroup and IsInGroup() or false
    local inRaid = IsInRaid and IsInRaid() or false
    local groupType = (inRaid and "raid") or (inGroup and "party") or "solo"
    local groupSize = (GetNumGroupMembers and (GetNumGroupMembers() or 0)) or 0

    local mapID = nil
    if type(C_Map) == "table" and type(C_Map.GetBestMapForUnit) == "function" then
        mapID = C_Map.GetBestMapForUnit("player")
    end

    local zone = (type(GetRealZoneText) == "function" and GetRealZoneText()) or nil
    local subzone = (type(GetSubZoneText) == "function" and GetSubZoneText()) or nil

    local difficultyID, maxPlayers, instanceID = nil, nil, nil
    if type(GetInstanceInfo) == "function" then
        local _, _, did, _, mp, _, _, iid = GetInstanceInfo()
        difficultyID, maxPlayers, instanceID = did, mp, iid
    end

    local encounter = (type(IsEncounterInProgress) == "function" and IsEncounterInProgress()) or false

    local ctx = {
        time = date("%Y-%m-%d %H:%M:%S"),
        combat = combat,
        inInstance = inInstance and true or false,
        instanceType = instanceType or "none",
        groupType = groupType,
        groupSize = groupSize,
        mapID = mapID,
        zone = zone,
        subzone = subzone,
        difficultyID = difficultyID,
        maxPlayers = maxPlayers,
        instanceID = instanceID,
        encounter = encounter,
    }
    ctx.ckey = ("c=%d|inst=%s|g=%s"):format(ctx.combat and 1 or 0, ctx.instanceType or "none", ctx.groupType or "solo")
    return ctx
end

function Addon:NewSession(label)
    local db = self:GetDB()
    db.lastSessionId = (db.lastSessionId or 0) + 1

    local sess = {
        id = db.lastSessionId,
        label = label or "manual",
        createdAt = date("%Y-%m-%d %H:%M:%S"),
        context = contextSnapshot(),
        findings = {},
        errors = {},
        lines = {},
    }

    db.sessions[#db.sessions + 1] = sess
    local maxS = tonumber(db.settings.maxSessions) or 0
    if maxS > 0 then
        while #db.sessions > maxS do table.remove(db.sessions, 1) end
    end

    self.activeSession = sess
    if self._preLines then
        for i = 1, #self._preLines do
            sess.lines[#sess.lines + 1] = self._preLines[i]
            if self.UI and self.UI.AppendLine then self.UI:AppendLine(self._preLines[i]) end
        end
        self._preLines = nil
    end
    self:Info("SESSION", ("=== Session #%d (%s) %s ==="):format(sess.id, sess.createdAt, sess.label))
    self:Info("SESSION", ("Context: combat=%s instance=%s(%s) zone=%s"):format(
        sess.context.combat and "yes" or "no",
        sess.context.inInstance and "yes" or "no",
        sess.context.instanceType2 or sess.context.instanceType or "none",
        sess.context.zone or ""
    ))

    return sess
end

-- --------------------------------
-- Operational logging (UI "chat")
-- --------------------------------
local LEVELS = { DEBUG = 10, INFO = 20, WARN = 30, ERROR = 40, CRITICAL = 50 }
local LEVEL_CHAR = { DEBUG = "D", INFO = "I", WARN = "W", ERROR = "E", CRITICAL = "C" }

-- NOTE: Do NOT name this method "Log".
-- Addon.Log is reserved for the findings logger (see log.lua).
function Addon:LogMsg(level, tag, msg)
    level = tostring(level or "INFO"):upper()
    tag = tostring(tag or "CORE"):upper()
    local Safe = self.Safe
    if Safe and Safe.SafeToString then
        msg = Safe:SafeToString(msg or "")
    else
        msg = tostring(msg or "")
    end
    local db = self:GetDB()
    local s = db.settings and db.settings.log or {}
    local minLevel = tostring(s.minLevel or "INFO"):upper()
    local minN = LEVELS[minLevel] or 20
    local n = LEVELS[level] or 20

    -- Always surface CRITICAL regardless of filters.
    if n < minN and level ~= "CRITICAL" then
        return
    end

    local prefix = ""
    if s.showTime ~= false then
        prefix = "[" .. date("%H:%M:%S") .. "]"
    end
    prefix = prefix .. "[" .. (LEVEL_CHAR[level] or "?") .. "][" .. tag .. "] "

    self:Line(prefix .. msg)
end

function Addon:Debug(tag, msg) self:LogMsg("DEBUG", tag, msg) end
function Addon:Info(tag, msg)  self:LogMsg("INFO",  tag, msg) end
function Addon:Warn(tag, msg)  self:LogMsg("WARN",  tag, msg) end
function Addon:Error(tag, msg) self:LogMsg("ERROR", tag, msg) end
function Addon:Crit(tag, msg)  self:LogMsg("CRITICAL", tag, msg) end

function Addon:Line(s)
    -- Separate timestamp from body to group identical messages
    local timeStr, msgBody = s:match("^(%[%d%d:%d%d:%d%d%])(.*)")
    if not msgBody then
        msgBody = s
        timeStr = ""
    end

    local sess = self.activeSession

    if self._lastLineBody == msgBody then
        self._repeatCount = (self._repeatCount or 0) + 1
        if sess and #sess.lines > 0 then
            sess.lines[#sess.lines] = timeStr .. msgBody .. (" (x%d)"):format(self._repeatCount + 1)
        end
        return
    else
        if (self._repeatCount or 0) > 0 and self.UI and self.UI.AppendLine then
            self.UI:AppendLine(("[ui] Previous line repeated %d times"):format(self._repeatCount))
        end
        self._repeatCount = 0
        self._lastLineBody = msgBody
    end

    if not sess then
        self._preLines = self._preLines or {}
        self._preLines[#self._preLines + 1] = s
        return
    end

    sess.lines[#sess.lines + 1] = s

    -- Prevent SavedVariables/log bloat: keep only the last N lines per session.
    local db = self:GetDB()
    local maxL = (db and db.settings and tonumber(db.settings.maxLinesPerSession)) or 0
    if maxL > 0 and #sess.lines > maxL then
        local drop = #sess.lines - maxL
        for _ = 1, drop do table.remove(sess.lines, 1) end
    end

    if self.UI and self.UI.AppendLine then self.UI:AppendLine(s) end
end

-- --------------------------------
-- Tester module handling
-- --------------------------------
Addon.tester = nil

-- --------------------------------
-- List pack registry (data-only addons)
-- --------------------------------
Addon._listPacks = Addon._listPacks or {}

function Addon:RegisterListPack(packName, pack)
    if type(packName) ~= "string" or packName == "" then return end
    if type(pack) ~= "table" then return end
    self._listPacks[packName] = pack
    self:Info("PACK", ("List pack registered: %s"):format(packName))
end

function Addon:GetListPacks()
    return self._listPacks
end

-- Global helper for pack addons.
_G.RothSecretTester_RegisterListPack = function(packName, pack)
    if _G.RothSecretTesterCore and _G.RothSecretTesterCore.RegisterListPack then
        _G.RothSecretTesterCore:RegisterListPack(packName, pack)
    end
end

-- ---------------------------------------------------------------------------
-- Interactive modules (LoadOnDemand addons)
-- A module is a self-contained probe (often event-driven) that can be started/stopped from UI.

Addon.modules = Addon.modules or {}
Addon.activeModuleId = nil

function Addon:RegisterModule(mod)
    if type(mod) ~= "table" then return end
    local id = tostring(mod.id or mod.name or "")
    if id == "" then return end
    if not mod.addonName and self._loadingAddOn then
        mod.addonName = self._loadingAddOn
    end


    self.modules[id] = mod
    if type(mod.Init) == "function" and not mod._inited then
        pcall(function() mod:Init(self) end)
        mod._inited = true
    end

    -- Best-effort UI glue: if the user selected a module addon, remember its registered id.
    local db = self:GetDB()
    if db and db.settings and db.settings.ui and type(mod.addonName) == 'string' then
        if db.settings.ui.selectedModuleAddOn == mod.addonName then
            db.settings.ui.selectedModuleId = id
        end
    end

    self:Info("MODULE", ("registered id=%s name=%s"):format(id, tostring(mod.name or id)))
    if self.UI and self.UI.RefreshStatus then self.UI:RefreshStatus() end
end

function Addon:GetModules()
    return self.modules
end

function Addon:LoadModule(addonName)
    if not addonName or addonName == "" then return false end
    if IsAddOnLoaded(addonName) then return true end

    if InCombatLockdown and InCombatLockdown() then
        self:Warn('MODULE', ('LoadAddOn blocked in combat: %s'):format(tostring(addonName)))
        return false
    end

    self._loadingAddOn = addonName
    local ok, loaded, reason = pcall(LoadAddOn, addonName)
    self._loadingAddOn = nil

    if not ok then
        self:Crit("MODULE", ("LoadAddOn crashed: %s"):format(tostring(loaded)))
        return false
    end
    if not loaded then
        self:Error("MODULE", ("LoadAddOn failed: %s (%s)"):format(addonName, tostring(reason or "unknown")))
        return false
    end

    self:Info("MODULE", ("Loaded %s"):format(addonName))
    return true
end

function Addon:StartModule(id)
    id = tostring(id or "")
    if id == "" then return end
    -- Stop previous active module (single-active policy to avoid event collisions)
    if self.activeModuleId and self.activeModuleId ~= id then
        self:StopModule(self.activeModuleId)
    end

    local mod = self.modules[id]
    if not mod then
        self:Line("StartModule: unknown module " .. id)
        return
    end

    self.activeModuleId = id
    self:NewSession("module:" .. id)

if type(mod.Start) == "function" then
    local ok, err = xpcall(function()
        mod:Start({ core = self, session = self.activeSession })
    end, function(e)
        local st = (debugstack and debugstack(2, 20, 20)) or ""
        if st ~= "" then return tostring(e) .. "\n" .. st end
        return tostring(e)
    end)
    if not ok then
        if self.Doctor then self.Doctor:Report(err, "module", "start", { id = id }, { severity = "CRITICAL" }) end
        self:Crit("MODULE", "StartModule crashed; module disabled.")
        self.activeModuleId = nil
        return
    end
end

    self:Info("MODULE", "started " .. id)
    if self.UI and self.UI.RefreshStatus then self.UI:RefreshStatus() end
end


function Addon:GetModulesByAddon(addonName)
    if not addonName then return {} end
    local out = {}
    for id, m in pairs(self.modules or {}) do
        if m and m.addonName == addonName then
            out[#out+1] = id
        end
    end
    table.sort(out)
    return out
end

function Addon:ResetAll()
    if InCombatLockdown and InCombatLockdown() then
        self._pendingReset = true
        self:Warn("RESET", "queued (combat lockdown); will reset after leaving combat.")
        return
    end
    self._pendingReset = nil
    self:Warn("RESET", "wiping saved variables and reloading UI.")
    _G.RothSecretTesterDB = nil
    ReloadUI()
end

function Addon:StopModule(id)
    id = tostring(id or self.activeModuleId or "")
    if id == "" then return end

    local mod = self.modules[id]
    if mod and self._loadingAddOn and (not mod.addonName or mod.addonName == "") then
        mod.addonName = self._loadingAddOn
    end

if mod and type(mod.Stop) == "function" then
    local ok, err = xpcall(function()
        mod:Stop({ core = self, session = self.activeSession })
    end, function(e)
        local st = (debugstack and debugstack(2, 20, 20)) or ""
        if st ~= "" then return tostring(e) .. "\n" .. st end
        return tostring(e)
    end)
    if not ok then
        if self.Doctor then self.Doctor:Report(err, "module", "stop", { id = id }, { severity = "CRITICAL" }) end
        self:Crit("MODULE", "StopModule crashed (module cleanup may be incomplete).")
    end
end

    if self.activeModuleId == id then self.activeModuleId = nil end
    self:Info("MODULE", "stopped " .. id)
    if self.UI and self.UI.RefreshStatus then self.UI:RefreshStatus() end
end

function Addon:IsModuleRunning(id)
    id = tostring(id or "")
    return (self.activeModuleId == id)
end

_G.RothSecretTester_RegisterModule = function(mod)
    if _G.RothSecretTesterCore and _G.RothSecretTesterCore.RegisterModule then
        _G.RothSecretTesterCore:RegisterModule(mod)
    end
end

function Addon:IsTesterLoaded()
    return type(self.tester) == "table" and self.tester.READY == true
end

function Addon:LoadTester()
    -- In RST2, tester code is packaged inside the main addon.
    -- Keep backward compatibility: if user still has a separate LoadOnDemand tester addon, we can load it.
    if self.tester and self.tester.READY then
        return true
    end

    local Tester = _G.RothSecretTesterTester
    if Tester and type(Tester.Init) == "function" then
        self.tester = Tester
        if not Tester._inited then
            local ok, err = pcall(function() Tester:Init(self) end)
            if not ok then
                self:Crit("TESTER", ("Tester Init error: %s"):format(tostring(err)))
                if self.Doctor then self.Doctor:Report(err, "tester", "init") end
                return false
            end
        end
        Tester.READY = true
        return true
    end

    -- Fallback: old architecture (separate addon)
    local ok, res = pcall(function()
        if IsAddOnLoaded("RothSecretTester_Tester") then
            self.tester = _G.RothSecretTesterTester
            if self.tester and self.tester.Init and not self.tester._inited then
                self.tester:Init(self)
            end
            return self:IsTesterLoaded()
        end
        if InCombatLockdown and InCombatLockdown() then
            self:Warn("TESTER", "LoadAddOn blocked in combat: RothSecretTester_Tester")
            return false
        end
        local loaded, err = ((C_AddOns and C_AddOns.LoadAddOn) or _G.LoadAddOn)("RothSecretTester_Tester")
        if not loaded then
            self:Error("TESTER", ("Tester LoadAddOn failed: %s"):format(tostring(err)))
            return false
        end
        self.tester = _G.RothSecretTesterTester
        if self.tester and self.tester.Init and not self.tester._inited then
            self.tester:Init(self)
        end
        return self:IsTesterLoaded()
    end)
    if not ok then
        self:Crit("TESTER", ("Tester Load error: %s"):format(tostring(res)))
        if self.Doctor then self.Doctor:Report(res, "core", "internal", { step = "LoadTester" }) end
        return false
    end
    return res and true or false
end


function Addon:RegisterTester(testerTable)
    self.tester = testerTable
    if self.tester and self.tester.Init and not self.tester._inited then
        self.tester:Init(self)
    end
    if self.tester then self.tester.READY = true end
end


-- --------------------------------
-- Loader module handling (loads data-only list packs)
-- --------------------------------
Addon.loader = nil

function Addon:IsLoaderLoaded()
    return type(self.loader) == "table" and self.loader.READY == true
end

function Addon:LoadLoader()
    if self:IsLoaderLoaded() then return true end
    local ok, res = pcall(function()
        if not IsAddOnLoaded("RothSecretTester_Loader") then
            if InCombatLockdown and InCombatLockdown() then
                self:Warn("PACK", "LoadAddOn blocked in combat: RothSecretTester_Loader")
                return false
            end
            local loaded, err = ((C_AddOns and C_AddOns.LoadAddOn) or _G.LoadAddOn)("RothSecretTester_Loader")
            if not loaded then
                self:Warn("PACK", ("Loader LoadAddOn failed: %s"):format(tostring(err)))
                return false
            end
        end
        self.loader = _G.RothSecretTesterLoader
        if self.loader and self.loader.Init and not self.loader._inited then
            self.loader:Init(self)
        end
        return self:IsLoaderLoaded()
    end)
    if not ok then
        self:Crit("PACK", ("Loader Load error: %s"):format(tostring(res)))
        if self.Doctor then self.Doctor:Report(res, "core", "internal", { step = "LoadLoader" }) end
        return false
    end
    return res and true or false
end

function Addon:RegisterLoader(loaderTable)
    self.loader = loaderTable
    if self.loader and self.loader.Init and not self.loader._inited then
        self.loader:Init(self)
    end
end

function Addon:LoadPack(addonName)
    if type(addonName) ~= "string" or addonName == "" then return false end
    if self:IsLoaderLoaded() and type(self.loader.LoadPack) == "function" then
        return self.loader:LoadPack(addonName)
    end
    if InCombatLockdown and InCombatLockdown() then
        self:Warn("PACK", ("LoadAddOn blocked in combat: %s"):format(tostring(addonName)))
        return false
    end
    local loaded, err = ((C_AddOns and C_AddOns.LoadAddOn) or _G.LoadAddOn)(addonName)
    if not loaded then
        self:Warn("PACK", ("Pack LoadAddOn failed: %s"):format(tostring(err)))
        return false
    end
    return true
end



-- --------------------------------
-- AddOn discovery helpers
-- --------------------------------
function Addon:DiscoverAddOns(prefix)
    prefix = tostring(prefix or "")
    if prefix == "" then return {} end

    local getNum = (_G.C_AddOns and C_AddOns.GetNumAddOns) or _G.GetNumAddOns
    local getInfo = (_G.C_AddOns and C_AddOns.GetAddOnInfo) or _G.GetAddOnInfo
    if type(getNum) ~= "function" or type(getInfo) ~= "function" then
        return {}
    end

    local out = {}
    local n = getNum()
    for i = 1, n do
        local name = getInfo(i)
        if type(name) == "string" and name:sub(1, #prefix) == prefix then
            out[#out + 1] = name
        end
    end

    table.sort(out)
    return out
end
-- Unified discovery of all LoadOnDemand sub-addons (packs / modules / test suites)
Addon.DISCOVERY_GROUPS = Addon.DISCOVERY_GROUPS or {
    { kind = "pack",      prefix = "RothSecretTester_Pack_"      },
    { kind = "module",    prefix = "RothSecretTester_Module_"    },
    { kind = "testsuite", prefix = "RothSecretTester_TestSuite_" },
}

function Addon:DiscoverAllAddOns(force)
    if self._discoveredAll and not force then
        return self._discoveredAll
    end

    local out = {}
    for _, g in ipairs(self.DISCOVERY_GROUPS) do
        local names = self:DiscoverAddOns(g.prefix)
        for _, name in ipairs(names) do
            out[#out + 1] = { kind = g.kind, name = name }
        end
    end

    table.sort(out, function(a, b)
        return a.name < b.name
    end)

    self._discoveredAll = out
    return out
end

function Addon:GetDiscovered(kind)
    local out = {}
    for _, it in ipairs(self:DiscoverAllAddOns(false)) do
        if it.kind == kind then
            out[#out + 1] = it.name
        end
    end
    return out
end

function Addon:LoadAddOnByName(addonName, silent)
    if not addonName or addonName == "" then
        return false
    end

    if IsAddOnLoaded(addonName) then
        return true
    end

    if InCombatLockdown and InCombatLockdown() then
        if not silent then self:Warn("CORE", ("LoadAddOn blocked in combat: %s"):format(tostring(addonName))) end
        return false
    end

    local loader = (C_AddOns and C_AddOns.LoadAddOn) or _G.LoadAddOn
    if type(loader) ~= "function" then
        if not silent then self:Crit("CORE", "No LoadAddOn API available.") end
        return false
    end

    local ok, reason = loader(addonName)
    if (not silent) and (not ok) then
        self:Warn("CORE", ("Failed to load %s (%s)"):format(addonName, tostring(reason)))
    end

    return ok and true or false
end

-- Load everything automatically once the UI is opened.
function Addon:AutoLoadOnUIOpen()
    -- RST2: keep this hook lightweight (UI should feel instant).
    if self._uiAutoLoaded then return end
    self._uiAutoLoaded = true
    self:LoadTester()
end

-- --------------------------------
-- Public actions (UI / slash)
-- --------------------------------
function Addon:RunSuite(suiteId, args)
    if not self.activeSession then self:NewSession("run-suite") end

    if not self:IsTesterLoaded() then
        if not self:LoadTester() then
            self:Error("TESTER", "Tester is not loaded; cannot run suite.")
            return
        end
    end

    if not self.tester or type(self.tester.RunSuite) ~= "function" then
        self:Crit("TESTER", "Tester API missing RunSuite.")
        return
    end

    self:Info("TESTER", ("--- Suite: %s ---"):format(suiteId))
    self.Doctor:Call("tester", "probe", { suite = suiteId }, function()
        self.tester:RunSuite(suiteId, args)
    end)
end


function Addon:SuiteReport(stats)
    if type(stats) ~= "table" then return end
    local sess = self.activeSession
    if not sess then sess = self:NewSession("auto") end

    sess.suiteStats = sess.suiteStats or {}
    local sid = stats.suite or "unknown"
    sess.suiteStats[sid] = sess.suiteStats[sid] or {}
    sess.suiteStats[sid][#sess.suiteStats[sid] + 1] = stats

    local ok = stats.ok and true or false
    local dt = 0
    if type(stats.duration) == "number" then dt = stats.duration end

    self:Info("TESTER", ("[suite:%s] ok=%s calls=%d scanned=%d secrets=%d tables=%d frames=%d time=%.3fs"):format(
        sid,
        ok and "yes" or "no",
        tonumber(stats.calls) or 0,
        tonumber(stats.scanned) or 0,
        tonumber(stats.secrets) or 0,
        tonumber(stats.tables) or 0,
        tonumber(stats.frames) or 0,
        dt
    ))
end

function Addon:TogglePassive(on)
    if not self:IsTesterLoaded() then
        if on then
            if not self:LoadTester() then
                self:Line("Tester is not loaded; cannot enable passive.")
                return
            end
        else
            return
        end
    end

    if self.tester and type(self.tester.SetPassive) == "function" then
        self.Doctor:Call("tester", "probe", { passive = on and true or false }, function()
            self.tester:SetPassive(on and true or false)
        end)
    end
end

-- --------------------------------
-- Bootstrap
-- --------------------------------
function Addon:IsReady()
    return self._booted == true
end

function Addon:Bootstrap()
    if self._booted then return end

    self:GetDB()
    if self.Log and self.Log.Init then self.Log:Init(self) end
    if self.Schema and self.Schema.Init then self.Schema:Init(self) end
    if self.Integration and self.Integration.Init then self.Integration:Init(self) end
    if self.Doctor and self.Doctor.Init then self.Doctor:Init(self) end
    if self.UI and self.UI.Init then self.UI:Init(self) end

    self._booted = true
    self:Info("CORE", "Bootstrapped.")

    local db = self:GetDB()
    if db.settings.tester and db.settings.tester.autoLoad then
        self:LoadTester()
    end
end

-- --------------------------------
-- Events (core)
-- --------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_REGEN_ENABLED")

f:SetScript("OnEvent", function(_, event, ...)
    local args = { ... }
    if Addon.Doctor then
        Addon.Doctor:Call("core", "internal", { event = event }, function()
            if event == "ADDON_LOADED" then
                local name = args[1]
                if name == "RothSecretTester" then
                    Addon:Bootstrap()
                    -- If the addon is enabled/loaded after PLAYER_LOGIN (e.g. via addon managers),
                    -- PLAYER_LOGIN will not fire again. Ensure essential UI is still initialized.
                    if type(_G.IsLoggedIn) == "function" and _G.IsLoggedIn() then
                        if Addon.UI and Addon.UI.RefreshStatus then Addon.UI:RefreshStatus() end
                    end
                elseif name == "RothSecretTester_Tester" then
                    if _G.RothSecretTesterTester then
                        Addon:RegisterTester(_G.RothSecretTesterTester)
                        Addon:Info("TESTER", "Tester module registered.")
                    end
                end
            elseif event == "PLAYER_LOGIN" then
                if Addon.UI and Addon.UI.RefreshStatus then Addon.UI:RefreshStatus() end
            end
        end)
    else
        if event == "ADDON_LOADED" and args[1] == "RothSecretTester" then
            Addon:Bootstrap()
        end
    end
end)

-- --------------------------------
-- Slash
-- --------------------------------
SLASH_ROTHSECRETT1 = "/rst"
SlashCmdList["ROTHSECRETT"] = function(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^(%S+)%s*(.-)%s*$")
    cmd = cmd and cmd:lower() or ""

    if cmd == "" or cmd == "show" then
        if Addon.UI then Addon.UI:Toggle(true) end
        return
    end
    if cmd == "hide" then
        if Addon.UI then Addon.UI:Toggle(false) end
        return
    end
    if cmd == "new" then
        Addon:NewSession("manual")
        if Addon.UI and Addon.UI.RefreshStatus then Addon.UI:RefreshStatus() end
        return
    end
    if cmd == "export" then
        -- Default to configured mode (db.settings.export.defaultMode).
        if Addon.UI and Addon.UI.Export then Addon.UI:Export(nil) end
        return
    end
    if cmd == "exportfull" or cmd == "export_full" then
        if Addon.UI and Addon.UI.Export then Addon.UI:Export("full") end
        return
    end
    if cmd == "audit" then
        -- Full export includes an [AUDIT] section.
        if Addon.UI and Addon.UI.Export then Addon.UI:Export("full") end
        return
    end
    if cmd == "reset" then
        Addon:ResetAll()
        return
    end
    if cmd == "bdk" or cmd == "fdk" or cmd == "udk" then
        Addon:StartModule(cmd:upper())
        return
    end
    if cmd == "passive" then
        local on = (rest == "1" or rest:lower() == "on" or rest:lower() == "true")
        Addon:TogglePassive(on)
        if Addon.UI and Addon.UI.RefreshStatus then Addon.UI:RefreshStatus() end
        return
    end
    if cmd == "bugsack" then
        if Addon.Integration then Addon.Integration:OpenBugSack() end
        return
    end

    Addon:Info("CORE", "Usage: /rst [show|hide|new|export|exportfull|audit|reset|bdk|fdk|udk|passive on|passive off|bugsack]")
    if Addon.UI then Addon.UI:Toggle(true) end
end
