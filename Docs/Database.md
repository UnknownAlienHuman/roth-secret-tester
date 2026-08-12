# Database model (SecretValue map)

Goal: run tests in many contexts (city / dummy / M+ / raid / open world) without producing kilometer-long logs.

## Constraints

- Addons cannot append to arbitrary text files. They can only update in-memory Lua tables; the game writes SavedVariables on **Reload UI / Logout / Exit**.
- The Export/Report window reads the live in-memory DB (same table). You do **not** need /reload before exporting.
- SecretValue behavior is usually controlled by a small set of dimensions (combat lockdown, instance type, group state, difficulty).

## What we store

### 1) Aggregated observations: `db.schema`

`schema` is the primary database. Each observation is keyed by:

- `apiKey`: the API call signature (e.g. `C_Spell.GetSpellCooldown(Pillar of Frost(51271))`)
- `caseKey`: the *subject* being tested (e.g. `spell:51271`, `aura:target:HARMFUL:191587`)
- `path`: a normalized return path (`ret#1.startTime`, `ret#1.[*]...`)

For each (apiKey, caseKey, path) we keep only counters:

- `s`: how many times the value was secret
- `n`: how many times it was non-secret
- `byCtx`: per-context counters

Context keys are compact strings, e.g.:

- `c=0|inst=none|g=solo`
- `c=1|inst=party|g=party|d=23`

### 2) Human log (bounded): `sessions[].lines`

The UI "chat" log is operational only. It is capped by `settings.maxLinesPerSession` (default 600) to prevent SV bloat.

Each line is prefixed with `[time][level][tag]`.

### 3) Error + quality metadata: `sessions[].errors` and `sessions[].quality`

The **Doctor** records structured errors into `sessions[].errors` and maintains `sessions[].quality` summary counters.

This is used by Export to label a run as `Data quality: CLEAN` vs `DIRTY` (and `DIRTY (CRITICAL)`), so you can decide whether to trust a session's metrics.

## How this answers “where is it secret?”

Because `caseKey` is stable and spell/aura-centric, you can query:

- all rows where `caseKey` starts with `spell:` → per-spell API/field secrecy map
- all rows where `caseKey` starts with `aura:`  → per-aura secrecy map

Export already outputs per-context classifications (`secret/nonsecret/mixed`).

## Recommended workflow

1. Pick spec pack (Blood/Frost/Unholy) and run in:
   - city (out of combat)
   - dummy (combat)
   - instance (party/raid)
2. Use **Export Summary** and filter by `caseKey` prefix (`spell:` or `aura:`).
3. Only when you need raw detail: enable `tester.printClearObs=true` temporarily.

## What NOT to store

Do not store raw return values or full tables. For SecretValue research you only need:

- whether a path is secret
- which contexts trigger secrecy
- optional type counts for non-secret values
