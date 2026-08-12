# Roth Secret Tester agent guide

## Start here

Read [`RothSecretTester.toc`](RothSecretTester.toc). The TOC loads the always-on core/support layer in this order: `core.lua`, `safe.lua`, `doctor.lua`, `log.lua`, `schema.lua`, `integration.lua`, `Tester/tester.lua`, `Tester/scanner.lua`, `Tester/suites.lua`, the BDK/FDK/UDK modules, and `ui.lua`. Despite compatibility comments and fallback `LoadAddOn` paths, the tester and class modules are packaged and loaded by this TOC in the current tree; separate `RothSecretTester_Tester`, `_Loader`, pack, or suite addons are optional legacy compatibility paths.

## Runtime and data flow

`core.lua` publishes `_G.RothSecretTesterCore`, initializes DB/log/schema/doctor/integration/UI in `Addon:Bootstrap`, and routes `ADDON_LOADED`, `PLAYER_LOGIN`, and `PLAYER_REGEN_ENABLED`. The global registration shims `_G.RothSecretTester_RegisterModule` and `_G.RothSecretTester_RegisterListPack` are the extension boundary. `Modules/BDK.lua`, `FDK.lua`, and `UDK.lua` register interactive modules; `Tester/tester.lua` registers the packaged tester and exposes suites/scanner/passive event collection.

Sessions and findings flow through `Addon:NewSession`/`AddFinding` -> `log.lua`/`schema.lua`; `safe.lua` sanitizes values before persistence; `doctor.lua` classifies/deduplicates errors and can disable passive testing; `ui.lua` exposes filtered entries and export modes. Only one interactive module is active at a time (`StartModule` stops the previous module).

## State, surfaces, dependencies

`RothSecretTesterDB` stores capped `settings`, `sessions`, `schema` observation tables, `catalog`, and metadata. Important caps are `maxLinesPerSession`, `schema.maxRows`, `maxPathsPerCase`, `maxCtxPerPath`, and `maxSourcesPerPath`; do not persist raw SecretValues or unbounded nested tables. `/rst show|hide|new|export|exportfull|audit|reset|bdk|fdk|udk|passive on|passive off|bugsack` is defined in `core.lua`. `RothSpellTracker` also registers `/rst`, so the alias is not uniquely owned when both addons are enabled; coordinate any rename through [this addon's issue #2](https://github.com/UnknownAlienHuman/roth-secret-tester/issues/2) and the paired tracker issue. TOC optional deps are `!BugGrabber` and `BugSack`; integration must remain a no-op when absent.

## Invariants and risks

- This addon is a SecretValue research harness. Every new probe must go through `safe.lua` and preserve log/schema caps; never use secret values as ordinary Lua keys, arithmetic operands, or persisted raw values.
- Passive mode registers `PLAYER_REGEN_*`, `UNIT_AURA`, `UNIT_POWER_UPDATE`, `UNIT_HEALTH`, and spellcast events in `Tester/tester.lua`, throttled at 0.5 seconds. It can generate large SavedVariables and CPU load; doctor flood controls and passive auto-disable are deliberate safety features.
- `LoadTester`, `LoadLoader`, and `LoadPack` can call `LoadAddOn` only out of combat. Preserve pending/error behavior and the core handshake for legacy external addons.
- UI export is a derived view; the schema DB is the source of truth. `ui.lua` has deferred export generation and combat guards.
- `ResetAll` wipes SavedVariables and reloads; treat `/rst reset` as destructive and keep it explicit.

## Change routing

- Startup/DB/module/tester/loader lifecycle/slash: `core.lua`.
- Secret-safe conversion and serializable boundaries: `safe.lua`.
- Error classification/flood protection: `doctor.lua`.
- Operational log/findings: `log.lua`.
- Observation schema/caps/report source: `schema.lua`.
- Passive tester/scanner/suites: `Tester/tester.lua`, `Tester/scanner.lua`, `Tester/suites.lua`.
- Class probes: `Modules/BDK.lua`, `FDK.lua`, `UDK.lua`.
- UI/export/filtering: `ui.lua`.
- BugGrabber/BugSack bridge: `integration.lua`.

## Verification

Static: verify TOC ordering and all references, parse every Lua file, and run `git diff --check`. In game, use `/rst new`, each class module, `/rst passive on/off`, `/rst export` and `/rst audit`, inspect caps/doctor output, test combat transitions and `bugsack` with and without optional addons, then `/reload` to confirm SavedVariables persistence. Verify no raw secret values or schema growth beyond caps. Current audit is source/static only; probe/API semantics require a live Midnight client.
