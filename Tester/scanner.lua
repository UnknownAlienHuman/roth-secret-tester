-- RothSecretTester Scanner (Tester)
-- Scans return values / nested tables. Records BOTH secret and non-secret paths into Core.Schema.

local Tester = _G.RothSecretTesterTester
if not Tester then return end

local type = type
local tostring = tostring
local pcall = pcall
local pairs = pairs
local table_concat = table.concat
local tinsert = table.insert

local function statInc(key, n)
    if Tester and type(Tester.StatInc) == "function" then
        Tester:StatInc(key, n or 1)
    elseif Tester and type(Tester._suiteStats) == "table" then
        local st = Tester._suiteStats
        st[key] = (tonumber(st[key]) or 0) + (n or 1)
    end
end

local function getSafe()
    local core = _G.RothSecretTesterCore
    return core and core.Safe or nil
end

local function keyStr(v, opts)
    local Safe = getSafe()
    if Safe and Safe.Key then
        return Safe:Key(v, opts)
    end
    local ok, s = pcall(tostring, v)
    return ok and s or "<tostring-error>"
end

local function isSecret(v)
    local core = _G.RothSecretTesterCore
    if core and core.Log and core.Log.IsSecret then
        return core.Log:IsSecret(v)
    end
    local Safe = getSafe()
    if Safe and Safe.IsSecret then
        return Safe:IsSecret(v)
    end
    if type(_G.issecretvalue) == "function" then
        local ok, r = pcall(_G.issecretvalue, v)
        return ok and r and true or false
    end
    return false
end

local function getOutputSettings()
    local core = _G.RothSecretTesterCore
    local db = core and core.GetDB and core:GetDB()
    local t = db and db.settings and db.settings.tester
    return t or {}
end

local function safeKey(k)
    if isSecret(k) then return "<SECRET_KEY>" end
    local tk = type(k)
    if tk == "string" or tk == "boolean" then
        return tostring(k)
    end
    if tk == "number" then
        -- collapse numeric indices
        return "[*]"
    end
    return "<" .. tk .. ">"
end

local function buildCaseKey(ctx)
    if type(ctx) ~= "table" then return "default" end

    -- Prefer explicit case key; suites should set this for stable identity.
    if type(ctx.case) == "string" and ctx.case ~= "" then
        return ctx.case
    end

    -- Stable identities (dedup):
    --  * spells: spell:<spellId>
    --  * auras:  aura:<unit>:<filter>:<spellId> (when spellId is safe)
    --  * auras:  auraIdx:<unit>:<filter>:<index> (fallback when spellId is secret/unknown)
    -- NOTE: list/pack is NOT part of the identity; it is carried via source attribution.

    local sid = ctx.spellId
    if type(sid) == "number" and (not isSecret(sid)) then
        if type(ctx.unit) == "string" and ctx.unit ~= "" and type(ctx.filter) == "string" and ctx.filter ~= "" then
            return string.format("aura:%s:%s:%d", ctx.unit, ctx.filter, sid)
        end
        return string.format("spell:%d", sid)
    end

    local itemId = ctx.itemId
    if type(itemId) == "number" and (not isSecret(itemId)) then
        return string.format("item:%d", itemId)
    end

    if type(ctx.unit) == "string" and ctx.unit ~= "" and type(ctx.filter) == "string" and ctx.filter ~= "" and type(ctx.auraIndex) == "number" then
        return string.format("auraIdx:%s:%s:%d", ctx.unit, ctx.filter, ctx.auraIndex)
    end

    local parts = {}

    local function addKV(k, v)
        local tv = type(v)
        if tv == "string" or tv == "number" or tv == "boolean" then
            -- Important: v may be SecretValue; normalize before concatenation.
            tinsert(parts, k .. "=" .. keyStr(v, { secretPlaceholder = "<secret>" }))
        elseif v ~= nil then
            tinsert(parts, k .. "=<" .. tv .. ">")
        end
    end

    addKV("unit", ctx.unit)
    addKV("unit2", ctx.unit2)
    addKV("filter", ctx.filter)
    addKV("spellId", ctx.spellId)
    addKV("itemId", ctx.itemId)
    addKV("slot", ctx.slot)

    if #parts == 0 then return "default" end
    return table_concat(parts, "|")
end

