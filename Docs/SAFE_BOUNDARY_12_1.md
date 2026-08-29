# Retail 12.1 value-access boundary

**Target:** World of Warcraft Retail 12.1.0  
**Interface:** `120100`  
**Verified source baseline:** `12.1.0.69497`

This contract applies to every probe, suite, module, scanner, passive event handler, log row, schema row, Doctor finding, export field, table key, and SavedVariables value in Roth Secret Tester.

## 1. Required order

An untrusted value returned by the client must not be treated as ordinary Lua data until accessibility has been decided.

```text
untrusted value
  -> canaccessvalue(value)
       false / inaccessible
         -> ordinary fixed marker: <inaccessible>
       true / accessible
         -> issecretvalue(value) and, for accessible tables, issecrettable(value)
              secret
                -> ordinary fixed marker: <secret>
              clear
                -> bounded ordinary processing
```

`Safe:CanAccess`, `Safe:IsSecret`, `Safe:SafeToString`, `Safe:Key`, `Safe:KeyNoIndex`, and `Safe:Sanitize` implement this boundary.

## 2. Operations forbidden before the access decision

Do not perform any of the following on an untrusted value before `Safe:CanAccess(value)` returns true:

- `type(value)`;
- `value == nil`, equality or ordering comparisons;
- boolean branching such as `if value then`;
- arithmetic;
- concatenation;
- `tostring`, `tonumber`, `string.format`, interpolation or logging;
- table lookup `table[value]` or indexing `value.key`;
- use as a table key;
- iteration through `pairs`, `ipairs`, `next`, length or array bounds;
- sorting, hashing, deduplication or identity construction;
- storage in an observation, cache, closure, timer, queue or SavedVariables;
- error-message construction containing the raw value.

A value can change accessibility between calls. An earlier successful check does not authorize retaining and reading the raw value later.

## 3. `pcall` is not authorization

This is invalid:

```lua
local ok, text = pcall(tostring, value)
if ok then
    Log(text)
end
```

The absence of an error does not establish an access contract and can change across contexts. Use:

```lua
local text = Safe:SafeToString(value)
```

`pcall` remains appropriate around API calls and ordinary processing after the access decision, solely to contain implementation errors.

## 4. No declassification by scrubbing

`scrubsecretvalues()` is not a classifier, access check, or declassification primitive. The harness must not use a scrubbed result to infer the original value, secrecy class, table shape, count, key set, identity, or absence.

## 5. Safe keys

Keys require the same access boundary as values. Normalize the key before indexing the destination table:

```lua
local safeKey = Safe:Key(rawKey, {
    collapseNumbers = true,
    inaccessiblePlaceholder = "<inaccessible_key>",
    secretPlaceholder = "<secret_key>",
})
output[safeKey] = Safe:Sanitize(rawValue, depth, options)
```

Never attempt `output[rawKey] = ...` first. Inaccessible and secret keys intentionally collapse to ordinary markers; the schema must not claim distinct hidden identities or counts from those markers.

## 6. Bounded ordinary table copies

`Safe:Sanitize` may enumerate only an accessible ordinary table that is not marked secret. Every admitted copy requires finite limits:

- maximum depth;
- maximum items per table;
- maximum string length;
- cycle detection;
- unsupported-type replacement;
- explicit truncation/drop telemetry at the durable owner.

Raw API-returned tables must not be retained for later processing. Copy only the ordinary bounded fields needed by the observation contract.

## 7. Persistent-data boundary

`RothSecretTesterDB` may contain only ordinary serializable primitives and bounded ordinary tables. It must never contain:

- SecretValues;
- inaccessible proxies;
- secret tables;
- raw API payloads;
- frames, textures or other FrameScriptObjects;
- userdata;
- functions or threads;
- unbounded nested structures;
- unbounded raw error text;
- hidden identities represented by pointer/string coercion.

Exports are derived views of sanitized durable state. Export text is not an alternate raw-data store.

## 8. Observation claims

A placeholder proves only the boundary result observed by the harness:

- `<inaccessible>` means the value was not accessible at the decision point;
- `<secret>` means the accessible value/table was classified secret by the supported predicate;
- neither marker proves hidden value equality, identity, count, shape or persistence across contexts.

Do not deduplicate hidden entities or infer transitions using placeholder equality alone.

## 9. Required regression classes

The deterministic suite must cover:

- inaccessible value whose `__tostring` throws;
- inaccessible value whose `__index` throws;
- inaccessible table key;
- accessible secret scalar;
- accessible secret table;
- ordinary nested table;
- truncation and maximum-item behavior;
- cyclic table;
- accessibility change between observations;
- repeated-event behavior without an error loop;
- SavedVariables/export verification containing ordinary sanitized values only.

`tests/safe_12_1_spec.lua` currently covers the centralized helper subset. Repository-wide call-site and live-client coverage remains a PR gate.

## 10. Review checklist for every new probe

- [ ] The source API and its 12.1 access/secrecy contract are named.
- [ ] The first operation on every returned value and key is the safe access boundary.
- [ ] No raw payload is retained across callbacks/timers/events.
- [ ] Work, storage, paths, contexts and sources have finite caps.
- [ ] Unknown/inaccessible behavior fails closed.
- [ ] The observation wording does not overclaim hidden identity or value.
- [ ] Deterministic clear/secret/inaccessible/proxy cases exist.
- [ ] Live evidence records exact build and context.
