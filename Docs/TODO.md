# TODO

## Status

- Current version: **1.6.4**
- Last completed: **P0.1 / P0.3 / P0.4 (partial)**

## P0 – stability, taint safety, data quality

1) SecretValue hardening sweep
   - [x] Centralize safe helpers (`safe.lua`) for: isSecret, safe-to-string, safe key normalization.
   - [x] Normalize all keys before table-indexing in: Log / Schema / Tester.Scanner.
   - [x] Avoid tostring() / concatenation on potentially secret values in scanner key building.
   - [ ] Remaining: audit suites for any `if v then` / `t[secret]` / `.. v` patterns (edge-cases).

2) Doctor + data quality
   - [ ] Ensure every module crash is marked CRITICAL with a clear origin (`module:start`, `module:stop`, `event:handler`).
   - [x] Export shows quality summary: CLEAN / DIRTY / DIRTY (CRITICAL) with counts.

3) Entity identity (dedup)
   - [x] Spells use stable keys: `spell:<spellId>`.
   - [x] Auras use stable keys when spellId is safe: `aura:<unit>:<filter>:<spellId>`.
   - [x] Stable fallback key when spellId is secret: `auraIdx:<unit>:<filter>:<index>`.
   - [x] Schema parser supports: `spell:<id>`, `spellId=<id>`, `aura:<...>:<id>`.
   - [x] Report includes a dedicated section for `auraIdx:` (spellId secret/unknown) keys.
   - [ ] Verify dedup behavior across multiple modules (BDK/FDK/UDK) for the same aura/spell.

4) Context snapshot enrichment
   - [x] Schema context captures: encounterInProgress + bossTarget flags.
   - [x] Schema context captures: mapID + instanceID + zone/subzone.
   - [x] UI/suite context snapshot captures: mapID + instanceID + difficultyID + zone/subzone + encounter.

5) Report / logging noise control
   - [x] Export->Report hides entities that are ONLY observed as non-secret (opt-in to include).
   - [x] Findings output throttled via `db.settings.log.findingsMode` (default: off; use Export->Report).
   - [x] SavedVariables hygiene: Findings/Doctor contexts sanitized (never persist raw SecretValues or huge tables).
   - [x] Schema growth caps (rows/paths/ctx/src) with drop counters shown in report header.
   - [x] Report aggregation is deterministic across multiple case keys per id (merges per-path stats).
   - [x] Report hides API sections with nothing to show (under current filters); adds `maxApisPerEntity` cap.
   - [ ] Re-add data packs (aura/spell id lists) as optional modular pack files; current build is modules-only.

## P1 – DK module work

BDK
- Death Strike prediction: track incoming damage (5s window) from CLEU, produce predicted heal and compare to actual.
- Blood Shield: track absorb via auras + `UnitGetTotalAbsorbs` and reconcile.
- Threat on target: `UnitThreatSituation` + `UnitDetailedThreatSituation`.
- Armor + parry: `UnitArmor`, `GetParryChance`, ratings.

FDK
- Killing Machine: proc + stacks (verify correct spellId(s)).
- Pillar of Frost: buff duration + cooldown safety map.
- Breath of Sindragosa: active duration + termination reasons.
- Razorice: target debuff stack tracking (verify correct spellId).

UDK
- Diseases: Virulent Plague + Dread Plague (discover/verify spellIds, track durations).
- Pet census: combat log summon/died tracking for temporary pets.
- Ghoul/Magus counters: discover which auras/fields represent stack counts.

## P2 – UX

- Export header should clearly indicate active mode (Log / Report / Full / Entity / Raw).
- (done) Copy focuses box; use Select All + Ctrl+C.
- Add a compact export preset: max contexts per field + max fields per entity.

## v161 (core hardening)
- [x] Doctor: aggregate identical errors (unique-key dedupe) + cap unique error keys per session to prevent SV bloat.
- [x] Safe: support `issecrettable` and `scrubsecretvalues` when available; sanitize secret tables/values early.
- [x] Schema: entity summary now de-duplicates paths across multiple case keys.
- [x] Added schema audit output (export full + `/rst audit`) to verify aggregation and caps.

