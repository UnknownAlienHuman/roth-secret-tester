-- RothSecretTester Doctor
-- Keeps core alive, isolates tester failures, classifies probe errors vs addon bugs.
-- Also bounds error growth (dedupe + cap) to prevent SavedVariables bloat.

local Addon = _G.RothSecretTesterCore
if not Addon then return end

local Doctor = {}
Addon.Doctor = Doctor

local date = date
local type = type
local tostring = tostring
local xpcall = xpcall
local pcall = pcall

local Safe = Addon.Safe

local function safeToString(v)
    -- Error objects are usually strings, but stay conservative.
    if Safe and Safe.SafeToString then
        return Safe:SafeToString(v)
    end
    local ok, s = pcall(tostring, v)
    return ok and s or "<tostring-error>"
end

local function _truncate(s, maxLen)
    if type(s) ~= "string" then return s end
    maxLen = tonumber(maxLen) or 1800
    if #s <= maxLen then return s end
    return s:sub(1, maxLen) .. "…"
end

local function captureError(err)
    local st = (debugstack and debugstack(3, 20, 20)) or ""
    if st ~= "" then
        return safeToString(err) .. "\n" .. st
    end
    return safeToString(err)
end

local PROBE_PATTERNS = {
    "blocked", "taint", "protected", "forbidden", "restricted", "secure", "insecure", "combat lockdown", "not permitted",
}
local BUG_PATTERNS = {
    "attempt to index", "attempt to call", "bad argument", "table expected", "string expected", "number expected", "nil value",
}

local SEV_ORDER = { DEBUG = 10, INFO = 20, WARN = 30, ERROR = 40, CRITICAL = 50 }

function Doctor:Severity(cause, origin, phase, msg, opts)
    -- Explicit override
    if opts and type(opts.severity) == "string" and opts.severity ~= "" then
        return opts.severity:upper()
    end

    local s = (msg or ""):lower()
    -- Hard-fail patterns
    if s:find("stack overflow", 1, true) or s:find("c stack overflow", 1, true) or s:find("out of memory", 1, true) then
        return "CRITICAL"
    end

    -- Module lifecycle errors should be treated as critical because they can poison subsequent runs.
    if origin == "module" and (phase == "start" or phase == "stop" or phase == "event") then
        return "CRITICAL"
    end

    if origin == "core" and (phase == "internal" or phase == "bootstrap") then
        return "CRITICAL"
    end

    if cause == "tested_api" then
        return "WARN"
    end
    if cause == "addon_bug" then
        return "ERROR"
    end
    return "ERROR"
end

function Doctor:Classify(errText)
    local s = (errText or ""):lower()

    -- If the stack/message clearly points at Blizzard FrameXML failing on secret values,
    -- treat it as tested API behavior (not our addon bug).
    if s:find("interface/addons/blizzard_", 1, true)
        or s:find("blizzard_framexml", 1, true)
        or s:find("framexmlutil", 1, true)
        or s:find("interface/framexml", 1, true)
        or s:find(": got secret", 1, true)
        or s:find("table expected, got secret", 1, true)
    then
        return "tested_api"
    end

    for _, p in ipairs(PROBE_PATTERNS) do
        if s:find(p, 1, true) then return "tested_api" end
    end
    for _, p in ipairs(BUG_PATTERNS) do
        if s:find(p, 1, true) then return "addon_bug" end
    end
    return "unknown"
end

function Doctor:Init(core)
    self.core = core
    self._burst = { windowStart = 0, internalCount = 0 }
end

local function ensureTable(t, k)
    local v = t[k]
    if type(v) ~= "table" then v = {}; t[k] = v end
    return v
end

