-- schema.lua
-- Persistent schema/observations database: which return paths are secret vs non-secret under which contexts.

local Addon = _G.RothSecretTesterCore
if not Addon then return end

Addon.Schema = Addon.Schema or {}
local Schema = Addon.Schema

local issecretvalue = _G.issecretvalue
local pcall = pcall

local Safe = Addon.Safe
local tostring = tostring
local type = type
local GetTime = GetTime or _G.GetTime
local yield = coroutine.yield

local function checkYield(t0)
    if GetTime() - t0 > 0.015 then
        yield()
        return GetTime()
    end
    return t0
end

local function keyStr(v, opts)
    if Safe and Safe.Key then
        return Safe:Key(v, opts)
    end
    local ok, s = pcall(tostring, v)
    return ok and s or "<tostring-error>"
end

local function isSecretValue(v)
    if Safe and Safe.IsSecret then
        return Safe:IsSecret(v)
    end
    if type(issecretvalue) == "function" then
        local ok, r = pcall(issecretvalue, v)
        return ok and r and true or false
    end
    return false
end

local function now()
    return _G.time and _G.time() or 0
end

local function deepcopy(t)
    if type(t) ~= 'table' then return t end
    local out = {}
    for k, v in pairs(t) do
        out[k] = deepcopy(v)
    end
    return out
end

local function snapshot_context()
  -- Minimal, stable context dimensions for classifying Secret Value behavior.
  -- Snapshot at observation time because secrecy can vary by context.

  local combat = false
  if type(UnitAffectingCombat) == "function" then
    combat = UnitAffectingCombat("player") or false
  end
  if not combat and type(InCombatLockdown) == "function" then
    combat = InCombatLockdown() or false
  end

  local inInstance, instanceType = false, "none"
  if type(IsInInstance) == "function" then
    inInstance, instanceType = IsInInstance()
    inInstance = inInstance or false
    instanceType = instanceType or "none"
  end

  local inGroup = (type(IsInGroup) == "function" and IsInGroup()) or false
  local inRaid = (type(IsInRaid) == "function" and IsInRaid()) or false
  local groupSize = 0
  if type(GetNumGroupMembers) == "function" then
    groupSize = GetNumGroupMembers() or 0
  end

  local groupType = "solo"
  if inRaid then
    groupType = "raid"
  elseif inGroup then
    groupType = "party"
  end

  -- Instance metadata (optional, helps reproduce edge-cases)
  local instanceType2, difficultyID, maxPlayers, mapID, instanceID = nil, nil, nil, nil, nil
  if type(GetInstanceInfo) == "function" then
    local _, it2, did, _, mp, _, _, iid = GetInstanceInfo()
    instanceType2, difficultyID, maxPlayers, instanceID = it2, did, mp, iid
  end
  if type(C_Map) == "table" and type(C_Map.GetBestMapForUnit) == "function" then
    mapID = C_Map.GetBestMapForUnit("player")
  end

  local zone, subzone = nil, nil
  if type(GetRealZoneText) == "function" then zone = GetRealZoneText() end
  if type(GetSubZoneText) == "function" then subzone = GetSubZoneText() end

  local encounter = false
  if type(IsEncounterInProgress) == "function" then
    encounter = IsEncounterInProgress() or false
  end

  local bossTarget = false
  if type(UnitExists) == "function" and UnitExists("target") then
    local okC, cls = pcall(UnitClassification, "target")
    local okL, lvl = pcall(UnitLevel, "target")
    if okC and cls == "worldboss" then
      bossTarget = true
    elseif okL and lvl == -1 then
      bossTarget = true
    end
  end

  local ctx = {
    combat = combat and 1 or 0,
    inInstance = inInstance and 1 or 0,
    instanceType = instanceType,
    instanceType2 = instanceType2,
    difficultyID = difficultyID,
    maxPlayers = maxPlayers,
    instanceID = instanceID,
    group = groupType,
    groupSize = groupSize,
    mapID = mapID,
    zone = zone,
    subzone = subzone,
    encounter = encounter and 1 or 0,
    bossTarget = bossTarget and 1 or 0,
  }

  return ctx
end

local function context_key(ctx)
  -- Keep the key compact to avoid exploding the database, but include the
  -- dimensions that most plausibly affect Secret Value rules.
  local c = tostring(ctx and ctx.combat or 0)
  local inst = tostring((ctx and ctx.instanceType) or "none")
  local g = tostring((ctx and ctx.group) or "solo")

  -- difficultyID only matters inside instances; omit when nil.
  local did = ctx and ctx.difficultyID
  if did ~= nil then
    return string.format("c=%s|inst=%s|g=%s|d=%s", c, inst, g, tostring(did))
  end

  return string.format("c=%s|inst=%s|g=%s", c, inst, g)
end

local function ensure_path(tbl, ...)
    local t = tbl
    for i = 1, select('#', ...) do
        local k = select(i, ...)
        if t[k] == nil then t[k] = {} end
        t = t[k]
    end
    return t
end

local function count_keys_limit(t, limit)
    -- Counts keys with early exit. Used for lightweight caps.
    local n = 0
    for _ in pairs(t) do
        n = n + 1
        if limit and n >= limit then
            return n
        end
    end
    return n
end

local function sorted_keys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    return keys
end

