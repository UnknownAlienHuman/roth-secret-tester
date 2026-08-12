-- RothSecretTester Suites (Tester)

local Tester = _G.RothSecretTesterTester
if not Tester then return end

Tester.suites = Tester.suites or {}

local Scanner = Tester.Scanner
local Suites = Tester.suites

local function now()
    return _G.time and _G.time() or 0
end

-- Merge suite-local hints into a base context snapshot.
local function ctxBase(extra)
    local core = _G.RothSecretTesterCore
    local ctx = (core and core.ContextSnapshot and core:ContextSnapshot()) or {}
    if type(extra) == "table" then
        for k, v in pairs(extra) do ctx[k] = v end
    end
    return ctx
end

-- --- Suite helpers -----------------------------------------------------------

local function pack(...)
    return { n = select('#', ...), ... }
end

local function unpackTbl(t)
    if type(t) ~= 'table' then return end
    local n = t.n or #t
    return unpack(t, 1, n)
end

local function shallowCopy(t)
    if type(t) ~= 'table' then return {} end
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    return o
end

local function scanRet(suiteName, apiKey, ctx, ...)
    if Scanner and Scanner.ScanReturns then
        Scanner:ScanReturns(suiteName, apiKey, ctx, ...)
    end
end

local function callFunc(suiteName, apiKey, ctx, fn)
    local res = pack(pcall(fn))
    local ok = res[1]
    if ok then
        local out = { n = res.n - 1 }
        for i = 1, out.n do
            out[i] = res[i + 1]
        end
        return true, out
    end

    local err = res[2]
    local core = _G.RothSecretTesterCore
    if core and core.Doctor and core.Doctor.Report then
        core.Doctor:Report(err, 'tester', 'probe', {
            suite = suiteName,
            api = apiKey,
            case = type(ctx) == 'table' and ctx.case or nil,
            label = type(ctx) == 'table' and ctx.label or nil,
        })
    end
    if core and (core.Error or core.Log or core.Line) then
        if core.Error then
            core:Error('TESTER', string.format('[suite:%s] call error api=%s case=%s err=%s',
            tostring(suiteName), tostring(apiKey), tostring(type(ctx) == 'table' and ctx.case or ''), tostring(err)))
        elseif core.Line then
            core:Line(string.format('[suite:%s] call error api=%s case=%s err=%s',
                tostring(suiteName), tostring(apiKey), tostring(type(ctx) == 'table' and ctx.case or ''), tostring(err)))
        end
    end
    return false, err
end

-- --- APIDocumentation helpers -------------------------------------------------

