# Death Knight module (roadmap + what to probe)

This addon is not a DK rotation helper. The DK modules exist to:

1) discover which DK-relevant APIs/fields are SecretValue
2) collect safe primitives that can later be used in gameplay addons (trackers, meters)

The current code ships with 3 modules:

- `BDK` – Blood DK
- `FDK` – Frost DK
- `UDK` – Unholy DK

## Blood DK (priority probes)

Goal: build a dataset to implement **Death Strike prediction** and core tank telemetry.

What to check:

1. **Death Strike prediction**
   - candidate inputs: last 5s damage taken, current health, max health, modifiers, healing taken debuffs
   - candidate APIs to probe (secret vs safe):
     - `UnitHealth`, `UnitHealthMax`
     - `UnitGetIncomingHeals`
     - `UnitGetTotalAbsorbs`, `UnitGetTotalHealAbsorbs`
     - `UnitStagger` (for other tanks; used as a reference of "recent damage" patterns)
   - observe whether any return values or fields are secret and which operations break.

2. **Blood Shield amount**
   - primary: aura-based (historically "Blood Shield") + `UnitGetTotalAbsorbs(player)`
   - observe aura tables from `C_UnitAuras` to learn the correct `spellId` for the build.

3. **Threat level on target**
   - probe: `UnitThreatSituation`, `UnitDetailedThreatSituation`

4. **Armor and parry**
   - probe: `UnitArmor`, `GetParryChance`, `GetCombatRating`, `GetCombatRatingBonus`

Run recommendations:

- Run `BDK` while tanking (dummy/instance/raid) to populate schema.

## Frost DK (priority probes)

1. **Killing Machine**
   - detect proc as aura (spellId may vary; verify via aura-watch)
2. **Pillar of Frost**
   - cooldown + aura duration
3. **Breath of Sindragosa**
   - buff duration remaining + resource drain behavior
4. **Razorice stacks**
   - target debuff stack tracking

Run:

- Run `FDK` in combat and on a dummy to populate schema.

## Unholy DK (priority probes)

1. **Diseases (Plague, Dread Plague)**
   - track target debuffs by `spellId` (names may be secret/unreliable)
   - use aura-watch to discover the correct IDs for your build
2. **Ghoul/Magus stacks**
   - identify which aura/buff encodes stack counters (12.0+ often uses datamined IDs)
3. **Pet census**
   - probe safe APIs around `pet`, `guardian`, `vehicle` units:
     - `UnitExists`, `UnitGUID`, `UnitName`, `UnitCreatureFamily` for `pet`
   - note: in many builds you cannot reliably enumerate all temporary pets without combat log; treat as a separate research path.

Run:

- Run `UDK` in combat to populate schema.
