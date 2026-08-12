-- RothSecretTester Tester module (LoadOnDemand)
-- Contains probes/suites. Can fail without killing core.

local ADDON_NAME, Addon = ...
local Tester = {}
_G.RothSecretTesterTester = Tester

Tester.READY = false
Tester._inited = false
Tester.passiveEnabled = false

local CreateFrame = CreateFrame
local type = type
local pcall = pcall
local tostring = tostring
local GetTime = GetTime or _G.GetTime

function Tester:Init(core)
    if self._inited then return end
    self.core = core
    self.log = core.Log
    self.doctor = core.Doctor
    self._inited = true
    self.READY = true
end

function Tester:SuiteStart(suiteId)
    self._suiteId = suiteId
    local useProfile = (type(_G.debugprofilestop) == "function")
    self._suiteStats = {
        suite = suiteId,
        ok = true,
        calls = 0,
        scanned = 0,
        secrets = 0,
        tables = 0,
        frames = 0,
        -- Higher precision timing if available
        _useProfile = useProfile,
        started = useProfile and _G.debugprofilestop() or ((type(_G.GetTime) == "function") and _G.GetTime() or 0),
        duration = 0,
    }

    -- Reset per-session dedupe caches in the scanner to avoid unbounded memory growth
    -- and to ensure per-suite logs remain meaningful.
    if self.Scanner and type(self.Scanner.ResetSeen) == "function" then
        pcall(function() self.Scanner:ResetSeen() end)
    end
end

function Tester:SuiteEnd(ok, err)
    local s = self._suiteStats
    if not s then return end
    if s._useProfile then
        local t1 = _G.debugprofilestop()
        if type(s.started) == "number" and type(t1) == "number" then
            s.duration = (t1 - s.started) / 1000
        end
    else
        local t1 = (type(_G.GetTime) == "function") and _G.GetTime() or 0
        if type(s.started) == "number" and type(t1) == "number" then
            s.duration = t1 - s.started
        end
    end
    s.ok = ok and true or false
    s.error = (not ok) and tostring(err) or nil

    if self.core and type(self.core.SuiteReport) == "function" then
        self.core:SuiteReport(s)
    end

    self._suiteStats = nil
    self._suiteId = nil
end

function Tester:StatInc(key, n)
    local s = self._suiteStats
    if not s then return end
    n = n or 1
    s[key] = (tonumber(s[key]) or 0) + n
end

function Tester:Line(msg)
    if self.core and type(self.core.Line) == "function" then
        self.core:Line(msg)
    end
end

function Tester:AddFinding(...)
    if self.core and type(self.core.AddFinding) == "function" then
        self.core:AddFinding(...)
    end
end

-- Passive event frame
local f = CreateFrame("Frame")
Tester._frame = f

local function dispatch(event, ...)
    if Tester.passiveEnabled and Tester.PassiveOnEvent then
        Tester:PassiveOnEvent(event, ...)
    end
end

f:SetScript("OnEvent", function(_, event, ...)
    dispatch(event, ...)
end)

function Tester:SetPassive(enable)
    enable = enable and true or false
    self.passiveEnabled = enable
    f:UnregisterAllEvents()
    if not enable then return end

    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:RegisterEvent("UNIT_AURA")
    f:RegisterEvent("UNIT_POWER_UPDATE")
    f:RegisterEvent("UNIT_HEALTH")
    f:RegisterEvent("UNIT_SPELLCAST_START")
    f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
    f:RegisterEvent("UNIT_SPELLCAST_STOP")
    f:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
    f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end

local lastThrottledEvents = {}
local THROTTLE_TIME = 0.5

function Tester:PassiveOnEvent(event, ...)
    -- NOTE: Lua 5.1: do not reference varargs ("...") from inside nested closures.
    -- Capture what we need up front.
    local unit = ...
    
    local now = GetTime()
    local tkey = event .. ":" .. tostring(unit or "")
    if lastThrottledEvents[tkey] and (now - lastThrottledEvents[tkey] < THROTTLE_TIME) then
        return
    end
    lastThrottledEvents[tkey] = now


    local ok, err = pcall(function()
        if not self.suites then return end
        if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
            -- Auto-probe around combat transitions to capture context-dependent secret behavior.
            if self.suites and self.suites.cooldowns then
                self:RunSuite("cooldowns")
            end
        elseif event == "UNIT_AURA" then
            if unit == "player" or unit == "target" then
                self.suites.auras:ProbeUnit(unit, "PASSIVE")
            end
        elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_HEALTH" then
            if unit == "player" or unit == "target" then
                self.suites.units:ProbeUnit(unit, "PASSIVE")
            end
        elseif event:match("^UNIT_SPELLCAST_") then
            if unit == "player" or unit == "target" then
                self.suites.casting:ProbeUnit(unit, "PASSIVE")
            end
        end
    end)

    if not ok and self.core and self.core.Doctor then
        self.core.Doctor:Report(err, "tester", "probe", { event = event, passive = true })
    end
end


function Tester:RunSuite(suiteId, args)
    if not self.READY then error("Tester not ready") end
    local s = self.suites and self.suites[suiteId]
    if not s then error("Unknown suite: " .. tostring(suiteId)) end
    if type(s.Run) ~= "function" then error("Suite has no Run(): " .. tostring(suiteId)) end

    self:SuiteStart(suiteId)
    local ok, err = pcall(function()
        -- Suites may ignore args; that's fine.
        s:Run(args)
    end)
    self:SuiteEnd(ok, err)
    if not ok then error(err) end
end

-- Handshake (RST2: packaged inside main addon)
local f2 = CreateFrame("Frame")
f2:RegisterEvent("ADDON_LOADED")
f2:SetScript("OnEvent", function(_, _, name)
    if name ~= "RothSecretTester" then return end
    Tester.READY = true
    if _G.RothSecretTesterCore then
        _G.RothSecretTesterCore:RegisterTester(Tester)
    end
end)