local function ensureDocs()
    local load = (_G.C_AddOns and C_AddOns.LoadAddOn) or _G.LoadAddOn
    local isLoaded = (_G.C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded

    if _G.APIDocumentation and (_G.APIDocumentation.systems or _G.APIDocumentation.functions) then
        return _G.APIDocumentation
    end

    if load and isLoaded and not isLoaded("Blizzard_APIDocumentationGenerated") then
        if InCombatLockdown and InCombatLockdown() then
            return _G.APIDocumentation
        end
        pcall(load, "Blizzard_APIDocumentationGenerated")
    end

    return _G.APIDocumentation
end

local function getLen(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in ipairs(t) do n = n + 1 end
    return n
end

local function docHasSecretHints(funcInfo)
    if type(funcInfo) ~= "table" then return false end

    -- Some builds annotate at the function-level
    if funcInfo.SecretReturnsForAspect or funcInfo.SecretArgumentsForAspect or funcInfo.MayReturnSecretValues then
        return true
    end

    local returns = funcInfo.Returns or funcInfo.returns
    if type(returns) == "table" then
        for _, r in ipairs(returns) do
            if type(r) == "table" then
                if r.SecretReturnsForAspect or r.IsSecretReturn or r.MayBeSecret or r.MayReturnSecretValues then
                    return true
                end
            end
        end
    end

    return false
end

local function iterDocFunctions(docs)
    local out = {}

    if type(docs) ~= "table" then return out end

    -- Modern format: APIDocumentation.systems = { { Name = "C_Spell", Functions = { ... } }, ... }
    if type(docs.systems) == "table" then
        for _, sys in ipairs(docs.systems) do
            local ns = ""
            if type(sys) == "table" then
                ns = sys.Name or sys.name or sys.Namespace or sys.namespace or ""
                local funcs = sys.Functions or sys.functions
                if type(funcs) == "table" then
                    for _, f in ipairs(funcs) do
                        if type(f) == "table" and (f.Name or f.name) then
                            local fn = f.Name or f.name
                            local key = (ns ~= "" and (ns .. "." .. fn) or fn)
                            out[#out + 1] = {
                                key = key,
                                ns = ns,
                                name = fn,
                                argsN = getLen(f.Arguments or f.arguments),
                                retsN = getLen(f.Returns or f.returns),
                                docSecret = docHasSecretHints(f),
                                raw = f,
                            }
                        end
                    end
                end
            end
        end
        return out
    end

    -- Fallback: docs.functions = { { fullName = "C_Spell.GetSpellCooldown", ... }, ... }
    if type(docs.functions) == "table" then
        for _, f in ipairs(docs.functions) do
            if type(f) == "table" then
                local key = f.fullName or f.fullname or f.Name or f.name
                if type(key) == "string" and key ~= "" then
                    out[#out + 1] = {
                        key = key,
                        ns = key:match("^(.*)%.%w+$") or "",
                        name = key:match("^(.*)%.(%w+)$") and key:match("^(.*)%.(%w+)$") or key,
                        argsN = getLen(f.arguments or f.Arguments),
                        retsN = getLen(f.returns or f.Returns),
                        docSecret = docHasSecretHints(f),
                        raw = f,
                    }
                end
            end
        end
    end

    return out
end

local function resolveFunctionByPath(path)
    if type(path) ~= "string" or path == "" then return nil end
    local cur = _G
    for part in path:gmatch("[^%.]+") do
        cur = cur and cur[part] or nil
        if not cur then return nil end
    end
    if type(cur) ~= "function" then return nil end
    return cur
end

-- --- Suite: catalog (docs only) ----------------------------------------------

local Catalog = {}

function Catalog:Run()
    local core = _G.RothSecretTesterCore
    if not core then return end

    local docs = ensureDocs()
    if not docs then
        core:Line("[catalog] APIDocumentation not available")
        return
    end

    local funcs = iterDocFunctions(docs)
    local total = #funcs
    local secretCapable = 0
    local call0 = 0

    for _, f in ipairs(funcs) do
        if f.docSecret then secretCapable = secretCapable + 1 end
        if f.argsN == 0 then call0 = call0 + 1 end
    end

    local db = core:GetDB()
    db.catalog = db.catalog or { version = 1, functions = {}, meta = { updated = 0 } }
    db.catalog.functions = funcs
    db.catalog.meta.updated = now()

    core:Line(("[catalog] docs funcs=%d secretHint=%d call0=%d"):format(total, secretCapable, call0))
end

Suites.catalog = Catalog

-- --- Suite: catalog_call0 (attempt zero-arg calls) ----------------------------

local CatalogCall0 = {}

function CatalogCall0:Run()
    local core = _G.RothSecretTesterCore
    if not core then return end

    local docs = ensureDocs()
    if not docs then
        core:Line("[catalog_call0] APIDocumentation not available")
        return
    end

    local funcs = iterDocFunctions(docs)
    if #funcs == 0 then
        core:Line("[catalog_call0] no functions discovered in docs")
        return
    end

    -- Run docSecret+zero-arg first, then the rest of zero-arg
    local primary, secondary = {}, {}
    for _, f in ipairs(funcs) do
        if f.argsN == 0 then
            if f.docSecret then
                primary[#primary + 1] = f
            else
                secondary[#secondary + 1] = f
            end
        end
    end

    local maxCalls = (core:GetDB().settings and core:GetDB().settings.maxCatalogCall0) or 75
    local calls = 0
    local ok = 0

    local function doCall(entry)
        local fn = resolveFunctionByPath(entry.key)
        if not fn then return end

        local success, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10 = pcall(fn)
        calls = calls + 1
        if not success then return end
        ok = ok + 1

        local ctx = ctxBase({ case = "call0", api = entry.key })
        Scanner:ScanReturns("catalog_call0", entry.key, ctx, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10)
    end

    for _, f in ipairs(primary) do
        if calls >= maxCalls then break end
        doCall(f)
    end

    for _, f in ipairs(secondary) do
        if calls >= maxCalls then break end
        doCall(f)
    end

    core:Line(("[catalog_call0] calls=%d ok=%d max=%d (docs=%d)"):format(calls, ok, maxCalls, #funcs))
end

Suites.catalog_call0 = CatalogCall0

-- Units
local Units = {}
Suites.units = Units

function Units:ProbeUnit(unit, mode)
    local core = _G.RothSecretTesterCore
    if not core then return end
    if UnitExists and not UnitExists(unit) then return end

    local ctx = ctxBase({ unit = unit, mode = mode })

    Tester:StatInc("calls", 1)
    local ok1, h = pcall(UnitHealth, unit)
    Tester:StatInc("calls", 1)
    local ok2, hm = pcall(UnitHealthMax, unit)
    if ok1 and ok2 then
        Scanner:ScanReturns("units", "UnitHealth", ctx, h, hm)
    end

    Tester:StatInc("calls", 1)
    local ok3, p = pcall(UnitPower, unit)
    Tester:StatInc("calls", 1)
    local ok4, pm = pcall(UnitPowerMax, unit)
    if ok3 and ok4 then
        Scanner:ScanReturns("units", "UnitPower", ctx, p, pm)
    end

    if UnitPowerType then
        Tester:StatInc("calls", 1)
        local ok5, a, b = pcall(UnitPowerType, unit)
        if ok5 then
            Scanner:ScanReturns("units", "UnitPowerType", ctx, a, b)
        end
    end
end

function Units:Run()
    local core = _G.RothSecretTesterCore
    if not core then return end
    core:Line("[units] probing player/target")
    self:ProbeUnit("player", "RUN")
    self:ProbeUnit("target", "RUN")
end

-- Casting
local Casting = {}
Suites.casting = Casting

function Casting:ProbeUnit(unit, mode)
    if UnitExists and not UnitExists(unit) then return end
    local ctx = ctxBase({ unit = unit, mode = mode })

    if UnitCastingInfo then
        Tester:StatInc("calls", 1)
        local ok, a, b, c, d, e, f, g, h = pcall(UnitCastingInfo, unit)
        if ok then
            Scanner:ScanReturns("casting", "UnitCastingInfo", ctx, a, b, c, d, e, f, g, h)
        end
    end
    if UnitChannelInfo then
        Tester:StatInc("calls", 1)
        local ok, a, b, c, d, e, f, g, h = pcall(UnitChannelInfo, unit)
        if ok then
            Scanner:ScanReturns("casting", "UnitChannelInfo", ctx, a, b, c, d, e, f, g, h)
        end
    end
end

function Casting:Run()
    local core = _G.RothSecretTesterCore
    if not core then return end
    core:Line("[casting] probing player/target")
    self:ProbeUnit("player", "RUN")
    self:ProbeUnit("target", "RUN")
end



-- Auras
local Auras = {}
Suites.auras = Auras

local function scanUnitAurasSafe(unit, filter, maxN)
    local res = {}

    -- Prefer C_UnitAuras in modern Retail; avoid AuraUtil helpers because they may
    -- internally unpack packed aura data and can error when the payload is a secret value.
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, maxN do
            local ok, auraData = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
            if not ok then
                res[#res + 1] = { __error = auraData }
                break
            end
            if auraData == nil then
                break
            end
            -- Store as-is; Scanner will detect secret values without indexing into auraData.
            res[#res + 1] = auraData
        end
        return res
    end

    -- Legacy fallback
    if UnitAura then
        for i = 1, maxN do
                        Tester:StatInc("calls", 1)
            local ok, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 = pcall(UnitAura, unit, i, filter)
            if not ok then
                res[#res + 1] = { __error = a1 }
                break
            end
            if not a1 then break end
            res[#res + 1] = { a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 }
        end
    end

    return res
end

function Auras:ProbeUnit(unit, mode)
    local core = _G.RothSecretTesterCore
    if not core then return end
    if UnitExists and not UnitExists(unit) then return end

    local maxN = 40

    local helpful = scanUnitAurasSafe(unit, "HELPFUL", maxN)
    local ctxH = ctxBase({ unit = unit, filter = "HELPFUL", mode = mode, case = unit .. ":HELPFUL" })
    Scanner:ScanReturns("auras", "Auras:" .. unit .. ":HELPFUL", ctxH, helpful)

    local harmful = scanUnitAurasSafe(unit, "HARMFUL", maxN)
    local ctxD = ctxBase({ unit = unit, filter = "HARMFUL", mode = mode, case = unit .. ":HARMFUL" })
    Scanner:ScanReturns("auras", "Auras:" .. unit .. ":HARMFUL", ctxD, harmful)
end

function Auras:Run()
    local core = _G.RothSecretTesterCore
    if not core then return end
    core:Line("[auras] probing player/target")
    self:ProbeUnit("player", "RUN")
    self:ProbeUnit("target", "RUN")
end

-- Cooldowns
local Cooldowns = {}
Suites.cooldowns = Cooldowns

local function probeSpellCooldown(spellID, label)
    local ctx = ctxBase({ spellId = spellID, case = label, label = label })
    if C_Spell and C_Spell.GetSpellCooldown then
        Tester:StatInc("calls", 1)
        local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
        if ok then
            Scanner:ScanReturns("cooldowns", "C_Spell.GetSpellCooldown(" .. label .. ")", ctx, info)
        end
    elseif GetSpellCooldown then
        Tester:StatInc("calls", 1)
        local ok, start, dur, enabled, modRate = pcall(GetSpellCooldown, spellID)
        if ok then
            Scanner:ScanReturns("cooldowns", "GetSpellCooldown(" .. label .. ")", ctx, start, dur, enabled, modRate)
        end
    end
end

local function probeInventoryCooldown(slot, label)
    local ctx = ctxBase({ slot = slot, case = label, label = label })
    if GetInventoryItemID and GetInventoryItemCooldown then
        local id = GetInventoryItemID("player", slot)
        if id then
            Tester:StatInc("calls", 1)
            local ok, start, dur, enable = pcall(GetInventoryItemCooldown, "player", slot)
            if ok then
                Scanner:ScanReturns("cooldowns", "GetInventoryItemCooldown(" .. label .. ")", ctx, id, start, dur, enable)
            end
        end
    end
end

function Cooldowns:Run()
    local core = _G.RothSecretTesterCore
    if not core then return end
    core:Line("[cooldowns] probing gcd + trinkets + mainhand")
    probeSpellCooldown(61304, "GCD")
    probeInventoryCooldown(13, "trinket13")
    probeInventoryCooldown(14, "trinket14")
    probeInventoryCooldown(16, "mainhand16")
end

-- UI suite
local UISuite = {}
Suites.ui = UISuite

function UISuite:Run()
    local core = _G.RothSecretTesterCore
    if not core then return end
    core:Line("[ui] probing frames for secret aspects/anchors")

    local frames = {
        { name = "PlayerFrame", frame = _G.PlayerFrame },
        { name = "TargetFrame", frame = _G.TargetFrame },
        { name = "UIParent", frame = _G.UIParent },
    }

    for _, f in ipairs(frames) do
        if f.frame then
            Scanner:ScanFrameSecrets("ui", "frame", f.frame, f.name, ctxBase({ frame = f.name }))
        end
    end

    local sb = CreateFrame("StatusBar", nil, UIParent)
    sb:SetSize(120, 10)
    sb:SetPoint("CENTER", 0, -200)
    sb:SetMinMaxValues(0, 1)
    sb:Show()

    local ok, val = pcall(function()
        local h = UnitHealth("target") or 0
        local hm = UnitHealthMax("target") or 1
        return hm > 0 and (h / hm) or 0
    end)
    if ok then
        local ok2 = pcall(function() sb:SetValue(val) end)
        if ok2 then
            Scanner:ScanFrameSecrets("ui", "StatusBar:SetValue", sb, "LocalStatusBar", ctxBase({ note = "SetValue(UnitHealth(target)/Max)" }))
        end
    end
end


-- DK suite -------------------------------------------------------------
-- Goal: DK-focused probing of common addon-facing APIs to learn which return
-- paths are "secret" vs safe. This complements the generic suites by:
--  - covering DK resources (runes/runic power)
--  - adding a curated DK spell set (baseline + per-spec), supplemented by
--    learned spells from the spellbook (capped)
-- Output: observations are deduplicated by the Scanner/DB layer; this suite
-- intentionally avoids logging raw values.

local DK = {
    title = "DK (auto by current spec)",
    desc  = "Probes DK-facing APIs + short aura diff-watch; auto-selects list by current specialization.",
}
Suites.dk = DK

-- Curated spell ids (best-effort; suite also supplements via spellbook).
-- Notes:
--  * Spec IDs are expected to be 250/251/252 (Blood/Frost/Unholy).
--  * Unknown/unlearned spell IDs are skipped at runtime.
local DK_SPELLS_COMMON = {
    61304,  -- GCD (Global Cooldown)
    6603,   -- Auto Attack

    49576,  -- Death Grip
    47528,  -- Mind Freeze
    45524,  -- Chains of Ice
    43265,  -- Death and Decay
    49998,  -- Death Strike
    47541,  -- Death Coil

    48707,  -- Anti-Magic Shell
    48792,  -- Icebound Fortitude
    49039,  -- Lichborne
    46584,  -- Raise Dead
    56222,  -- Dark Command
    108199, -- Gorefiend's Grasp
    212552, -- Wraith Walk
    48743,  -- Death Pact

    439843, -- Reaper's Mark (hero talent; target debuff)
    439851, -- Wave of Souls (hero talent)
    441378, -- Exterminate (hero talent)
    444347, -- Death Charge (hero talent)
    433895, -- Vampiric Strike (hero talent)
    433925, -- Essence of the Blood Queen (hero talent)
}

local DK_SPELLS_BLOOD = {
    195182, -- Marrowrend
    206930, -- Heart Strike
    50842,  -- Blood Boil
    55233,  -- Vampiric Blood
    49028,  -- Dancing Rune Weapon
    194844, -- Bonestorm
    219809, -- Tombstone
    194679, -- Rune Tap
    195292, -- Death's Caress
}

local DK_SPELLS_FROST = {
    49020, -- Obliterate
    49184, -- Howling Blast
    49143, -- Frost Strike
    196770, -- Remorseless Winter
    51271, -- Pillar of Frost
    47568, -- Empower Rune Weapon
    279302, -- Frostwyrm's Fury
    152279, -- Breath of Sindragosa
    194913, -- Glacial Advance
    456230, -- Arctic Assault
    207057, -- Shattering Blade
    207142, -- Avalanche
    207256, -- Obliteration
    53343, -- Rune of Razorice (runeforge)
    51128, -- Killing Machine (passive)
    59057, -- Rime (passive/proc)
}


local DK_SPELLS_UNHOLY = {
    55090, -- Scourge Strike
    85948, -- Festering Strike
    455397, -- Festering Scythe
    1247378, -- Putrefy
    77575, -- Outbreak
    63560, -- Dark Transformation
    49206, -- Summon Gargoyle
    42650, -- Army of the Dead
    207317, -- Epidemic
    115989, -- Unholy Blight
    49530, -- Sudden Doom (passive/proc)
    191587, -- Virulent Plague (disease/debuff)
}


local function dkGetSpecIdName()
    if type(GetSpecialization) ~= "function" or type(GetSpecializationInfo) ~= "function" then
        return 0, "unknown"
    end
    local spec = GetSpecialization()
    if not spec or spec == 0 then
        return 0, "unknown"
    end
    local id, name = GetSpecializationInfo(spec)
    return id or 0, name or "unknown"
end

local function dkAppendUnique(out, seen, list, maxN)
    if not list then return end
    for i = 1, #list do
        local v = list[i]
        if v and not seen[v] then
            seen[v] = true
            out[#out + 1] = v
            if maxN and #out >= maxN then
                return true
            end
        end
    end
    return false
end

local function dkGatherSpellbookSpellIDs(maxN)
    local out, seen = {}, {}

    if type(GetNumSpellTabs) ~= "function" or type(GetSpellTabInfo) ~= "function" or type(GetSpellBookItemInfo) ~= "function" then
        return out
    end

    local bookType = _G.BOOKTYPE_SPELL or "spell"

    local okTabs, numTabs = pcall(GetNumSpellTabs)
    if not okTabs or not numTabs then
        return out
    end

    for tab = 1, numTabs do
        local okTab, _, _, offset, numSpells = pcall(GetSpellTabInfo, tab)
        if okTab and offset and numSpells then
            for idx = offset + 1, offset + numSpells do
                local okItem, itemType, itemId = pcall(GetSpellBookItemInfo, idx, bookType)
                if okItem and itemId and (itemType == "SPELL" or itemType == "SPELLP") then
                    local sid = itemId
                    local passiveOk = true
                    if type(IsPassiveSpell) == "function" then
                        passiveOk = not IsPassiveSpell(sid)
                    end
                    if passiveOk and not seen[sid] then
                        seen[sid] = true
                        out[#out + 1] = sid
                        if maxN and #out >= maxN then
                            return out
                        end
                    end
                end
            end
        end
    end

    return out
end

local function dkProbeCall(suiteName, apiKey, ctx, fn)
    local ok, rets = callFunc(suiteName, apiKey, ctx, fn)
    if ok then
        scanRet(suiteName, apiKey, ctx, unpackTbl(rets))
    end
    return ok
end

local function dkSpellLabel(spellId)
    local name
    if type(GetSpellInfo) == "function" then
        name = GetSpellInfo(spellId)
    end
    if not name and _G.C_Spell and type(C_Spell.GetSpellInfo) == "function" then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
        if ok and info and type(info) == "table" then
            name = info.name
        end
    end
    if name then
        return string.format("%s(%d)", name, spellId)
    end
    return string.format("spell(%d)", spellId)
end

local function dkProbeSpellAPIs(suiteName, spellId, ctx)
    local label = dkSpellLabel(spellId)
    local caseKey = string.format("spell:%d", spellId)

    local c = shallowCopy(ctx)
    c.case = caseKey
    c.label = label
    c.spellId = spellId

    if _G.C_Spell and type(C_Spell.GetSpellInfo) == "function" then
        dkProbeCall(suiteName, "C_Spell.GetSpellInfo(" .. label .. ")", c, function() return C_Spell.GetSpellInfo(spellId) end)
    elseif type(GetSpellInfo) == "function" then
        dkProbeCall(suiteName, "GetSpellInfo(" .. label .. ")", c, function() return GetSpellInfo(spellId) end)
    end

    if _G.C_Spell and type(C_Spell.GetSpellCooldown) == "function" then
        dkProbeCall(suiteName, "C_Spell.GetSpellCooldown(" .. label .. ")", c, function() return C_Spell.GetSpellCooldown(spellId) end)
    elseif type(GetSpellCooldown) == "function" then
        dkProbeCall(suiteName, "GetSpellCooldown(" .. label .. ")", c, function() return GetSpellCooldown(spellId) end)
    end

    if _G.C_Spell and type(C_Spell.GetSpellCharges) == "function" then
        dkProbeCall(suiteName, "C_Spell.GetSpellCharges(" .. label .. ")", c, function() return C_Spell.GetSpellCharges(spellId) end)
    elseif type(GetSpellCharges) == "function" then
        dkProbeCall(suiteName, "GetSpellCharges(" .. label .. ")", c, function() return GetSpellCharges(spellId) end)
    end

    if type(GetSpellPowerCost) == "function" then
        dkProbeCall(suiteName, "GetSpellPowerCost(" .. label .. ")", c, function() return GetSpellPowerCost(spellId) end)
    end

    if type(IsUsableSpell) == "function" then
        dkProbeCall(suiteName, "IsUsableSpell(" .. label .. ")", c, function() return IsUsableSpell(spellId) end)
    end

    if type(IsSpellInRange) == "function" then
        dkProbeCall(suiteName, "IsSpellInRange(" .. label .. ",target)", c, function() return IsSpellInRange(spellId, "target") end)
    elseif _G.C_Spell and type(C_Spell.IsSpellInRange) == "function" then
        dkProbeCall(suiteName, "C_Spell.IsSpellInRange(" .. label .. ",target)", c, function() return C_Spell.IsSpellInRange(spellId, "target") end)
    end
end

function DK:Run(opts)
    local t0 = debugprofilestop()


    opts = type(opts) == "table" and opts or {}
    local suiteName = tostring(opts.suiteName or "dk")
    local expectedSpecId = tonumber(opts.expectedSpecId or 0) or 0

    local core = _G.RothSecretTesterCore
    if not core then return end
    local _, class = UnitClass("player")
    if class ~= "DEATHKNIGHT" then
        core:Line(string.format("[%s] skipped: class=%s", suiteName, tostring(class)))
        return
    end

    local specId, specName = dkGetSpecIdName()
    if expectedSpecId > 0 and specId ~= expectedSpecId then
        core:Line(string.format("[%s] skipped: spec mismatch (expected=%d got=%d %s)", suiteName, expectedSpecId, specId, tostring(specName)))
        return
    end
    local ctx = ctxBase({ note = "dk" })
    ctx.specId = specId
    ctx.specName = specName

    core:Line(string.format("[%s] probing DK (spec=%s, id=%d)", suiteName, tostring(specName), tonumber(specId or 0)))

    -- Baseline combat-facing APIs
    if type(UnitAttackSpeed) == "function" then
        dkProbeCall(suiteName, "UnitAttackSpeed(player)", ctx, function() return UnitAttackSpeed("player") end)
    end
    if type(UnitDamage) == "function" then
        dkProbeCall(suiteName, "UnitDamage(player)", ctx, function() return UnitDamage("player") end)
    end

	    -- Blood DK priorities (also useful for Frost/Unholy tanking/solo): threat + mitigation.
	    -- These probes are intentionally "read-only" and wrapped in pcall inside dkProbeCall.
	    if UnitExists and UnitExists("target") then
	        if type(UnitThreatSituation) == "function" then
	            local c = shallowCopy(ctx)
	            c.case = "threat:status"
	            c.label = "UnitThreatSituation(player,target)"
	            dkProbeCall(suiteName, "UnitThreatSituation(player,target)", c, function() return UnitThreatSituation("player", "target") end)
	        end
	        if type(UnitDetailedThreatSituation) == "function" then
	            local c = shallowCopy(ctx)
	            c.case = "threat:detailed"
	            c.label = "UnitDetailedThreatSituation(player,target)"
	            dkProbeCall(suiteName, "UnitDetailedThreatSituation(player,target)", c, function() return UnitDetailedThreatSituation("player", "target") end)
	        end
	    end
	    if type(UnitArmor) == "function" then
	        local c = shallowCopy(ctx)
	        c.case = "mitigation:armor"
	        c.label = "UnitArmor(player)"
	        dkProbeCall(suiteName, "UnitArmor(player)", c, function() return UnitArmor("player") end)
	    end
	    if type(GetParryChance) == "function" then
	        local c = shallowCopy(ctx)
	        c.case = "mitigation:parry"
	        c.label = "GetParryChance()"
	        dkProbeCall(suiteName, "GetParryChance()", c, function() return GetParryChance() end)
	    end
	    if type(GetDodgeChance) == "function" then
	        local c = shallowCopy(ctx)
	        c.case = "mitigation:dodge"
	        c.label = "GetDodgeChance()"
	        dkProbeCall(suiteName, "GetDodgeChance()", c, function() return GetDodgeChance() end)
	    end
	    if type(UnitGetTotalAbsorbs) == "function" then
	        local c = shallowCopy(ctx)
	        c.case = "mitigation:absorbs"
	        c.label = "UnitGetTotalAbsorbs(player)"
	        dkProbeCall(suiteName, "UnitGetTotalAbsorbs(player)", c, function() return UnitGetTotalAbsorbs("player") end)
	    end

    -- Runes (if available)
    if type(GetRuneCooldown) == "function" then
        for i = 1, 6 do
            local c = shallowCopy(ctx)
            c.case = "rune:" .. i
            c.label = "rune(" .. i .. ")"
            dkProbeCall(suiteName, "GetRuneCooldown(" .. i .. ")", c, function() return GetRuneCooldown(i) end)
        end
    end

    -- Runic power
    if type(UnitPower) == "function" and type(UnitPowerMax) == "function" then
        local rp = 6
        if _G.Enum and Enum.PowerType and Enum.PowerType.RunicPower then
            rp = Enum.PowerType.RunicPower
        end
        local c = shallowCopy(ctx)
        c.case = "power:runic"
        c.label = "RunicPower"
        dkProbeCall(suiteName, "UnitPower(player,RunicPower)", c, function() return UnitPower("player", rp) end)
        dkProbeCall(suiteName, "UnitPowerMax(player,RunicPower)", c, function() return UnitPowerMax("player", rp) end)
    end

    -- Spell set: curated list + spellbook supplement (capped)
    local spells, seen = {}, {}
    dkAppendUnique(spells, seen, DK_SPELLS_COMMON)

    if specId == 250 then
        dkAppendUnique(spells, seen, DK_SPELLS_BLOOD)
    elseif specId == 251 then
        dkAppendUnique(spells, seen, DK_SPELLS_FROST)
    elseif specId == 252 then
        dkAppendUnique(spells, seen, DK_SPELLS_UNHOLY)
    end

    -- Also include a small supplement of learned spellbook spells to catch
    -- spec/talent variations without turning the suite into a full dump.
    local supplement = dkGatherSpellbookSpellIDs(60)
    dkAppendUnique(spells, seen, supplement, 90)

    -- Probe per-spell APIs
    local probed = 0
    for i = 1, #spells do
        local sid = spells[i]
        if sid and sid > 0 then
            -- Skip missing/unlearned spells to keep the dataset clean.
            local known = true
            if type(IsSpellKnown) == "function" then
                known = IsSpellKnown(sid)
            elseif type(GetSpellInfo) == "function" then
                known = (GetSpellInfo(sid) ~= nil)
            end

            if known then
                dkProbeSpellAPIs(suiteName, sid, ctx)
                probed = probed + 1
            end
        end
    end


    -- Optional: short aura diff watch.
    -- Purpose: discover new/renamed buffs/debuffs by spellId (without relying on aura.name text),
    -- and capture full auraData tables for SecretValue detection.
    if C_UnitAuras and type(C_UnitAuras.GetAuraDataByIndex) == "function"
        and C_Timer and type(C_Timer.After) == "function"
        and type(CreateFrame) == "function"
    then
        local watchSecs = 15
        core:Line(string.format("[%s] aura-watch: %ds (player+target)", suiteName, watchSecs))

        local f = CreateFrame("Frame")
        local pending = {}
        local prev = {}

        local function joinIds(ids)
            local t = {}
            for i = 1, #ids do t[i] = tostring(ids[i]) end
            return table.concat(t, ",")
        end

        local function snapshot(unit, filter)
            local set = {}
            for i = 1, 80 do
                local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
                if not aura then break end
                local sid = aura.spellId
	                if type(sid) == "number" then
	                    -- spellId may still be a SecretValue "number"; avoid using it as a table key.
	                    local okKey = pcall(function() set[sid] = true end)
	                    if not okKey then
	                        set["#idx:" .. tostring(i)] = true
	                    end
	                else
	                    set["#idx:" .. tostring(i)] = true
	                end
            end
            return set
        end

        local function diff(oldSet, newSet)
            oldSet = oldSet or {}
            local added, removed = {}, {}
            for sid in pairs(newSet) do
                if not oldSet[sid] then added[#added + 1] = sid end
            end
            for sid in pairs(oldSet) do
                if not newSet[sid] then removed[#removed + 1] = sid end
            end
            return added, removed
        end

        local function findAura(unit, filter, sid)
            for i = 1, 80 do
                local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)
                if not aura then break end
	                local okEq, eq = pcall(function() return aura.spellId == sid end)
	                if okEq and eq then return aura end
            end
        end

        local function scanAdded(unit, filter, ids)
            for _, sid in ipairs(ids) do
	                if type(sid) == "number" then
	                    local aura = findAura(unit, filter, sid)
	                    if aura then
	                        local c = shallowCopy(ctx)
	                        c.case = string.format("aura:%s:%s:%d", unit, filter, sid)
	                        c.unit = unit
	                        c.filter = filter
	                        c.spellId = sid
	                        scanRet(suiteName, "C_UnitAuras.GetAuraDataByIndex(" .. unit .. "," .. filter .. "," .. tostring(sid) .. ")", c, aura)
	                    end
	                end
            end
        end

        prev.playerHelpful = snapshot("player", "HELPFUL")
        prev.playerHarmful = snapshot("player", "HARMFUL")
        prev.targetHelpful = snapshot("target", "HELPFUL")
        prev.targetHarmful = snapshot("target", "HARMFUL")

        f:RegisterEvent("UNIT_AURA")
        f:SetScript("OnEvent", function(_, _, unit)
            if unit ~= "player" and unit ~= "target" then return end
            if pending[unit] then return end
            pending[unit] = true
            C_Timer.After(0, function()
                pending[unit] = nil
                if unit == "player" then
                    local nh = snapshot("player", "HELPFUL")
                    local nd = snapshot("player", "HARMFUL")
                    local addH, remH = diff(prev.playerHelpful, nh)
                    local addD, remD = diff(prev.playerHarmful, nd)
                    prev.playerHelpful, prev.playerHarmful = nh, nd

                    if #addH > 0 then core:Line(string.format("[%s][aura+][player][HELPFUL] %s", suiteName, joinIds(addH))); scanAdded("player", "HELPFUL", addH) end
                    if #remH > 0 then core:Line(string.format("[%s][aura-][player][HELPFUL] %s", suiteName, joinIds(remH))) end
                    if #addD > 0 then core:Line(string.format("[%s][aura+][player][HARMFUL] %s", suiteName, joinIds(addD))); scanAdded("player", "HARMFUL", addD) end
                    if #remD > 0 then core:Line(string.format("[%s][aura-][player][HARMFUL] %s", suiteName, joinIds(remD))) end
                else
                    local nh = snapshot("target", "HELPFUL")
                    local nd = snapshot("target", "HARMFUL")
                    local addH, remH = diff(prev.targetHelpful, nh)
                    local addD, remD = diff(prev.targetHarmful, nd)
                    prev.targetHelpful, prev.targetHarmful = nh, nd

                    if #addH > 0 then core:Line(string.format("[%s][aura+][target][HELPFUL] %s", suiteName, joinIds(addH))); scanAdded("target", "HELPFUL", addH) end
                    if #remH > 0 then core:Line(string.format("[%s][aura-][target][HELPFUL] %s", suiteName, joinIds(remH))) end
                    if #addD > 0 then core:Line(string.format("[%s][aura+][target][HARMFUL] %s", suiteName, joinIds(addD))); scanAdded("target", "HARMFUL", addD) end
                    if #remD > 0 then core:Line(string.format("[%s][aura-][target][HARMFUL] %s", suiteName, joinIds(remD))) end
                end
            end)
        end)

        C_Timer.After(watchSecs, function()
            if f and f.UnregisterAllEvents then
                f:UnregisterAllEvents()
                f:SetScript("OnEvent", nil)
            end
            core:Line(string.format("[%s] aura-watch: done", suiteName))
        end)
    end

    local dt = (debugprofilestop() - t0) / 1000
    core:Line(string.format("[suite:%s] ok=yes spells=%d time=%.3fs", suiteName, probed, dt))
end

-- DK spec helpers (explicit suite ids for clean datasets)
local DKBlood = {
    title = "DK - Blood",
    desc  = "Blood-only DK probe (Death Strike/Blood Shield focus). Requires Blood spec.",
}
function DKBlood:Run() DK:Run({ suiteName = "dk_blood", expectedSpecId = 250 }) end
Suites.dk_blood = DKBlood

local DKFrost = {
    title = "DK - Frost",
    desc  = "Frost-only DK probe (KM/Pillar/Breath/Razorice focus). Requires Frost spec.",
}
function DKFrost:Run() DK:Run({ suiteName = "dk_frost", expectedSpecId = 251 }) end
Suites.dk_frost = DKFrost

local DKUnholy = {
    title = "DK - Unholy",
    desc  = "Unholy-only DK probe (diseases + pet stack counters). Requires Unholy spec.",
}
function DKUnholy:Run() DK:Run({ suiteName = "dk_unholy", expectedSpecId = 252 }) end
Suites.dk_unholy = DKUnholy



-- Lists suite (data packs)
local Lists = {}
Suites.lists = Lists

local function iterPackLists(packs)
    local out = {}
    for packName, pack in pairs(packs) do
        if type(pack) == "table" and type(pack.lists) == "table" then
            out[#out + 1] = { name = packName, pack = pack }
        end
    end
    return out
end

function Lists:Run(args)
    local core = _G.RothSecretTesterCore
    if not core then return end

    local packs = core:GetListPacks()
    local list = iterPackLists(packs)

    -- Optional filter: run only a single pack (UI uses this for Pack entries).
    local only = (type(args) == "table" and args.pack) and tostring(args.pack) or nil
    if only and only ~= "" then
        local filtered = {}
        for i = 1, #list do
            if list[i].name == only then filtered[#filtered + 1] = list[i] end
        end
        list = filtered
    end
    if #list == 0 then
        core:Line("[lists] no list packs registered. Use /rst pack RothSecretTester_Pack_Default")
        return
    end

    core:Line(("[lists] probing packs=%d"):format(#list))

    -- Build lookups
    local spellEntries = {}
    local auraIdSet = {}
    local itemSlots = {}

    for _, entry in ipairs(list) do
        local p = entry.pack
        if type(p.lists.spells) == "table" then
            for _, s in ipairs(p.lists.spells) do
                if type(s) == "table" and type(s.id) == "number" then
                    spellEntries[#spellEntries + 1] = { id = s.id, label = (s.label or tostring(s.id)), pack = entry.name }
                end
            end
        end
        if type(p.lists.auraIDs) == "table" then
            for _, a in ipairs(p.lists.auraIDs) do
                if type(a) == "table" and type(a.id) == "number" then
                    auraIdSet[a.id] = a.label or tostring(a.id)
                end
            end
        end
        if type(p.lists.items) == "table" then
            for _, it in ipairs(p.lists.items) do
                if type(it) == "table" and type(it.slot) == "number" then
                    itemSlots[#itemSlots + 1] = { slot = it.slot, label = it.label or ("slot" .. tostring(it.slot)), pack = entry.name }
                end
            end
        end
    end

    -- Spells: probe spell APIs (info/cooldown/charges/cost/usable/range)
    local function probeSpell(suiteName, e)
        local sid = e.id
        local label = e.label or tostring(sid)

        local ctx = ctxBase({ pack = e.pack, listName = e.pack, spellId = sid, label = label })
        ctx.case = string.format("spell:%d", sid)

        -- SpellInfo
        if _G.C_Spell and type(C_Spell.GetSpellInfo) == "function" then
            local ok, info = pcall(C_Spell.GetSpellInfo, sid)
            if ok then Scanner:ScanReturns(suiteName, "C_Spell.GetSpellInfo(" .. label .. ")", ctx, info) end
        elseif type(GetSpellInfo) == "function" then
            local ok, name, rank, icon = pcall(GetSpellInfo, sid)
            if ok then Scanner:ScanReturns(suiteName, "GetSpellInfo(" .. label .. ")", ctx, name, rank, icon) end
        end

        -- Cooldown
        if _G.C_Spell and type(C_Spell.GetSpellCooldown) == "function" then
            local ok, info = pcall(C_Spell.GetSpellCooldown, sid)
            if ok then Scanner:ScanReturns(suiteName, "C_Spell.GetSpellCooldown(" .. label .. ")", ctx, info) end
        elseif type(GetSpellCooldown) == "function" then
            local ok, start, dur, enabled, modRate = pcall(GetSpellCooldown, sid)
            if ok then Scanner:ScanReturns(suiteName, "GetSpellCooldown(" .. label .. ")", ctx, start, dur, enabled, modRate) end
        end

        -- Charges
        if _G.C_Spell and type(C_Spell.GetSpellCharges) == "function" then
            local ok, info = pcall(C_Spell.GetSpellCharges, sid)
            if ok then Scanner:ScanReturns(suiteName, "C_Spell.GetSpellCharges(" .. label .. ")", ctx, info) end
        elseif type(GetSpellCharges) == "function" then
            local ok, cur, maxc, start, dur, modRate = pcall(GetSpellCharges, sid)
            if ok then Scanner:ScanReturns(suiteName, "GetSpellCharges(" .. label .. ")", ctx, cur, maxc, start, dur, modRate) end
        end

        -- Power cost
        if type(GetSpellPowerCost) == "function" then
            local ok, cost = pcall(GetSpellPowerCost, sid)
            if ok then Scanner:ScanReturns(suiteName, "GetSpellPowerCost(" .. label .. ")", ctx, cost) end
        end

        -- Usable
        if type(IsUsableSpell) == "function" then
            local ok, usable, nomana = pcall(IsUsableSpell, sid)
            if ok then Scanner:ScanReturns(suiteName, "IsUsableSpell(" .. label .. ")", ctx, usable, nomana) end
        end

        -- Range (target)
        if type(IsSpellInRange) == "function" then
            local ok, inRange = pcall(IsSpellInRange, sid, "target")
            if ok then Scanner:ScanReturns(suiteName, "IsSpellInRange(" .. label .. ",target)", ctx, inRange) end
        elseif _G.C_Spell and type(C_Spell.IsSpellInRange) == "function" then
            local ok, inRange = pcall(C_Spell.IsSpellInRange, sid, "target")
            if ok then Scanner:ScanReturns(suiteName, "C_Spell.IsSpellInRange(" .. label .. ",target)", ctx, inRange) end
        end
    end

    if #spellEntries > 0 then
        local max = math.min(#spellEntries, 220)
        core:Line(("[lists] spells=%d (testing first %d)"):format(#spellEntries, max))
        for i = 1, max do
            probeSpell("lists", spellEntries[i])
        end
    else
        core:Line("[lists] spells: none")
    end

    -- Items: inventory cooldown queries
    local function probeItemSlot(suiteName, it)
        if not (GetInventoryItemID and GetInventoryItemCooldown) then return end
        local slot = it.slot
        local label = it.label or ("slot" .. tostring(slot))
        local packName = it.pack
        local itemId = GetInventoryItemID("player", slot)
        if not itemId then return end

        local ctx = ctxBase({ pack = packName, listName = packName, slot = slot, itemId = itemId, label = label })
        ctx.case = string.format("itemslot:%d", slot)

        local ok, startT, dur, enable = pcall(GetInventoryItemCooldown, "player", slot)
        if ok then
            Scanner:ScanReturns(suiteName, "GetInventoryItemCooldown(" .. label .. ")", ctx, itemId, startT, dur, enable)
        end
    end

    if #itemSlots > 0 then
        core:Line(("[lists] items=%d"):format(#itemSlots))
        for _, it in ipairs(itemSlots) do
            probeItemSlot("lists", it)
        end
    else
        core:Line("[lists] items: none")
    end

    -- Auras: scan unit aura tables.
    -- Two modes:
    --  - tracked: only IDs listed in pack.lists.auraIDs
    --  - discovery: when running a single pack, also capture auras applied by player/pet
    --    (lets you discover unknown diseases/buffs without depending on aura.name).

    local onlyPack = only  -- from outer scope
    local discoverAuras = (onlyPack and onlyPack ~= "") and true or false

    local function isFromPlayerOrPet(aura)
        if type(aura) ~= "table" then return false end
        if aura.isFromPlayerOrPlayerPet then return true end
        local src = aura.sourceUnit
        if src == "player" or src == "pet" or src == "vehicle" then return true end
        return false
    end

    local function recordDiscoveredAura(spellId, unit, filter)
        local core = _G.RothSecretTesterCore
        if not core then return end
        local db = core:GetDB()
        db.discovered = db.discovered or {}
        local d = db.discovered
        d.packs = d.packs or {}
        local pnode = d.packs[onlyPack] or { auras = {}, meta = { first = time(), last = time() } }
        d.packs[onlyPack] = pnode
        pnode.meta.last = time()

        local a = pnode.auras[spellId]
        if not a then
            a = { count = 0, first = time(), last = time(), unit = unit, filter = filter }
            pnode.auras[spellId] = a
        end
        a.count = (a.count or 0) + 1
        a.last = time()
    end

    local function scanAuraMatches(unit, filter)
        if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
        for i = 1, 60 do
            local ok, auraData = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
            if not ok or auraData == nil then break end
	        local sid = auraData.spellId
	        local sidSafe, trackedLabel = false, nil
	        -- WARNING: auraData.spellId can be a SecretValue "number". Using it as a table index
	        -- triggers a hard error: "table index is secret". Guard all key usage behind pcall.
	        if type(sid) == "number" then
	            local okKey, val = pcall(function() return auraIdSet[sid] end)
	            if okKey then
	                sidSafe = true
	                trackedLabel = val
	            end
	        end
	
	        local discovered = discoverAuras and isFromPlayerOrPet(auraData) and true or false
	        if trackedLabel or discovered then
	            local label
	            if trackedLabel then
	                label = trackedLabel
	            elseif sidSafe then
	                label = "discovered:" .. tostring(sid)
	            else
	                label = "aura#" .. tostring(i)
	            end
	
	            local ctx = ctxBase({
	                pack = onlyPack,
	                listName = onlyPack,
	                unit = unit,
	                filter = filter,
	                auraIndex = i,
	                spellId = sidSafe and sid or nil,
	                label = label,
	            })
	            -- Case key strategy:
	            --  * If spellId is safe => rely on buildCaseKey() (unit+filter+spellId+listName) so the
	            --    same aura ID is not duplicated across aura index shifts.
	            --  * If spellId is NOT safe (SecretValue) => fall back to index-based case key to keep
	            --    rows separated without hard errors.
	            if not sidSafe then
	                ctx.case = string.format('auraIdx:%s:%s:%d', unit, filter, i)
	            end

	            Scanner:ScanReturns("lists", "C_UnitAuras.GetAuraDataByIndex("..unit..","..filter..")", ctx, auraData)
	
	            if discovered and sidSafe and not trackedLabel and onlyPack then
	                recordDiscoveredAura(sid, unit, filter)
	            end
	        end
        end
    end

    local auraCount = 0
    for _ in pairs(auraIdSet) do auraCount = auraCount + 1 end
    if auraCount > 0 then
        core:Line(("[lists] auras tracked=%d (only logs when present on unit)"):format(auraCount))
        if UnitExists and UnitExists("player") then
            scanAuraMatches("player", "HELPFUL")
            scanAuraMatches("player", "HARMFUL")
        end
        if UnitExists and UnitExists("target") then
            scanAuraMatches("target", "HELPFUL")
            scanAuraMatches("target", "HARMFUL")
        end
    else
        core:Line("[lists] auras: none")
    end
end

-- ---------------------------------------------------------------------------
-- RST2: Modules-only override for Lists suite
-- Replaces legacy "pack" flow. Modules pass args.lists (spells/auraIDs/items).
-- This keeps the dataset compact: only tracked IDs are scanned.
-- ---------------------------------------------------------------------------

local function _rst2_isSecret(v)
    if type(_G.issecretvalue) == "function" then
        local ok, r = pcall(_G.issecretvalue, v)
        return ok and r and true or false
    end
    return false
end

local function _rst2_norm_spell_list(spells)
    local out = {}
    if type(spells) ~= "table" then return out end
    for _, s in ipairs(spells) do
        if type(s) == "number" and s > 0 then
            out[#out + 1] = { id = s, label = tostring(s) }
        elseif type(s) == "table" and type(s.id) == "number" then
            out[#out + 1] = { id = s.id, label = s.label or tostring(s.id) }
        end
    end
    return out
end

local function _rst2_norm_aura_list(auraIDs)
    local set = {}
    if type(auraIDs) ~= "table" then return set end
    for _, a in ipairs(auraIDs) do
        if type(a) == "number" and a > 0 then
            set[a] = tostring(a)
        elseif type(a) == "table" and type(a.id) == "number" then
            set[a.id] = a.label or tostring(a.id)
        end
    end
    return set
end

local function _rst2_norm_item_list(items)
    local out = {}
    if type(items) ~= "table" then return out end
    for _, it in ipairs(items) do
        if type(it) == "number" and it > 0 then
            out[#out + 1] = { slot = it, label = ("slot" .. tostring(it)) }
        elseif type(it) == "table" and type(it.slot) == "number" then
            out[#out + 1] = { slot = it.slot, label = it.label or ("slot" .. tostring(it.slot)) }
        end
    end
    return out
end

-- Override legacy Lists:Run.
function Lists:Run(args)
    local core = _G.RothSecretTesterCore
    if not core then return end

    args = (type(args) == "table") and args or {}
    local lists = (type(args.lists) == "table") and args.lists or nil
    local moduleId = tostring(args.moduleId or args.module or args.listName or "MODULE")

    if not lists then
        core:Line(string.format("[module %s] no lists provided", moduleId))
        return
    end

    core:Line(string.format("[module %s] probing tracked lists", moduleId))

    local spellEntries = _rst2_norm_spell_list(lists.spells)
    local auraIdSet = _rst2_norm_aura_list(lists.auraIDs)
    local itemSlots = _rst2_norm_item_list(lists.items)

    -- Spells: probe key spell APIs
    local function probeSpell(suiteName, e)
        local sid = e.id
        local label = e.label or tostring(sid)

        local ctx = ctxBase({ listName = moduleId, spellId = sid, label = label })
        ctx.case = string.format("spell:%d", sid)

        if _G.C_Spell and type(C_Spell.GetSpellInfo) == "function" then
            local ok, info = pcall(C_Spell.GetSpellInfo, sid)
            if ok then Scanner:ScanReturns(suiteName, "C_Spell.GetSpellInfo(" .. label .. ")", ctx, info) end
        elseif type(GetSpellInfo) == "function" then
            local ok, name, rank, icon = pcall(GetSpellInfo, sid)
            if ok then Scanner:ScanReturns(suiteName, "GetSpellInfo(" .. label .. ")", ctx, name, rank, icon) end
        end

        if _G.C_Spell and type(C_Spell.GetSpellCooldown) == "function" then
            local ok, info = pcall(C_Spell.GetSpellCooldown, sid)
            if ok then Scanner:ScanReturns(suiteName, "C_Spell.GetSpellCooldown(" .. label .. ")", ctx, info) end
        elseif type(GetSpellCooldown) == "function" then
            local ok, start, dur, enabled, modRate = pcall(GetSpellCooldown, sid)
            if ok then Scanner:ScanReturns(suiteName, "GetSpellCooldown(" .. label .. ")", ctx, start, dur, enabled, modRate) end
        end

        if _G.C_Spell and type(C_Spell.GetSpellCharges) == "function" then
            local ok, info = pcall(C_Spell.GetSpellCharges, sid)
            if ok then Scanner:ScanReturns(suiteName, "C_Spell.GetSpellCharges(" .. label .. ")", ctx, info) end
        elseif type(GetSpellCharges) == "function" then
            local ok, cur, maxc, start, dur, modRate = pcall(GetSpellCharges, sid)
            if ok then Scanner:ScanReturns(suiteName, "GetSpellCharges(" .. label .. ")", ctx, cur, maxc, start, dur, modRate) end
        end

        if type(GetSpellPowerCost) == "function" then
            local ok, cost = pcall(GetSpellPowerCost, sid)
            if ok then Scanner:ScanReturns(suiteName, "GetSpellPowerCost(" .. label .. ")", ctx, cost) end
        end

        if type(IsUsableSpell) == "function" then
            local ok, usable, nomana = pcall(IsUsableSpell, sid)
            if ok then Scanner:ScanReturns(suiteName, "IsUsableSpell(" .. label .. ")", ctx, usable, nomana) end
        end

        if type(IsSpellInRange) == "function" then
            local ok, inRange = pcall(IsSpellInRange, sid, "target")
            if ok then Scanner:ScanReturns(suiteName, "IsSpellInRange(" .. label .. ",target)", ctx, inRange) end
        elseif _G.C_Spell and type(C_Spell.IsSpellInRange) == "function" then
            local ok, inRange = pcall(C_Spell.IsSpellInRange, sid, "target")
            if ok then Scanner:ScanReturns(suiteName, "C_Spell.IsSpellInRange(" .. label .. ",target)", ctx, inRange) end
        end
    end

    if #spellEntries > 0 then
        local max = math.min(#spellEntries, 240)
        core:Line(string.format("[module %s] spells=%d (testing first %d)", moduleId, #spellEntries, max))
        for i = 1, max do probeSpell(moduleId, spellEntries[i]) end
    else
        core:Line(string.format("[module %s] spells: none", moduleId))
    end

    -- Items: inventory cooldown queries
    local function probeItemSlot(suiteName, it)
        if not (GetInventoryItemID and GetInventoryItemCooldown) then return end
        local slot = it.slot
        local label = it.label or ("slot" .. tostring(slot))
        local itemId = GetInventoryItemID("player", slot)
        if not itemId then return end

        local ctx = ctxBase({ listName = moduleId, slot = slot, itemId = itemId, label = label })
        ctx.case = string.format("itemslot:%d", slot)

        local ok, startT, dur, enable = pcall(GetInventoryItemCooldown, "player", slot)
        if ok then
            Scanner:ScanReturns(suiteName, "GetInventoryItemCooldown(" .. label .. ")", ctx, itemId, startT, dur, enable)
        end
    end

    if #itemSlots > 0 then
        core:Line(string.format("[module %s] items=%d", moduleId, #itemSlots))
        for _, it in ipairs(itemSlots) do probeItemSlot(moduleId, it) end
    else
        core:Line(string.format("[module %s] items: none", moduleId))
    end

    -- Auras: scan tracked auras; still record SecretValue cases via index fallback.
    local function scanAuraMatches(unit, filter)
        if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
        for i = 1, 60 do
            local ok, auraData = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
            if not ok or auraData == nil then break end

            local sid = auraData.spellId

            -- If spellId is secret, we can't match against the tracked set; still record for diagnostics.
            if _rst2_isSecret(sid) then
                local ctx = ctxBase({ listName = moduleId, unit = unit, filter = filter, auraIndex = i, label = ("aura#" .. tostring(i)) })
                ctx.case = string.format("auraIdx:%s:%s:%d", unit, filter, i)
                Scanner:ScanReturns(moduleId, "C_UnitAuras.GetAuraDataByIndex(" .. unit .. "," .. filter .. ")", ctx, auraData)

            -- Non-secret spellId: only scan if in the tracked list.
            elseif type(sid) == "number" then
                local label = auraIdSet[sid]
                if label then
                    local ctx = ctxBase({ listName = moduleId, unit = unit, filter = filter, auraIndex = i, spellId = sid, label = label })
                    ctx.case = string.format("aura:%s:%s:%d", unit, filter, sid)
                    Scanner:ScanReturns(moduleId, "C_UnitAuras.GetAuraDataByIndex(" .. unit .. "," .. filter .. ")", ctx, auraData)
                end
            end
        end
    end

    local auraCount = 0
    for _ in pairs(auraIdSet) do auraCount = auraCount + 1 end
    if auraCount > 0 then
        core:Line(string.format("[module %s] auras tracked=%d (only when present)", moduleId, auraCount))
        if UnitExists and UnitExists("player") then
            scanAuraMatches("player", "HELPFUL")
            scanAuraMatches("player", "HARMFUL")
        end
        if UnitExists and UnitExists("target") then
            scanAuraMatches("target", "HELPFUL")
            scanAuraMatches("target", "HARMFUL")
        end
    else
        core:Line(string.format("[module %s] auras: none", moduleId))
    end
end
