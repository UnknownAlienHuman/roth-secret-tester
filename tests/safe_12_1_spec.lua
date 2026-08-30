local safePath = assert(arg[1], "usage: texlua safe_12_1_spec.lua <safe.lua>")

local inaccessible = setmetatable({}, {
    __tostring = function() error("inaccessible value was stringified") end,
    __index = function() error("inaccessible value was indexed") end,
})
local secret = {}
local secretTable = {}

_G.canaccessvalue = function(value)
    return value ~= inaccessible
end
_G.issecretvalue = function(value)
    return value == secret
end
_G.issecrettable = function(value)
    return value == secretTable
end
_G.RothSecretTesterCore = {}

assert(loadfile(safePath))()
local Safe = assert(_G.RothSecretTesterCore.Safe)

assert(Safe:CanAccess(inaccessible) == false)
assert(Safe:IsSecret(inaccessible) == true)
assert(Safe:SafeToString(inaccessible) == "<inaccessible>")
assert(Safe:Key(inaccessible) == "<inaccessible>")
assert(Safe:KeyNoIndex(inaccessible) == "<inaccessible>")
assert(Safe:Sanitize(inaccessible) == "<inaccessible>")

assert(Safe:CanAccess(secret) == true)
assert(Safe:IsSecret(secret) == true)
assert(Safe:SafeToString(secret) == "<secret>")
assert(Safe:Sanitize(secret) == "<secret>")

assert(Safe:CanAccess(secretTable) == true)
assert(Safe:IsSecret(secretTable) == true)
assert(Safe:Sanitize(secretTable) == "<secret>")

local ordinary = {
    alpha = "abcdefghijklmnopqrstuvwxyz",
    count = 42,
    flag = true,
    hidden = inaccessible,
}
local sanitized = Safe:Sanitize(ordinary, 2, { maxStringLen = 8 })
assert(sanitized.alpha == "abcdefgh…")
assert(sanitized.count == 42)
assert(sanitized.flag == true)
assert(sanitized.hidden == "<inaccessible>")

local cyclic = {}
cyclic.self = cyclic
assert(Safe:Sanitize(cyclic, 3).self == "<cycle>")

local keyTable = {}
keyTable[inaccessible] = "hidden-key"
local keySanitized = Safe:Sanitize(keyTable, 2)
assert(keySanitized["<inaccessible_key>"] == "hidden-key")

print("safe_12_1_spec: PASS")