local seenObs = {}

local function wipeTable(t)
    if type(t) ~= "table" then return end
    for k in pairs(t) do t[k] = nil end
end

local function observe(suite, apiKey, caseKey, ctx, path, v)
    local core = _G.RothSecretTesterCore

    local apiS = keyStr(apiKey, { nilPlaceholder = "?", secretPlaceholder = "<secret_api>" })
    local caseS = keyStr(caseKey, { nilPlaceholder = "?", secretPlaceholder = "<secret_case>" })
    local pathS = keyStr(path, { nilPlaceholder = "?", secretPlaceholder = "<secret_path>" })

    -- Log classification per (api,case,path): by default print only secrets (one-time per path).
    local k = apiS .. "|" .. caseS .. "|" .. pathS
    local entry = seenObs[k]
    if not entry then
        entry = { clear = false, secret = false }
        seenObs[k] = entry
    end

    local out = getOutputSettings()
    local printClear = out.printClearObs == true
    local printSecret = out.printSecretObs ~= false

    local secret = isSecret(v)
    local ctxStr = "default"
    if type(ctx) == "table" then
        ctxStr = keyStr(ctx.ckey, { nilPlaceholder = "default", secretPlaceholder = "<secret_ctx>" })
    end

    if secret and (not entry.secret) then
        entry.secret = true
        if printSecret and core and type(core.Line) == "function" then
            core:Line(string.format('[OBS] cls=secret api=%s case=%s path=%s ctx=%s', apiS, caseS, pathS, ctxStr))
        end
    elseif (not secret) and (not entry.clear) then
        entry.clear = true
        if printClear and core and type(core.Line) == "function" then
            core:Line(string.format('[OBS] cls=clear api=%s case=%s path=%s ctx=%s', apiS, caseS, pathS, ctxStr))
        end
    end

    if core and core.Schema and core.Schema.Observe then
        -- Source attribution: include list/module when available to keep the report informative
        -- without polluting caseKey identity.
        local src = tostring(suite or "")
        if type(ctx) == "table" then
            local ln = ctx.listName or ctx.pack or ctx.moduleId or ctx.module
            if type(ln) == "string" and ln ~= "" then
                src = src .. "|list=" .. ln
            end
        end
        core.Schema:Observe(apiS, caseS, pathS, v, nil, src)
    end
end

local Scanner = {}
Tester.Scanner = Scanner

function Scanner:ResetSeen()
    -- Per-session cache to suppress duplicate observation lines.
    wipeTable(seenObs)
end

local function scanValue(suite, apiKey, caseKey, ctx, path, v, depth)
    observe(suite, apiKey, caseKey, ctx, path, v)

    if isSecret(v) then
        statInc("secrets", 1)
        return
    end

    local tv = type(v)
    if tv ~= "table" then
        return
    end

    local currentDepth = depth or 3
    if currentDepth <= 0 then
        return
    end

    local okIter, errIter
    okIter, errIter = pcall(function()
        for k, vv in pairs(v) do
            local sk = safeKey(k)
            local childPath = path .. "." .. sk
            scanValue(suite, apiKey, caseKey, ctx, childPath, vv, currentDepth - 1)
        end
    end)

    if not okIter then
        -- treat iteration errors as info, but do not fail suite
        statInc("tables", 1)
        if Tester and type(Tester.AddNote) == "function" then
            Tester:AddNote(suite, "table_iter_fail", keyStr(errIter, { nilPlaceholder = "unknown", secretPlaceholder = "<secret_err>" }))
        end
    else
        statInc("tables", 1)
    end
end

function Scanner:ScanReturns(suite, apiKey, ctx, ...)
    local caseKey = buildCaseKey(ctx)

    local n = select('#', ...)
    for i = 1, n do
        local v = select(i, ...)
        local path = "ret#" .. tostring(i)
        scanValue(suite, apiKey, caseKey, ctx, path, v, (type(ctx) == "table") and ctx.depth or 3)
    end
end

-- Convenience wrapper for scanning a single value (e.g., direct table values).
function Scanner:ScanValue(suite, apiKey, ctx, path, v)
    local caseKey = buildCaseKey(ctx)
    scanValue(suite, apiKey, caseKey, ctx, path, v, (type(ctx) == "table") and ctx.depth or 3)
end
