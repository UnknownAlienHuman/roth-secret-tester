# Roth Secret Tester agent guide

## Start here

Read [`RothSecretTester.toc`](RothSecretTester.toc). The TOC loads the always-on core/support layer in this order: `core.lua`, `safe.lua`, `doctor.lua`, `log.lua`, `schema.lua`, `integration.lua`, `Tester/tester.lua`, `Tester/scanner.lua`, `Tester/suites.lua`, the BDK/FDK/UDK modules, and `ui.lua`.

Target contract:

- Retail / Midnight `12.1.0`;
- Interface `120100`;
- verified Blizzard source baseline `12.1.0.69497`;
- version candidate `1.7.0`;
- one SavedVariables root: `RothSecretTesterDB`;
- optional `!BugGrabber` / `BugSack` integration only.

The tester and class modules are packaged by the current TOC. Separate tester, loader, pack, or suite addons referenced by compatibility code are optional legacy integration paths, not the checked-in runtime authority.

## Canonical value boundary

`safe.lua` is mandatory for every untrusted value returned by the client or by a probe. The first operation must be:

```lua
Safe:CanAccess(value)
```

Only after a true accessibility result may code call `type`, compare, branch, concatenate, format, convert, index, use the value as a table key, traverse it, log it, or persist it.

The approved classifications are:

- inaccessible: `<inaccessible>`;
- accessible secret value/table: `<secret>`;
- accessible ordinary primitive: bounded ordinary value;
- accessible ordinary table: bounded sanitized copy;
- cycle: `<cycle>`;
- unsupported/nonserializable type: ordinary `<type>` marker.

`pcall` contains an error but never authorizes an operation. Do not use “try the operation and see whether it throws” as a SecretValue test. Do not restore `scrubsecretvalues()` as a classifier or declassification path.

### Safe API

- `Safe:CanAccess(value)` — canonical access decision;
- `Safe:IsSecret(value)` — valid only after/through the access decision;
- `Safe:SafeToString(value)` — ordinary placeholder or bounded string conversion;
- `Safe:Key(value, options)` — normalized safe key with explicit placeholders;
- `Safe:KeyNoIndex(value)` — coarse key representation that never serializes the original value;
- `Safe:Sanitize(value, depth, options)` — bounded SavedVariables-safe copy.

Every new probe/module/suite must route keys and retained values through these helpers before calling log/schema/doctor owners.

## Runtime and data flow

`core.lua` publishes `_G.RothSecretTesterCore`, initializes DB/log/schema/doctor/integration/UI in `Addon:Bootstrap`, and routes `ADDON_LOADED`, `PLAYER_LOGIN`, and `PLAYER_REGEN_ENABLED`. `_G.RothSecretTester_RegisterModule` and `_G.RothSecretTester_RegisterListPack` are extension boundaries.

Sessions/findings flow through `Addon:NewSession` / `Addon:AddFinding` into the bounded owners:

```text
probe
  -> safe.lua access/key/sanitize
  -> log.lua / schema.lua / doctor.lua
  -> RothSecretTesterDB
  -> ui.lua derived views
```

Only one interactive module is active at a time; starting another must stop the previous module.

## State, caps and dependencies

`RothSecretTesterDB` stores capped settings, sessions, schema observations, catalog data and metadata. Preserve and test all existing caps, including log lines, schema rows, paths per case, contexts per path and sources per path. New persistent dimensions require finite limits and drop counters.

Do not persist raw SecretValues, inaccessible proxies, frame objects, API-returned tables, arbitrary userdata, functions or unbounded nested tables.

`integration.lua` must remain a no-op when `!BugGrabber` and BugSack are absent. An integration failure must not disable the core harness.

`RothSpellTracker` also uses `/rst`; coordinate any slash rename through both repositories rather than silently stealing the alias.

## Passive tester caution

The packaged passive tester may register health, power, spellcast and aura-related events and can generate substantial observations. Existing throttles, schema caps, doctor flood controls and passive auto-disable are safety features.

Patch 12.1 invalidates broad aura reads as a general truth source in restricted contexts. Do not restore removed aura/index/filter packs simply because older builds exposed those values. Each pack requires:

- an explicit access/secrecy contract;
- bounded work and storage;
- exact build/context evidence;
- fail-closed behavior;
- no managed aura side channel;
- independent module ownership.

## Open PR checklist

The root and documentation TODO files are carried into the version 1.7.0 PR. Remaining engineering work includes:

### SecretValue and data quality

- audit suites/modules for direct `if value`, `table[value]`, `.. value`, formatting and arithmetic before the safe boundary;
- classify module crashes with clear `module:start`, `module:stop` or `event:handler` origin;
- validate entity dedup across BDK/FDK/UDK and shared aura/spell observations.

### Reporting UX

- export-window toggles for clear entities, clear paths, unknown entities/paths and compact mode;
- persistence under `db.settings.export.report.*`;
- deterministic kind grouping and secrecy order `secret -> mixed -> unknown -> clear`;
- optional top-API counts in compact mode;
- explicit active export mode header.

### Packs and DK probes

- optional, separately bounded aura/spell/item packs with 12.1 access contracts;
- BDK Death Strike prediction, Blood Shield, threat, armor/parry;
- FDK Killing Machine, Pillar, Breath and Razorice;
- UDK diseases, pet census and ghoul/magus counters.

### SavedVariables hygiene

- manual and optional bounded pruning of stale contexts/entities;
- schema-growth telemetry for rows, paths, contexts, sources and dropped counters;
- compact export preset with finite per-entity/context limits.

## Change routing

- startup/DB/module/tester/loader lifecycle/slash: `core.lua`;
- access, safe keys and serializable boundaries: `safe.lua`;
- error classification/flood protection: `doctor.lua`;
- operational log/findings: `log.lua`;
- observation schema/caps/report source: `schema.lua`;
- passive tester/scanner/suites: `Tester/tester.lua`, `Tester/scanner.lua`, `Tester/suites.lua`;
- DK probes: `Modules/BDK.lua`, `Modules/FDK.lua`, `Modules/UDK.lua`;
- UI/export/filtering: `ui.lua`;
- optional bug bridge: `integration.lua`;
- deterministic safe-boundary regression: `tests/safe_12_1_spec.lua`.

## Verification

Run the exact helper regression:

```sh
texlua --luaconly safe.lua
texlua --luaconly tests/safe_12_1_spec.lua
texlua tests/safe_12_1_spec.lua safe.lua
```

Expected result:

```text
safe_12_1_spec: PASS
```

The test uses inaccessible proxy values whose `__index` and `__tostring` handlers throw, accessible secret values, secret tables, inaccessible table keys, ordinary nested data, truncation and cycles.

Before release, parse every Lua file, run all deterministic tests, perform static call-site searches for direct unsafe operations, and execute live clear/secret/inaccessible/secret-table/proxy cases on the named Retail build. Verify exports/logs/SavedVariables contain ordinary sanitized data only and that access changes do not create repeating error loops.

Current offline evidence proves `safe.lua` only. It does not prove every existing suite/module call site or live API behavior.
