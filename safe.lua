-- safe.lua
-- Centralized SecretValue hardening helpers.
--
-- IMPORTANT RULES (Midnight / SecretValue):
--  - Never use potentially secret values as table keys.
--  - Never concatenate or tostring() potentially secret values.
--  - Never do boolean tests on potentially secret values (if v then).
--
-- This module provides normalized, non-secret string keys and safe-to-string.

local Addon = _G.RothSecretTesterCore
if not Addon then return end

Addon.Safe = Addon.Safe or {}
local Safe = Addon.Safe

local type = type
local tostring = tostring
local pcall = pcall

-- Patch 12.0+: secret helpers
local issecretvalue = _G.issecretvalue
local issecrettable = _G.issecrettable
local scrubsecretvalues = _G.scrubsecretvalues

local function try_scrub(v)
    if type(scrubsecretvalues) ~= "function" then return true, v end
    -- Signature is documented as: scrubsecretvalues(...) -> ... where secret inputs become nil.
    local ok, r1 = pcall(scrubsecretvalues, v)
    if not ok then
        return false, v
    end
    return true, r1
end

function Safe:IsSecret(v)
    -- NOTE: in 12.0+ there are multiple secret types (values, tables).
    if type(issecretvalue) == "function" then
        local ok, r = pcall(issecretvalue, v)
        if ok and r then return true end
    end

    if type(v) == "table" and type(issecrettable) == "function" then
        local ok, r = pcall(issecrettable, v)
        if ok and r then return true end
    end

    -- Fallback: scrubsecretvalues returns nil for secret inputs.
    local okScrub, r1 = try_scrub(v)
    if okScrub and v ~= nil and r1 == nil then
        return true
    end

    return false
end

function Safe:SafeToString(v)
    if self:IsSecret(v) then
        return "<secret>"
    end
    local ok, s = pcall(tostring, v)
    if ok then return s end
    return "<tostring-error>"
end

function Safe:Key(v, opts)
    opts = (type(opts) == "table") and opts or {}

    if v == nil then
        return opts.nilPlaceholder or "<nil>"
    end

    if self:IsSecret(v) then
        return opts.secretPlaceholder or "<secret>"
    end

    local tv = type(v)
    if tv == "string" then
        if v ~= "" then return v end
        return opts.emptyPlaceholder or "<empty>"
    end

    if tv == "boolean" then
        return v and "true" or "false"
    end

    if tv == "number" then
        if opts.collapseNumbers then
            return opts.numberPlaceholder or "[*]"
        end
        return self:SafeToString(v)
    end

    return "<" .. tv .. ">"
end

function Safe:KeyNoIndex(v)
    -- Stricter key normalizer: never attempts to represent the value itself.
    -- Useful if you're unsure about toString behavior.
    if v == nil then return "<nil>" end
    if self:IsSecret(v) then return "<secret>" end
    local tv = type(v)
    if tv == "string" then return v end
    if tv == "number" then return "<num>" end
    if tv == "boolean" then return v and "true" or "false" end
    return "<" .. tv .. ">"
end

-- -----------------------------------------
-- SavedVariables-safe sanitization helpers
-- -----------------------------------------
-- Goal: never persist SecretValues or huge nested tables in SavedVariables.
-- Used by Doctor + Log samples.

local function _truncate(s, maxLen)
    if type(s) ~= "string" then return s end
    maxLen = tonumber(maxLen) or 160
    if #s <= maxLen then return s end
    return s:sub(1, maxLen) .. "…"
end

local function _sanitizePrimitive(self, v, opts)
    opts = (type(opts) == "table") and opts or {}

    if v == nil then return nil end

    -- Extra hardening: scrub first (handles cases where issecretvalue/issecrettable are absent or incomplete).
    local okScrub, scrubbed = try_scrub(v)
    if okScrub and scrubbed == nil and v ~= nil then
        return opts.secretPlaceholder or "<secret>"
    end

    if self:IsSecret(v) then
        return opts.secretPlaceholder or "<secret>"
    end

    local tv = type(v)
    if tv == "string" then
        return _truncate(v, opts.maxStringLen)
    end
    if tv == "number" then
        if opts.collapseNumbers then
            return opts.numberPlaceholder or "[*]"
        end
        return v
    end
    if tv == "boolean" then
        return v and true or false
    end

    -- Keep SavedVariables stable: represent non-serializable types as strings.
    return "<" .. tv .. ">"
end

local function _sanitizeTable(self, t, depth, visited, opts)
    if t == nil then return nil end

    -- scrub/secret check must happen BEFORE type(table) iteration
    local okScrub, scrubbed = try_scrub(t)
    if okScrub and scrubbed == nil and t ~= nil then
        return (opts and opts.secretPlaceholder) or "<secret>"
    end

    if self:IsSecret(t) then return (opts and opts.secretPlaceholder) or "<secret>" end
    if type(t) ~= "table" then return _sanitizePrimitive(self, t, opts) end

    depth = tonumber(depth) or 2
    if depth <= 0 then return "<table>" end

    visited = visited or {}
    if visited[t] then return "<cycle>" end
    visited[t] = true

    opts = (type(opts) == "table") and opts or {}
    local maxItems = tonumber(opts.maxItems) or 50

    local out = {}
    local n = 0
    for k, v in pairs(t) do
        n = n + 1
        if n > maxItems then
            out["<truncated>"] = string.format("…(+%d)", n - maxItems)
            break
        end
        -- Keys must be safe + deterministic.
        local sk = self:Key(k, { collapseNumbers = true, secretPlaceholder = "<secret_key>" })
        out[sk] = _sanitizeTable(self, v, depth - 1, visited, opts)
    end

    visited[t] = nil
    return out
end

function Safe:Sanitize(v, depth, opts)
    -- Returns a SavedVariables-safe representation.
    -- Tables are copied and bounded; non-serializable types become strings.
    return _sanitizeTable(self, v, depth, nil, opts)
end

