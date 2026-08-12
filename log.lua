-- RothSecretTester Log & Findings (Core)
-- Stores only "findings" (secret detections) and short lines.

local Addon = _G.RothSecretTesterCore
if not Addon then return end

local Log = {}
Addon.Log = Log

local date = date
local type = type
local tostring = tostring
local pcall = pcall

local Safe = Addon.Safe

local function safeToString(v)
    if Safe and Safe.SafeToString then
        return Safe:SafeToString(v)
    end
    local ok, s = pcall(tostring, v)
    return ok and s or "<tostring-error>"
end

local function isSecret(v)
    if Safe and Safe.IsSecret then
        return Safe:IsSecret(v)
    end
    if type(_G.issecretvalue) == "function" then
        local ok, r = pcall(_G.issecretvalue, v)
        return ok and r and true or false
    end
    return false
end

local function keyStr(v, opts)
    if Safe and Safe.Key then
        return Safe:Key(v, opts)
    end
    return safeToString(v)
end

local function ensure(t, k)
    local v = t[k]
    if type(v) ~= "table" then v = {}; t[k] = v end
    return v
end

function Log:Init(core)
    self.core = core
end

-- Finding levels:
-- 1 SECRET_RETURN, 2 SECRET_FIELD, 3 SECRET_ASPECT, 4 SECRET_ANCHOR, 5 API_DOC_FLAG
function Log:AddFinding(category, level, api, key, ctx)
    local core = self.core or Addon
    local sess = core.activeSession
    if not sess then sess = core:NewSession("auto") end

    category = keyStr(category, { nilPlaceholder = "unknown", secretPlaceholder = "<secret_cat>" })
    level = tonumber(level) or 0
    local levelKey = tostring(level)

    api = keyStr(api, { nilPlaceholder = "unknown", secretPlaceholder = "<secret_api>" })
    key = keyStr(key, { nilPlaceholder = "unknown", secretPlaceholder = "<secret_key>" })

    local byCat = ensure(sess.findings, category)
    local byLvl = ensure(byCat, levelKey)
    local byApi = ensure(byLvl, api)

    local rec = byApi[key]
    if not rec then
        rec = { count = 0, firstSeen = date("%H:%M:%S"), lastSeen = date("%H:%M:%S"), samples = {} }
        byApi[key] = rec
    end

    rec.count = rec.count + 1
    rec.lastSeen = date("%H:%M:%S")

    local db = core:GetDB()
    local max = (db.settings and db.settings.maxFindingsPerKey) or 8
    if ctx and type(ctx) == "table" and #rec.samples < max then
        -- Never persist raw SecretValues or large tables in SavedVariables.
        if Safe and Safe.Sanitize then
            rec.samples[#rec.samples + 1] = Safe:Sanitize(ctx, 2, { maxItems = 40, maxStringLen = 180, collapseNumbers = false })
        else
            rec.samples[#rec.samples + 1] = ctx
        end
    end

    -- Operational output (avoid floods; use Export->Report as the primary artifact)
    local db = core.GetDB and core:GetDB() or nil
    local lset = db and db.settings and db.settings.log or {}
    local mode = tostring(lset.findingsMode or "off")

    -- Per-session counters (in-memory only; never persisted)
    sess._findingMeta = sess._findingMeta or { collected = 0, unique = 0, printed = 0, suppressed = 0 }
    local meta = sess._findingMeta
    meta.collected = (tonumber(meta.collected) or 0) + 1
    if rec.count == 1 then meta.unique = (tonumber(meta.unique) or 0) + 1 end

    local function isPow2(n)
        -- Lua 5.1 safe check (no bitwise operators).
        n = tonumber(n) or 0
        if n < 1 then return false end
        while n % 2 == 0 do
            n = n / 2
        end
        return n == 1
    end

    local shouldPrint = false
    if mode == "all" then
        shouldPrint = true
    elseif mode == "unique" then
        shouldPrint = (rec.count == 1)
    elseif mode == "milestone" then
        shouldPrint = isPow2(rec.count)
    else
        shouldPrint = false
    end

    if shouldPrint then
        meta.printed = (tonumber(meta.printed) or 0) + 1
        local line
        if rec.count == 1 then
            line = ("[FND][NEW][%s][L%s] %s :: %s"):format(category, levelKey, api, key)
        else
            line = ("[FND][%s][L%s] %s :: %s (x%d)"):format(category, levelKey, api, key, rec.count)
        end
        if core.Info then core:Info("FIND", line) elseif core.Line then core:Line(line) end
    else
        meta.suppressed = (tonumber(meta.suppressed) or 0) + 1
    end

    if core.Integration and core.Integration.MaybeReportFinding then
        core.Integration:MaybeReportFinding(category, level, api, key, rec)
    end
end

function Log:IsSecret(v) return isSecret(v) end
function Log:SafeToString(v) return safeToString(v) end