function Doctor:Report(err, origin, phase, ctx, opts)
    local core = self.core or Addon
    local db = core:GetDB()
    local sess = core.activeSession
    if not sess then sess = core:NewSession("auto") end

    local msgFull = type(err) == "string" and err or captureError(err)
    local msg = msgFull

    local cause = self:Classify(msgFull)

    local severity = self:Severity(cause, origin or "core", phase or "internal", msgFull, opts)
    local critical = (severity == "CRITICAL")

    local safeCtx = ctx or {}
    if Safe and Safe.Sanitize then
        safeCtx = Safe:Sanitize(ctx, 2, { maxItems = 30, maxStringLen = 220, collapseNumbers = false })
    end

    -- Error aggregation (avoid floods). One record per unique first line + origin/phase/cause.
    local firstLine = msgFull:match("^[^\n]+") or msgFull
    local dset = (db.settings and db.settings.doctor) or {}
    local maxErrs = tonumber(dset.maxErrorsPerSession) or 120
    local maxMsgLen = tonumber(dset.maxErrorMsgLen) or 1800

    sess.errors = sess.errors or {}
    sess._errorIndex = sess._errorIndex or {}

    local key = (origin or "core") .. "|" .. (phase or "internal") .. "|" .. cause .. "|" .. firstLine

    local rec = sess._errorIndex[key]
    if rec then
        rec.count = (tonumber(rec.count) or 1) + 1
        rec.lastSeen = date("%H:%M:%S")
        -- do not overwrite the original message; keep the first captured stack for forensics
    else
        if #sess.errors >= maxErrs then
            sess.errorsDropped = (tonumber(sess.errorsDropped) or 0) + 1
        else
            msg = _truncate(msgFull, maxMsgLen)

            rec = {
                at = date("%H:%M:%S"),
                lastSeen = date("%H:%M:%S"),
                count = 1,
                origin = origin or "core",
                phase = phase or "internal",
                cause = cause,
                severity = severity,
                critical = critical,
                ctx = safeCtx,
                message = msg,
            }
            sess.errors[#sess.errors + 1] = rec
            sess._errorIndex[key] = rec
        end
    end

    -- Session-level quality flags (for export and post-processing).
    sess.quality = sess.quality or { dirty = false, dirtyCritical = false, sev = {}, cause = {} }
    sess.quality.sev[severity] = (sess.quality.sev[severity] or 0) + 1
    sess.quality.cause[cause] = (sess.quality.cause[cause] or 0) + 1
    if severity == "ERROR" or severity == "CRITICAL" then sess.quality.dirty = true end
    if critical then sess.quality.dirtyCritical = true end

    -- Operational line (single-line; aggregated count)
    local line = firstLine
    if rec and tonumber(rec.count) and rec.count > 1 then
        line = line .. string.format(" (x%d)", rec.count)
    end

    if core.Log then
        if core.LogMsg then
            core:LogMsg(severity, "DOCTOR", ("[%s/%s/%s] %s"):format(origin or "core", phase or "internal", cause, line))
        else
            core:Line(("[DOCTOR][%s/%s/%s] %s"):format(origin or "core", phase or "internal", cause, line))
        end
    else
        core:Line(("[RST][%s/%s/%s] %s"):format(origin or "core", phase or "internal", cause, line))
    end

    if core.Integration and core.Integration.MaybeReportError and rec then
        core.Integration:MaybeReportError(rec)
    end

    local settings = dset
    if settings.enabled and settings.autoDisableTesterPassive and origin == "tester" and cause == "addon_bug" and phase == "probe" then
        local now = GetTime and GetTime() or 0
        if self._burst.windowStart == 0 or (now - self._burst.windowStart) > (settings.burstWindowSec or 10) then
            self._burst.windowStart = now
            self._burst.internalCount = 0
        end
        self._burst.internalCount = self._burst.internalCount + 1
        if self._burst.internalCount >= (settings.burstInternalLimit or 5) then
            self._burst.windowStart = now
            self._burst.internalCount = 0
            if core.tester and core.tester.SetPassive then
                core:Warn("DOCTOR", "Disabling tester passive due to internal error burst.")
                pcall(function() core.tester:SetPassive(false) end)
            end
        end
    end
end

function Doctor:Call(origin, phase, ctx, fn, opts)
    local ok, res = xpcall(function()
        return fn()
    end, captureError)

    if not ok then
        self:Report(res, origin, phase, ctx, opts)
        return false
    end
    return true, res
end
