-- safe.lua
-- Centralized SecretValue hardening helpers for Retail 12.1.
--
-- Boundary rule:
--  - canaccessvalue() is the first operation on an untrusted runtime value.
--  - inaccessible values are never typed, compared, formatted, indexed, logged,
--    persisted, or used as table keys.
--  - pcall is an error boundary only; it never declassifies a value.

local Addon = _G.RothSecretTesterCore
if not Addon then return end

Addon.Safe = Addon.Safe or {}
local Safe = Addon.Safe

local type = type
local tostring = tostring
local tonumber = tonumber
local pcall = pcall
local pairs = pairs
local format = string.format

local canaccessvalue = _G.canaccessvalue
local issecretvalue = _G.issecretvalue
local issecrettable = _G.issecrettable

local function CanAccessValue(value)
    if type(canaccessvalue) == "function" then
        local ok, accessible = pcall(canaccessvalue, value)
        return ok and accessible == true
    end

    -- Compatibility fallback for older clients. Retail 12.1 is expected to
    -- provide canaccessvalue(), so this path is not the current authority.
    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        return ok and secret ~= true
    end

    return true
end

local function IsSecretTable(value)
    if type(issecrettable) ~= "function" then
        return false
    end

    local ok, secret = pcall(issecrettable, value)
    return ok and secret == true
end

function Safe:CanAccess(value)
    return CanAccessValue(value)
end

function Safe:IsSecret(value)
    if not CanAccessValue(value) then
        return true
    end

    if type(issecretvalue) == "function" then
        local ok, secret = pcall(issecretvalue, value)
        if ok and secret == true then
            return true
        end
    end

    -- type() is legal only after the accessibility gate above.
    if type(value) == "table" and IsSecretTable(value) then
        return true
    end

    return false
end

function Safe:SafeToString(value)
    if not CanAccessValue(value) then
        return "<inaccessible>"
    end
    if self:IsSecret(value) then
        return "<secret>"
    end

    local ok, text = pcall(tostring, value)
    if ok then
        return text
    end
    return "<tostring-error>"
end

function Safe:Key(value, opts)
    opts = (type(opts) == "table") and opts or {}

    if not CanAccessValue(value) then
        return opts.inaccessiblePlaceholder or opts.secretPlaceholder or "<inaccessible>"
    end
    if self:IsSecret(value) then
        return opts.secretPlaceholder or "<secret>"
    end

    local valueType = type(value)
    if valueType == "nil" then
        return opts.nilPlaceholder or "<nil>"
    end
    if valueType == "string" then
        if value ~= "" then
            return value
        end
        return opts.emptyPlaceholder or "<empty>"
    end
    if valueType == "boolean" then
        return value and "true" or "false"
    end
    if valueType == "number" then
        if opts.collapseNumbers then
            return opts.numberPlaceholder or "[*]"
        end
        return self:SafeToString(value)
    end

    return "<" .. valueType .. ">"
end

function Safe:KeyNoIndex(value)
    if not CanAccessValue(value) then
        return "<inaccessible>"
    end
    if self:IsSecret(value) then
        return "<secret>"
    end

    local valueType = type(value)
    if valueType == "nil" then return "<nil>" end
    if valueType == "string" then return value end
    if valueType == "number" then return "<num>" end
    if valueType == "boolean" then return value and "true" or "false" end
    return "<" .. valueType .. ">"
end

-- -----------------------------------------
-- SavedVariables-safe sanitization helpers
-- -----------------------------------------

local function Truncate(text, maxLength)
    -- Callers pass only an accessible ordinary string.
    maxLength = tonumber(maxLength) or 160
    if #text <= maxLength then
        return text
    end
    return text:sub(1, maxLength) .. "…"
end

local function SanitizePrimitive(self, value, opts)
    opts = (type(opts) == "table") and opts or {}

    if not CanAccessValue(value) then
        return opts.inaccessiblePlaceholder or opts.secretPlaceholder or "<inaccessible>"
    end
    if self:IsSecret(value) then
        return opts.secretPlaceholder or "<secret>"
    end

    local valueType = type(value)
    if valueType == "nil" then
        return nil
    end
    if valueType == "string" then
        return Truncate(value, opts.maxStringLen)
    end
    if valueType == "number" then
        if opts.collapseNumbers then
            return opts.numberPlaceholder or "[*]"
        end
        return value
    end
    if valueType == "boolean" then
        return value
    end

    return "<" .. valueType .. ">"
end

local function SanitizeValue(self, value, depth, visited, opts)
    opts = (type(opts) == "table") and opts or {}

    if not CanAccessValue(value) then
        return opts.inaccessiblePlaceholder or opts.secretPlaceholder or "<inaccessible>"
    end
    if self:IsSecret(value) then
        return opts.secretPlaceholder or "<secret>"
    end

    local valueType = type(value)
    if valueType ~= "table" then
        return SanitizePrimitive(self, value, opts)
    end

    -- Do not enumerate a table marked secret even if the table object itself is
    -- accessible in the current context.
    if IsSecretTable(value) then
        return opts.secretPlaceholder or "<secret>"
    end

    depth = tonumber(depth) or 2
    if depth <= 0 then
        return "<table>"
    end

    visited = visited or {}
    if visited[value] then
        return "<cycle>"
    end
    visited[value] = true

    local maxItems = tonumber(opts.maxItems) or 50
    local output = {}
    local itemCount = 0

    for key, child in pairs(value) do
        itemCount = itemCount + 1
        if itemCount > maxItems then
            output["<truncated>"] = format("…(+%d)", itemCount - maxItems)
            break
        end

        local safeKey = self:Key(key, {
            collapseNumbers = true,
            inaccessiblePlaceholder = "<inaccessible_key>",
            secretPlaceholder = "<secret_key>",
        })
        output[safeKey] = SanitizeValue(self, child, depth - 1, visited, opts)
    end

    visited[value] = nil
    return output
end

function Safe:Sanitize(value, depth, opts)
    return SanitizeValue(self, value, depth, nil, opts)
end