local function serialize_lua(value, indent, visited, depth)
    indent = indent or ""
    visited = visited or {}
    depth = depth or 0

    local t = type(value)
    if t == "nil" then
        return "nil"
    elseif t == "boolean" then
        return value and "true" or "false"
    elseif t == "number" then
        return tostring(value)
    elseif t == "string" then
        return string.format("%q", value)
    elseif t == "table" then
        if visited[value] then
            return "\"<cycle>\""
        end
        visited[value] = true

        local parts = {"{\n"}
        local keys = sorted_keys(value)
        for _, k in ipairs(keys) do
            local v = value[k]
            parts[#parts + 1] = indent .. "  [" .. serialize_lua(k, "", visited, depth + 1) .. "] = " .. serialize_lua(v, indent .. "  ", visited, depth + 1) .. ",\n"
        end
        parts[#parts + 1] = indent .. "}"
        return table.concat(parts)
    else
        return string.format("%q", "<" .. t .. ">")
    end
end

local function serialize_lua_yield(value, indent, visited, depth, tRef)
    indent = indent or ""
    visited = visited or {}
    depth = depth or 0

    if tRef and type(tRef) == 'table' then
        tRef.t0 = checkYield(tRef.t0)
    end

    local t = type(value)
    if t == "nil" then
        return "nil"
    elseif t == "boolean" then
        return value and "true" or "false"
    elseif t == "number" then
        return tostring(value)
    elseif t == "string" then
        return string.format("%q", value)
    elseif t == "table" then
        if visited[value] then
            return "\"<cycle>\""
        end
        visited[value] = true

        local parts = {"{\n"}
        local keys = sorted_keys(value)
        for _, k in ipairs(keys) do
            local v = value[k]
            parts[#parts + 1] = indent .. "  [" .. serialize_lua_yield(k, "", visited, depth + 1, tRef) .. "] = " .. serialize_lua_yield(v, indent .. "  ", visited, depth + 1, tRef) .. ",\n"
        end
        parts[#parts + 1] = indent .. "}"
        return table.concat(parts)
    else
        return string.format("%q", "<" .. t .. ">")
    end
end


function Schema:Init(core)
    self.core = core or Addon
    local db = self.core:GetDB()

    db.schema = db.schema or { version = 1, contexts = {}, obs = {}, meta = { created = 0, updated = 0 } }
    db.schema.version = db.schema.version or 1
    db.schema.contexts = db.schema.contexts or {}
    db.schema.obs = db.schema.obs or {}
    db.schema.meta = db.schema.meta or { created = 0, updated = 0 }

    if not db.schema.meta.created or db.schema.meta.created == 0 then
        db.schema.meta.created = now()
    end

    self.db = db.schema

    -- Meta counters (stable across reloads) for bounded growth.
    self.db.meta.rows = tonumber(self.db.meta.rows) or nil
    self.db.meta.droppedRows = tonumber(self.db.meta.droppedRows) or 0
    self.db.meta.droppedPaths = tonumber(self.db.meta.droppedPaths) or 0
    self.db.meta.droppedCtx = tonumber(self.db.meta.droppedCtx) or 0
    self.db.meta.droppedSrc = tonumber(self.db.meta.droppedSrc) or 0

    -- Compute total row count once if absent (O(N) on first init only).
    if self.db.meta.rows == nil then
        local rows = 0
        for _, apiNode in pairs(self.db.obs) do
            if type(apiNode) == "table" then
                for _, caseNode in pairs(apiNode) do
                    if type(caseNode) == "table" then
                        for _, stat in pairs(caseNode) do
                            if type(stat) == "table" then rows = rows + 1 end
                        end
                    end
                end
            end
        end
        self.db.meta.rows = rows
    end
end

function Schema:Observe(apiKey, caseKey, path, value, ctx, source)
    if not self.db then return end

    apiKey = keyStr(apiKey, { nilPlaceholder = "<unknown>", secretPlaceholder = "<secret_api>" })
    caseKey = keyStr(caseKey, { nilPlaceholder = "<default>", secretPlaceholder = "<secret_case>" })
    path = keyStr(path, { nilPlaceholder = "<path>", secretPlaceholder = "<secret_path>" })

    ctx = ctx or snapshot_context()
    local ckey = context_key(ctx)

    -- store context snapshot (first-wins for that key)
    if not self.db.contexts[ckey] then
        self.db.contexts[ckey] = deepcopy(ctx)
    end

    -- Growth caps (SavedVariables safety). This harness can be spammed by
    -- passive probes; keep the schema bounded.
    local maxRows, maxPathsPerCase, maxCtxPerPath, maxSourcesPerPath = 60000, 250, 40, 40
    if self.core and self.core.GetDB then
        local _db = self.core:GetDB()
        local sset = _db and _db.settings and _db.settings.schema or nil
        if type(sset) == "table" then
            maxRows = tonumber(sset.maxRows) or maxRows
            maxPathsPerCase = tonumber(sset.maxPathsPerCase) or maxPathsPerCase
            maxCtxPerPath = tonumber(sset.maxCtxPerPath) or maxCtxPerPath
            maxSourcesPerPath = tonumber(sset.maxSourcesPerPath) or maxSourcesPerPath
        end
    end

    local obs = self.db.obs
    local apiNode = obs[apiKey]
    if not apiNode then apiNode = {}; obs[apiKey] = apiNode end
    local caseNode = apiNode[caseKey]
    if not caseNode then caseNode = {}; apiNode[caseKey] = caseNode end

    local stat = caseNode[path]
    local isNewRow = false
    if not stat then
        isNewRow = true
        local rows = tonumber(self.db.meta.rows) or 0
        if maxRows > 0 and rows >= maxRows then
            self.db.meta.droppedRows = (tonumber(self.db.meta.droppedRows) or 0) + 1
            return
        end

        if maxPathsPerCase > 0 then
            local cur = count_keys_limit(caseNode, maxPathsPerCase)
            if cur >= maxPathsPerCase then
                self.db.meta.droppedPaths = (tonumber(self.db.meta.droppedPaths) or 0) + 1
                return
            end
        end

        stat = {}
        caseNode[path] = stat
        self.db.meta.rows = rows + 1
    end

    stat.s = stat.s or 0  -- secret count
    stat.n = stat.n or 0  -- non-secret count
    stat.types = stat.types or {}
    stat.byCtx = stat.byCtx or {}
    stat.bySrc = stat.bySrc or {}
    stat.first = stat.first or now()
    stat.last = now()

    local isSecret = isSecretValue(value)
    if isSecret then
        stat.s = stat.s + 1
    else
        stat.n = stat.n + 1
        local lt = type(value)
        stat.types[lt] = (stat.types[lt] or 0) + 1
    end

    local cstat = stat.byCtx[ckey]
    if not cstat then
        if maxCtxPerPath > 0 and count_keys_limit(stat.byCtx, maxCtxPerPath) >= maxCtxPerPath then
            self.db.meta.droppedCtx = (tonumber(self.db.meta.droppedCtx) or 0) + 1
        else
            cstat = { s = 0, n = 0 }
            stat.byCtx[ckey] = cstat
        end
    end
    if cstat then
        if isSecret then cstat.s = cstat.s + 1 else cstat.n = cstat.n + 1 end
    end

    -- Optional source (suite/module) attribution
    if source ~= nil then
        local src = keyStr(source, { nilPlaceholder = "", secretPlaceholder = "<secret_src>" })
        if src ~= '' then
            local sstat = stat.bySrc[src]
            if not sstat then
                if maxSourcesPerPath > 0 and count_keys_limit(stat.bySrc, maxSourcesPerPath) >= maxSourcesPerPath then
                    self.db.meta.droppedSrc = (tonumber(self.db.meta.droppedSrc) or 0) + 1
                    sstat = nil
                else
                    sstat = { s = 0, n = 0 }
                    stat.bySrc[src] = sstat
                end
            end
            if sstat then
                if isSecret then sstat.s = sstat.s + 1 else sstat.n = sstat.n + 1 end
            end
        end
    end

    self.db.meta.updated = now()

    -- Inform core that the persistent DB changed (for operational logging/UI status).
    if self.core and type(self.core.MarkDBDirty) == 'function' then
        self.core:MarkDBDirty('schema')
    end
end

function Schema:GetSummary()
    if not self.db then return { apis = 0, cases = 0, paths = 0 } end

    local apis, cases, paths = 0, 0, 0
    for _, apiNode in pairs(self.db.obs) do
        apis = apis + 1
        for _, caseNode in pairs(apiNode) do
            cases = cases + 1
            for _ in pairs(caseNode) do
                paths = paths + 1
            end
        end
    end

    return { apis = apis, cases = cases, paths = paths }
end

function Schema:ExportFullLua()
    if not self.db then return "-- schema not initialized" end
    local tRef = { t0 = GetTime() }
    return "return " .. serialize_lua_yield(self.db, "", {}, 0, tRef)
end

function Schema:ExportSummaryLua()
    if not self.db then return "-- schema not initialized" end

    local out = {
        version = self.db.version or 1,
        meta = self.db.meta,
        contexts = self.db.contexts,
        rows = {},
    }

    local obs = self.db.obs or {}
    local tmp = {}

    local function cls_from_counts(s, n)
        s = tonumber(s) or 0
        n = tonumber(n) or 0
        if s > 0 and n == 0 then return "secret" end
        if n > 0 and s == 0 then return "nonsecret" end
        if s > 0 and n > 0 then return "mixed" end
        return "unknown"
    end

    local t0 = GetTime()

    for apiKey, apiNode in pairs(obs) do
        for caseKey, caseNode in pairs(apiNode or {}) do
            for path, stat in pairs(caseNode or {}) do
                t0 = checkYield(t0)
                local ctxMap = {}
                local hasS, hasN = false, false

                if stat.byCtx then
                    for ckey, cstat in pairs(stat.byCtx) do
                        local ccls = cls_from_counts(cstat.s, cstat.n)
                        ctxMap[ckey] = ccls
                        if (tonumber(cstat.s) or 0) > 0 then hasS = true end
                        if (tonumber(cstat.n) or 0) > 0 then hasN = true end
                    end
                else
                    local ccls = cls_from_counts(stat.s, stat.n)
                    ctxMap["<noctx>"] = ccls
                    if (tonumber(stat.s) or 0) > 0 then hasS = true end
                    if (tonumber(stat.n) or 0) > 0 then hasN = true end
                end


                local srcMap = nil
                if stat.bySrc then
                    srcMap = {}
                    for src, sstat in pairs(stat.bySrc) do
                        srcMap[src] = cls_from_counts(sstat.s, sstat.n)
                    end
                end
                local overall
                if hasS and hasN then
                    overall = "mixed"
                elseif hasS then
                    overall = "secret"
                elseif hasN then
                    overall = "nonsecret"
                else
                    overall = "unknown"
                end

                tmp[#tmp + 1] = {
                    api = apiKey,
                    case = caseKey,
                    path = path,
                    cls = overall,
                    ctx = ctxMap,
                    src = srcMap,
                }
            end
        end
    end

    table.sort(tmp, function(a, b)
        if a.api ~= b.api then return a.api < b.api end
        if a.case ~= b.case then return a.case < b.case end
        return a.path < b.path
    end)

    out.rows = tmp
    local tRef = { t0 = GetTime() }
    return "return " .. serialize_lua_yield(out, "", {}, 0, tRef)
end

function Schema:CountSummaryRows()
    -- Count rows as they appear in ExportSummaryLua (apiKey x caseKey x path).
    if not self.db or not self.db.obs then return 0 end
    local n = 0
    for _, apiNode in pairs(self.db.obs) do
        for _, caseNode in pairs(apiNode or {}) do
            for _ in pairs(caseNode or {}) do
                n = n + 1
            end
        end
    end
    return n
end




-- --------------------------------
-- Entity summary export (compact)
-- --------------------------------
-- Problem: full schema export is path-level and can be very large.
-- This export groups by spell/aura id and summarizes "where it's secret" by context.

local function _cls_from_counts(s, n)
    s = tonumber(s) or 0
    n = tonumber(n) or 0
    if s > 0 and n == 0 then return "secret" end
    if n > 0 and s == 0 then return "nonsecret" end
    if s > 0 and n > 0 then return "mixed" end
    return "unknown"
end

local function _api_short(apiKey)
    if type(apiKey) ~= "string" then return tostring(apiKey) end
    local p = apiKey:match("^([%w_%.]+)%(")
    return p or apiKey
end

local function _parse_list(caseKey)
    if type(caseKey) ~= "string" then return nil end
    return caseKey:match("list=([^|]+)")
end

local function _parse_spell_id(caseKey)
    if type(caseKey) ~= "string" then return nil end
    -- Supported key formats:
    --  * spell:<id>
    --  * ...spellId=<id>... (legacy buildCaseKey)
    --  * aura:<unit>:<filter>:<id>
    --  * auraIdx:<unit>:<filter>:<index> (no spellId)
    local sid = caseKey:match("^spell:(%d+)")
    if not sid then sid = caseKey:match("spellId=(%d+)") end
    if not sid then sid = caseKey:match("^aura:[^:]+:[^:]+:(%d+)") end
    if not sid then sid = caseKey:match("spell:(%d+)") end
    if sid then return tonumber(sid) end
    return nil
end

local function _guess_kind(caseKey)
    if type(caseKey) ~= "string" then return "unknown" end
    -- Aura caseKeys in this addon usually contain unit/filter
    if caseKey:find("filter=", 1, true) or caseKey:find("aura", 1, true) then
        return "aura"
    end
    return "spell"
end


function Schema:ExportEntitySummaryLua(opts)
    if not self.db then return "-- schema not initialized" end
    opts = type(opts) == "table" and opts or {}

    local includeContexts = (opts.includeContexts ~= false)
    local includeAPIs = (opts.includeAPIs ~= false)

    local obs = self.db.obs or {}
    local entities = {}
    local order = {}

    local function ensure(t, k)
        local v = t[k]
        if type(v) ~= "table" then v = {}; t[k] = v end
        return v
    end

    local function get_entity(kind, id)
        local key = kind .. ":" .. tostring(id)
        local e = entities[key]
        if not e then
            e = {
                kind = kind,
                id = id,
                packs = {},
                _ctxAgg = {}, -- ckey -> {s=bool,n=bool}
                _apiAgg = {}, -- apiS -> { _hasS,_hasN,_pathAgg }
                _hasS = false,
                _hasN = false,
            }
            entities[key] = e
            order[#order + 1] = key
        end
        return e
    end

    local t0 = GetTime()

    -- Build aggregated, de-duplicated per-path stats across multiple case keys.
    for apiKey, apiNode in pairs(obs) do
        local apiS = _api_short(apiKey)
        for caseKey, caseNode in pairs(apiNode or {}) do
            local sid = _parse_spell_id(caseKey)
            if sid then
                t0 = checkYield(t0)
                local kind = _guess_kind(caseKey)
                local e = get_entity(kind, sid)

                -- Legacy: some old builds embedded list/pack in the caseKey.
                local listName = _parse_list(caseKey)
                if listName then e.packs[listName] = true end

                local aAgg = ensure(e._apiAgg, apiS)
                aAgg._hasS = aAgg._hasS or false
                aAgg._hasN = aAgg._hasN or false
                aAgg._pathAgg = aAgg._pathAgg or {} -- pathKey -> {s=bool,n=bool}

                for pathKey, stat in pairs(caseNode or {}) do
                    local s = tonumber(stat and stat.s) or 0
                    local n = tonumber(stat and stat.n) or 0

                    if s > 0 then
                        e._hasS = true
                        aAgg._hasS = true
                    end
                    if n > 0 then
                        e._hasN = true
                        aAgg._hasN = true
                    end

                    local p = aAgg._pathAgg[pathKey]
                    if not p then
                        p = { s = false, n = false }
                        aAgg._pathAgg[pathKey] = p
                    end
                    if s > 0 then p.s = true end
                    if n > 0 then p.n = true end

                    -- Source attribution (suite/module) is stored per-path.
                    if type(stat and stat.bySrc) == "table" then
                        for src in pairs(stat.bySrc) do
                            if type(src) == "string" and src ~= "" then
                                e.packs[src] = true
                            end
                        end
                    end

                    if includeContexts then
                        if type(stat and stat.byCtx) == "table" then
                            for ckey, cstat in pairs(stat.byCtx) do
                                local c = ensure(e._ctxAgg, ckey)
                                c.s = c.s or false
                                c.n = c.n or false
                                if (tonumber(cstat and cstat.s) or 0) > 0 then c.s = true end
                                if (tonumber(cstat and cstat.n) or 0) > 0 then c.n = true end
                            end
                        else
                            local c = ensure(e._ctxAgg, "<noctx>")
                            c.s = c.s or false
                            c.n = c.n or false
                            if s > 0 then c.s = true end
                            if n > 0 then c.n = true end
                        end
                    end
                end
            end
        end
    end

    table.sort(order, function(a, b)
        -- sort: kind then id
        local ka, ia = a:match("^([^:]+):(%d+)$")
        local kb, ib = b:match("^([^:]+):(%d+)$")
        if ka ~= kb then return tostring(ka) < tostring(kb) end
        return tonumber(ia) < tonumber(ib)
    end)

    local out = {
        version = self.db.version or 1,
        meta = self.db.meta,
        contexts = self.db.contexts,
        entities = {},
    }

    for i = 1, #order do
        local e = entities[order[i]]

        -- packs as sorted array
        local packs = nil
        if e.packs then
            packs = {}
            for p in pairs(e.packs) do packs[#packs + 1] = p end
            table.sort(packs)
        end

        -- contexts as ckey -> classification
        local ctx = nil
        if includeContexts then
            ctx = {}
            for ckey, agg in pairs(e._ctxAgg or {}) do
                ctx[ckey] = _cls_from_counts((agg.s and 1 or 0), (agg.n and 1 or 0))
            end
        end

        -- per-api stats + unique path counts
        local apis = nil
        local totalPaths, secretPaths, nonsecretPaths = 0, 0, 0

        if includeAPIs then
            apis = {}
            for apiS, agg in pairs(e._apiAgg or {}) do
                local paths = 0
                local pAgg = agg._pathAgg or {}
                for _, p in pairs(pAgg) do
                    paths = paths + 1
                    totalPaths = totalPaths + 1
                    if p.s then secretPaths = secretPaths + 1 end
                    if p.n then nonsecretPaths = nonsecretPaths + 1 end
                end

                apis[#apis + 1] = {
                    api = apiS,
                    cls = _cls_from_counts(agg._hasS and 1 or 0, agg._hasN and 1 or 0),
                    paths = paths,
                }
            end
            table.sort(apis, function(a, b) return a.api < b.api end)
        else
            for _, agg in pairs(e._apiAgg or {}) do
                local pAgg = agg._pathAgg or {}
                for _, p in pairs(pAgg) do
                    totalPaths = totalPaths + 1
                    if p.s then secretPaths = secretPaths + 1 end
                    if p.n then nonsecretPaths = nonsecretPaths + 1 end
                end
            end
        end

        out.entities[#out.entities + 1] = {
            kind = e.kind,
            id = e.id,
            overall = _cls_from_counts(e._hasS and 1 or 0, e._hasN and 1 or 0),
            packs = packs,
            contexts = ctx,
            apis = apis,
            stats = {
                paths = totalPaths,
                secret_paths = secretPaths,
                nonsecret_paths = nonsecretPaths,
            },
        }
    end

    local tRef = { t0 = GetTime() }
    return "return " .. serialize_lua_yield(out, "", {}, 0, tRef)
end

-- --------------------------------
-- Human report (one row per spell/aura, with per-field secrecy)
-- --------------------------------
-- Goal: avoid kilometre-long logs. We keep raw observations in db.obs (aggregated counts),
-- and generate a readable report from it.

local function _spell_name(spellId)
    spellId = tonumber(spellId)
    if not spellId then return nil end

    if _G.C_Spell and type(C_Spell.GetSpellInfo) == "function" then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellId)
        if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
            return info.name
        end
    end

    if type(_G.GetSpellInfo) == "function" then
        local name = GetSpellInfo(spellId)
        if type(name) == "string" and name ~= "" then
            return name
        end
    end

    return nil
end

local function _ctx_split(stat)
    -- Returns: secretKeys[], clearKeys[]
    local secretKeys, clearKeys = {}, {}
    if not stat or type(stat.byCtx) ~= "table" then
        return secretKeys, clearKeys
    end

    for ckey, cstat in pairs(stat.byCtx) do
        local cls = _cls_from_counts(cstat.s, cstat.n)
        if cls == "secret" then
            secretKeys[#secretKeys + 1] = ckey
        elseif cls == "nonsecret" then
            clearKeys[#clearKeys + 1] = ckey
        elseif cls == "mixed" then
            -- Mixed per-context means both were observed in same ckey;
            -- treat as BOTH for the purpose of highlighting instability.
            secretKeys[#secretKeys + 1] = ckey
            clearKeys[#clearKeys + 1] = ckey
        end
    end

    table.sort(secretKeys)
    table.sort(clearKeys)
    return secretKeys, clearKeys
end

local function _join_limit(arr, limit)
    limit = tonumber(limit) or 6
    if #arr <= limit then
        return table.concat(arr, ", ")
    end
    local tmp = {}
    for i = 1, limit do tmp[#tmp + 1] = arr[i] end
    tmp[#tmp + 1] = string.format("…(+%d)", #arr - limit)
    return table.concat(tmp, ", ")
end

local function _entity_key(kind, id)
    return tostring(kind or "unknown") .. ":" .. tostring(id or 0)
end

-- Merge two path-level stats (as stored in db.schema.obs[api][case][path]).
-- Used only for report generation; does not modify SavedVariables.
local function _mergeStat(dst, src)
    if type(src) ~= "table" then
        return dst
    end
    if type(dst) ~= "table" then
        dst = {}
    end

    -- Counters
    dst.s = (tonumber(dst.s) or 0) + (tonumber(src.s) or 0)
    dst.n = (tonumber(dst.n) or 0) + (tonumber(src.n) or 0)

    -- Types (non-secret only)
    if type(src.types) == "table" then
        dst.types = dst.types or {}
        for lt, c in pairs(src.types) do
            dst.types[lt] = (tonumber(dst.types[lt]) or 0) + (tonumber(c) or 0)
        end
    end

    -- Context aggregation
    if type(src.byCtx) == "table" then
        dst.byCtx = dst.byCtx or {}
        for ckey, cstat in pairs(src.byCtx) do
            local d = dst.byCtx[ckey]
            if not d then
                d = { s = 0, n = 0 }
                dst.byCtx[ckey] = d
            end
            d.s = (tonumber(d.s) or 0) + (tonumber(cstat and cstat.s) or 0)
            d.n = (tonumber(d.n) or 0) + (tonumber(cstat and cstat.n) or 0)
        end
    end

    -- Source attribution
    if type(src.bySrc) == "table" then
        dst.bySrc = dst.bySrc or {}
        for skey, sstat in pairs(src.bySrc) do
            local d = dst.bySrc[skey]
            if not d then
                d = { s = 0, n = 0 }
                dst.bySrc[skey] = d
            end
            d.s = (tonumber(d.s) or 0) + (tonumber(sstat and sstat.s) or 0)
            d.n = (tonumber(d.n) or 0) + (tonumber(sstat and sstat.n) or 0)
        end
    end

    -- Time ranges
    local df, sf = tonumber(dst.first), tonumber(src.first)
    if df == nil or (sf and sf < df) then dst.first = sf or df end
    local dl, sl = tonumber(dst.last), tonumber(src.last)
    if dl == nil or (sl and sl > dl) then dst.last = sl or dl end

    return dst
end

function Schema:BuildReportText(opts)
    if not self.db then return "-- schema not initialized" end
    opts = type(opts) == "table" and opts or {}

    local maxCtxPerPath = tonumber(opts.maxCtxPerPath) or 6
    local maxEntities = tonumber(opts.maxEntities)
    if maxEntities == nil then maxEntities = 400 end
    local maxPathsPerApi = tonumber(opts.maxPathsPerApi)
    if maxPathsPerApi == nil then maxPathsPerApi = 80 end
    local maxApisPerEntity = tonumber(opts.maxApisPerEntity)
    if maxApisPerEntity == nil then maxApisPerEntity = 20 end
    local includeNonSecret = opts.includeNonSecretPaths == true
    local includeUnknown = opts.includeUnknownPaths == true
    local includeNonSecretEntities = opts.includeNonSecretEntities == true
    local includeUnknownEntities = opts.includeUnknownEntities == true

    -- Compact mode: keep report readable by default.
    -- In compact mode, clear-only entities are listed, but without deep per-path details.
    local compact = (opts.compact ~= false)

    local obs = self.db.obs or {}

    -- entity aggregation
    local entities = {}
    local order = {}

    local function ensure(t, k)
        local v = t[k]
        if type(v) ~= "table" then v = {}; t[k] = v end
        return v
    end

    local function get_entity(kind, id)
        local k = _entity_key(kind, id)
        local e = entities[k]
        if not e then
            e = {
                kind = kind,
                id = id,
                name = _spell_name(id),
                packs = {},
                cases = {}, -- case variants (for auras: unit:filter)
                ctxAgg = {}, -- ckey -> {hasS,hasN}
                apis = {},   -- apiShort -> { paths = { path -> mergedStat } }
                _hasS = false,
                _hasN = false,
            }
            entities[k] = e
            order[#order + 1] = k
        end
        return e
    end

    local function recordCaseVariant(e, caseKey)
        if e.kind ~= "aura" then return end
        if type(caseKey) ~= "string" then return end
        local unit, filter = caseKey:match("^aura:([^:]+):([^:]+):%d+")
        if not unit or not filter then return end
        local k = unit .. ":" .. filter
        e.cases[k] = true
    end

    for apiKey, apiNode in pairs(obs) do
        local apiS = _api_short(apiKey)
        for caseKey, caseNode in pairs(apiNode or {}) do
            local sid = _parse_spell_id(caseKey)
            if sid then
                local kind = _guess_kind(caseKey)
                local e = get_entity(kind, sid)

                recordCaseVariant(e, caseKey)

                local a = ensure(e.apis, apiS)
                a.paths = a.paths or {}

                for path, stat in pairs(caseNode or {}) do
                    -- Important: multiple caseKeys can map to the same spellId (auras across units/filters).
                    -- Merge per-path stats so the report is deterministic and truly aggregated.
                    a.paths[path] = _mergeStat(a.paths[path], stat)

                    -- Attribute the observation to its sources (suite/module). This keeps the report
                    -- useful even when case keys are normalized and no longer include list/pack names.
                    if type(stat.bySrc) == "table" then
                        for src in pairs(stat.bySrc) do
                            if type(src) == "string" and src ~= "" then
                                e.packs[src] = true
                            end
                        end
                    end
                    local s = tonumber(stat.s) or 0
                    local n = tonumber(stat.n) or 0
                    if s > 0 then e._hasS = true end
                    if n > 0 then e._hasN = true end

                    if type(stat.byCtx) == "table" then
                        for ckey, cstat in pairs(stat.byCtx) do
                            local c = ensure(e.ctxAgg, ckey)
                            c.hasS = c.hasS or ((tonumber(cstat.s) or 0) > 0)
                            c.hasN = c.hasN or ((tonumber(cstat.n) or 0) > 0)
                        end
                    end
                end
            end
        end
    end

    table.sort(order, function(a, b)
        local ea = entities[a]
        local eb = entities[b]
        local ca = ea and _cls_from_counts(ea._hasS and 1 or 0, ea._hasN and 1 or 0) or "unknown"
        local cb = eb and _cls_from_counts(eb._hasS and 1 or 0, eb._hasN and 1 or 0) or "unknown"
        local cpri = { secret = 1, mixed = 2, unknown = 3, nonsecret = 4 }
        local paC = cpri[ca] or 9
        local pbC = cpri[cb] or 9
        if paC ~= pbC then return paC < pbC end

        local ka, ia = a:match("^([^:]+):(%d+)$")
        local kb, ib = b:match("^([^:]+):(%d+)$")
        local kpri = { aura = 1, spell = 2, item = 3, other = 9 }
        local paK = kpri[tostring(ka)] or 9
        local pbK = kpri[tostring(kb)] or 9
        if paK ~= pbK then return paK < pbK end
        if ka ~= kb then return tostring(ka) < tostring(kb) end
        return tonumber(ia) < tonumber(ib)
    end)

    -- Precompute counts to keep the report compact and debuggable.
    local total, cSecret, cMixed, cClear, cUnknown = 0, 0, 0, 0, 0
    for i = 1, #order do
        local e = entities[order[i]]
        local overall = _cls_from_counts(e._hasS and 1 or 0, e._hasN and 1 or 0)
        total = total + 1
        if overall == "secret" then cSecret = cSecret + 1
        elseif overall == "mixed" then cMixed = cMixed + 1
        elseif overall == "nonsecret" then cClear = cClear + 1
        else cUnknown = cUnknown + 1 end
    end

    -- If filters would make the report look empty, auto-unhide clear entities.
    local autoUnhideClear = false
    if (not includeNonSecretEntities) and cSecret == 0 and cMixed == 0 and cUnknown == 0 and cClear > 0 then
        includeNonSecretEntities = true
        autoUnhideClear = true
        -- keep compact behavior for readability
        compact = true
    end

    local out = {}
    local meta = self.db.meta or {}
    out[#out + 1] = string.format(
        "Entities: total=%d  secret=%d  mixed=%d  clear=%d  unknown=%d  (clear hidden=%s)  caps: maxEntities=%s maxApisPerEntity=%s maxPathsPerAPI=%s  dropped: rows=%d paths=%d ctx=%d src=%d",
        total, cSecret, cMixed, cClear, cUnknown,
        includeNonSecretEntities and "no" or "yes",
        tostring(maxEntities), tostring(maxApisPerEntity), tostring(maxPathsPerApi),
        tonumber(meta.droppedRows) or 0,
        tonumber(meta.droppedPaths) or 0,
        tonumber(meta.droppedCtx) or 0,
        tonumber(meta.droppedSrc) or 0
    )
    if autoUnhideClear then
        out[#out + 1] = "(auto: showing clear-only entities because no secret/mixed/unknown entities were detected)"
    end
    out[#out + 1] = ""

    local printedEntities = 0
    local truncatedEntities = 0
    for i = 1, #order do
        local e = entities[order[i]]
        local overall = _cls_from_counts(e._hasS and 1 or 0, e._hasN and 1 or 0)

        -- Default: hide entities that were ONLY observed as non-secret.
        if overall == "nonsecret" and not includeNonSecretEntities then
            -- skip noisy, always-clear entities
        elseif overall == "unknown" and not includeUnknownEntities then
            -- skip entities that never produced any data
        else
            if maxEntities > 0 and printedEntities >= maxEntities then
                truncatedEntities = truncatedEntities + 1
            else
                printedEntities = printedEntities + 1

        -- packs list
        local packs = {}
        for p in pairs(e.packs or {}) do packs[#packs + 1] = p end
        table.sort(packs)

        local headerName = e.name and (e.name .. " (" .. tostring(e.id) .. ")") or ("id=" .. tostring(e.id))
        -- case variants (auras only)
        local caseInfo = ""
        if e.kind == "aura" then
            local cases = {}
            for k in pairs(e.cases or {}) do cases[#cases + 1] = k end
            table.sort(cases)
            if #cases > 1 then
                caseInfo = "  cases=" .. _join_limit(cases, 6)
            end
        end

        out[#out + 1] = string.format("[%s] %s  overall=%s%s%s", tostring(e.kind), headerName, overall,
            (#packs > 0 and ("  sources=" .. table.concat(packs, ",")) or ""),
            caseInfo)

        -- Compact mode: for clear-only entities, list the entity header and skip deep details.
        if compact and overall == "nonsecret" and (not includeNonSecret) and (not includeUnknown) then
            out[#out + 1] = ""
        else

        -- Context summary (entity-level)
        if next(e.ctxAgg) ~= nil then
            local ctxS, ctxN, ctxM = {}, {}, {}
            for ckey, agg in pairs(e.ctxAgg) do
                local cls = _cls_from_counts(agg.hasS and 1 or 0, agg.hasN and 1 or 0)
                if cls == "secret" then ctxS[#ctxS + 1] = ckey
                elseif cls == "nonsecret" then ctxN[#ctxN + 1] = ckey
                elseif cls == "mixed" then ctxM[#ctxM + 1] = ckey end
            end
            table.sort(ctxS); table.sort(ctxN); table.sort(ctxM)
            if #ctxM > 0 then out[#out + 1] = "  ctx mixed: " .. _join_limit(ctxM, maxCtxPerPath) end
            if #ctxS > 0 then out[#out + 1] = "  ctx secret: " .. _join_limit(ctxS, maxCtxPerPath) end
            if #ctxN > 0 then out[#out + 1] = "  ctx clear:  " .. _join_limit(ctxN, maxCtxPerPath) end
        end

        -- API/path details
        local apiNames = {}
        for apiS in pairs(e.apis or {}) do apiNames[#apiNames + 1] = apiS end
        table.sort(apiNames)

        local apiShown, apiHidden = 0, 0
        for _, apiS in ipairs(apiNames) do
            local a = e.apis[apiS]
            local paths = a and a.paths or {}

            -- per-api counts
            local cSecret, cMixed, cClear, cUnknown = 0, 0, 0, 0
            local pathNames = {}
            for path in pairs(paths) do pathNames[#pathNames + 1] = path end
            table.sort(pathNames, function(pa, pb)
                local sa = paths[pa]
                local sb = paths[pb]
                local ca = _cls_from_counts(sa.s, sa.n)
                local cb = _cls_from_counts(sb.s, sb.n)
                local pri = { secret = 1, mixed = 2, unknown = 3, nonsecret = 4 }
                local da = pri[ca] or 9
                local db_ = pri[cb] or 9
                if da ~= db_ then return da < db_ end
                return tostring(pa) < tostring(pb)
            end)

            local shown, hidden = 0, 0
            for _, path in ipairs(pathNames) do
                local st = paths[path]
                local cls = _cls_from_counts(st.s, st.n)
                if cls == "secret" then cSecret = cSecret + 1
                elseif cls == "mixed" then cMixed = cMixed + 1
                elseif cls == "nonsecret" then cClear = cClear + 1
                else cUnknown = cUnknown + 1 end
            end

            -- Skip APIs that have nothing to show under current filters.
            if (not includeNonSecret) and (not includeUnknown) and (cSecret + cMixed == 0) then
                -- all-clear
            elseif (not includeNonSecret) and includeUnknown and (cSecret + cMixed + cUnknown == 0) then
                -- clear-only
            else
                if maxApisPerEntity > 0 and apiShown >= maxApisPerEntity then
                    apiHidden = apiHidden + 1
                else
                    apiShown = apiShown + 1

                    local line = string.format("  - %s  paths: secret=%d mixed=%d", apiS, cSecret, cMixed)
                    if includeUnknown then
                        line = line .. string.format(" unknown=%d", cUnknown)
                    end
                    if includeNonSecret then
                        line = line .. string.format(" clear=%d", cClear)
                    end
                    out[#out + 1] = line

                    for _, path in ipairs(pathNames) do
                        local st = paths[path]
                        local cls = _cls_from_counts(st.s, st.n)

                if cls == "nonsecret" and not includeNonSecret then
                    -- skip
                elseif cls == "unknown" and not includeUnknown then
                    -- skip
                else
                    if maxPathsPerApi > 0 and shown >= maxPathsPerApi then
                        hidden = hidden + 1
                    else
                        shown = shown + 1
                    if cls == "mixed" then
                        local secK, clrK = _ctx_split(st)
                        out[#out + 1] = string.format("      %s: %s  secret_in=[%s] clear_in=[%s]",
                            path, cls, _join_limit(secK, maxCtxPerPath), _join_limit(clrK, maxCtxPerPath))
                    elseif cls == "secret" then
                        local secK, _ = _ctx_split(st)
                        out[#out + 1] = string.format("      %s: %s  ctx=[%s]", path, cls, _join_limit(secK, maxCtxPerPath))
                    else
                        out[#out + 1] = string.format("      %s: %s", path, cls)
                    end
                    end
                end
                    end
                    if hidden > 0 then
                        out[#out + 1] = string.format("      … (+%d more paths truncated; raise maxPathsPerApi to show)", hidden)
                    end
                end
            end
        end

        if apiHidden > 0 then
            out[#out + 1] = string.format("  … (+%d more APIs truncated; raise maxApisPerEntity to show)", apiHidden)
        end

        out[#out + 1] = ""

        end -- compact clear-only gate

            end -- maxEntities gate
        end
    end

    if truncatedEntities > 0 then
        out[#out + 1] = string.format("… (+%d more entities truncated; raise maxEntities to show)", truncatedEntities)
        out[#out + 1] = ""
    end

	-- ---------------------------------------------------------------------
	-- Index-only auras (spellId is secret/unknown)
	-- These are tracked via case keys like: auraIdx:<unit>:<filter>:<index>
	-- They cannot be grouped by spellId, but should still appear in reports.
	-- ---------------------------------------------------------------------
	local maxIdxAuras = tonumber(opts.maxIdxAuras) or 20
	local idxAuras = {}
	local idxOrder = {}

	local function get_idx(caseKey)
		local e = idxAuras[caseKey]
		if not e then
			e = { caseKey = caseKey, packs = {}, apis = {}, _hasS = false, _hasN = false }
			idxAuras[caseKey] = e
			idxOrder[#idxOrder + 1] = caseKey
		end
		return e
	end

	for apiKey, apiNode in pairs(obs) do
		local apiS = _api_short(apiKey)
		for caseKey, caseNode in pairs(apiNode or {}) do
			if type(caseKey) == "string" and caseKey:match("^auraIdx:") then
				local e = get_idx(caseKey)
				local a = e.apis[apiS]
				if not a then a = { paths = {} }; e.apis[apiS] = a end
				for path, stat in pairs(caseNode or {}) do
					-- Deterministic aggregation (defensive; caseKey is already unique).
					a.paths[path] = _mergeStat(a.paths[path], stat)
					if type(stat.bySrc) == "table" then
						for src in pairs(stat.bySrc) do
							if type(src) == "string" and src ~= "" then
								e.packs[src] = true
							end
						end
					end
					local s = tonumber(stat.s) or 0
					local n = tonumber(stat.n) or 0
					if s > 0 then e._hasS = true end
					if n > 0 then e._hasN = true end
				end
			end
		end
	end

	if #idxOrder > 0 then
		table.sort(idxOrder)
		out[#out + 1] = "Index-only auras (spellId secret/unknown): " .. tostring(#idxOrder)
		out[#out + 1] = "(grouped by auraIdx key; shown only when secret/mixed unless includeNonSecretEntities=true)"
		out[#out + 1] = ""

		local shown = 0
		for i = 1, #idxOrder do
			if shown >= maxIdxAuras then break end
			local e = idxAuras[idxOrder[i]]
			local overall = _cls_from_counts(e._hasS and 1 or 0, e._hasN and 1 or 0)

			if overall == "nonsecret" and not includeNonSecretEntities then
				-- skip
			else
				shown = shown + 1
				local packs = {}
				for p in pairs(e.packs or {}) do packs[#packs + 1] = p end
				table.sort(packs)
				out[#out + 1] = string.format("[auraIdx] %s  overall=%s%s", e.caseKey, overall,
					(#packs > 0 and ("  sources=" .. table.concat(packs, ",")) or ""))

				local apiNames = {}
				for apiS in pairs(e.apis or {}) do apiNames[#apiNames + 1] = apiS end
				table.sort(apiNames)

				local apiShown, apiHidden = 0, 0
				for _, apiS in ipairs(apiNames) do
					local a = e.apis[apiS]
					local paths = a and a.paths or {}
					local cSecret, cMixed, cClear, cUnknown = 0, 0, 0, 0
					local pathNames = {}
					for path in pairs(paths) do pathNames[#pathNames + 1] = path end
					table.sort(pathNames, function(pa, pb)
						local sa = paths[pa]
						local sb = paths[pb]
						local ca = _cls_from_counts(sa.s, sa.n)
						local cb = _cls_from_counts(sb.s, sb.n)
						local pri = { secret = 1, mixed = 2, unknown = 3, nonsecret = 4 }
						local da = pri[ca] or 9
						local db_ = pri[cb] or 9
						if da ~= db_ then return da < db_ end
						return tostring(pa) < tostring(pb)
					end)

					for _, path in ipairs(pathNames) do
						local st = paths[path]
						local cls = _cls_from_counts(st.s, st.n)
						if cls == "secret" then cSecret = cSecret + 1
						elseif cls == "mixed" then cMixed = cMixed + 1
						elseif cls == "nonsecret" then cClear = cClear + 1
						else cUnknown = cUnknown + 1 end
					end

					-- Skip APIs that have nothing to show under current filters.
					if (not includeNonSecret) and (not includeUnknown) and (cSecret + cMixed == 0) then
						-- all-clear
					elseif (not includeNonSecret) and includeUnknown and (cSecret + cMixed + cUnknown == 0) then
						-- clear-only
					else
						if maxApisPerEntity > 0 and apiShown >= maxApisPerEntity then
							apiHidden = apiHidden + 1
						else
							apiShown = apiShown + 1
							local line = string.format("  - %s  paths: secret=%d mixed=%d", apiS, cSecret, cMixed)
							if includeUnknown then line = line .. string.format(" unknown=%d", cUnknown) end
							if includeNonSecret then line = line .. string.format(" clear=%d", cClear) end
							out[#out + 1] = line

							local shownP, hiddenP = 0, 0
							for _, path in ipairs(pathNames) do
								local st = paths[path]
								local cls = _cls_from_counts(st.s, st.n)
								if cls == "nonsecret" and not includeNonSecret then
									-- skip
								elseif cls == "unknown" and not includeUnknown then
									-- skip
								else
									if maxPathsPerApi > 0 and shownP >= maxPathsPerApi then
										hiddenP = hiddenP + 1
									else
										shownP = shownP + 1
										if cls == "mixed" then
											local secK, clrK = _ctx_split(st)
											out[#out + 1] = string.format("      %s: %s  secret_in=[%s] clear_in=[%s]",
												path, cls, _join_limit(secK, maxCtxPerPath), _join_limit(clrK, maxCtxPerPath))
										elseif cls == "secret" then
											local secK, _ = _ctx_split(st)
											out[#out + 1] = string.format("      %s: %s  ctx=[%s]", path, cls, _join_limit(secK, maxCtxPerPath))
										else
											out[#out + 1] = string.format("      %s: %s", path, cls)
										end
									end
								end
							end
							if hiddenP > 0 then
								out[#out + 1] = string.format("      … (+%d more paths truncated; raise maxPathsPerApi to show)", hiddenP)
							end
						end
					end
				end
				if apiHidden > 0 then
					out[#out + 1] = string.format("  … (+%d more APIs truncated; raise maxApisPerEntity to show)", apiHidden)
				end

				out[#out + 1] = ""
			end
		end

		if #idxOrder > shown then
			out[#out + 1] = string.format("(… +%d more auraIdx keys; increase opts.maxIdxAuras to show)", #idxOrder - shown)
			out[#out + 1] = ""
		end
	end

    return table.concat(out, "\n")
end


-- --------------------------------
-- Audit (diagnostics)
-- --------------------------------
-- Produces a compact, deterministic summary to verify that aggregation works and
-- the schema DB is not exploding in cardinality.

function Schema:BuildAuditText(opts)
    if not self.db then return "(schema not initialized)" end
    opts = type(opts) == "table" and opts or {}

    local topN = tonumber(opts.topN) or 10

    local obs = self.db.obs or {}
    local apiCount = 0
    local casePairs = 0
    local rows = tonumber(self.db.meta and self.db.meta.rows) or 0

    local apiRows = {}
    local caseRows = {}

    for apiKey, apiNode in pairs(obs) do
        apiCount = apiCount + 1
        local aRows = 0
        if type(apiNode) == "table" then
            for caseKey, caseNode in pairs(apiNode) do
                casePairs = casePairs + 1
                local cRows = 0
                if type(caseNode) == "table" then
                    for _ in pairs(caseNode) do
                        aRows = aRows + 1
                        cRows = cRows + 1
                    end
                end
                caseRows[#caseRows + 1] = { caseKey = caseKey, rows = cRows, apiKey = apiKey }
            end
        end
        apiRows[#apiRows + 1] = { apiKey = apiKey, rows = aRows }
    end

    table.sort(apiRows, function(a, b) return (a.rows or 0) > (b.rows or 0) end)
    table.sort(caseRows, function(a, b) return (a.rows or 0) > (b.rows or 0) end)

    local out = {}
    out[#out + 1] = "[AUDIT]"
    out[#out + 1] = string.format("APIs=%d  (api,case)=%d  rows=%d", apiCount, casePairs, rows)

    local meta = self.db.meta or {}
    out[#out + 1] = string.format("Dropped: rows=%d paths=%d ctx=%d src=%d", tonumber(meta.droppedRows) or 0, tonumber(meta.droppedPaths) or 0, tonumber(meta.droppedCtx) or 0, tonumber(meta.droppedSrc) or 0)

    out[#out + 1] = ""
    out[#out + 1] = string.format("Top APIs by rows (N=%d):", topN)
    for i = 1, math.min(topN, #apiRows) do
        local a = apiRows[i]
        out[#out + 1] = string.format("  %2d) %s  rows=%d", i, tostring(a.apiKey), tonumber(a.rows) or 0)
    end

    out[#out + 1] = ""
    out[#out + 1] = string.format("Top cases by rows (N=%d):", topN)
    for i = 1, math.min(topN, #caseRows) do
        local c = caseRows[i]
        out[#out + 1] = string.format("  %2d) %s  rows=%d  api=%s", i, tostring(c.caseKey), tonumber(c.rows) or 0, tostring(c.apiKey))
    end

    return table.concat(out, "\n")
end
