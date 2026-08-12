# Roth Secret Tester 2

Purpose: collect **SecretValue** behavior datasets (what APIs/fields are secret, and how they behave) so you can later build addons that:

- avoid unsafe operations (tostring/concat/table keys) on secret returns
- choose stable, non-secret API alternatives when they exist
- build class-specific trackers using only safe primitives

This addon is a **research harness**, not a gameplay tracker. It stores results in SavedVariables and exposes a copy/export window (Report/Entity/Full modes).

## Concept model

This build is **modules-only**.

- **Module**: an interactive probe (event-driven), start/stop life cycle.
  - `BDK` – Blood DK probe
  - `FDK` – Frost DK probe
  - `UDK` – Unholy DK probe

Internally the addon still runs scripted probe functions, but they are **not** exposed to the user as separate entities.

## Main workflow

1. Open UI → a **new session** is created (label `ui`).
2. Pick a **Module (BDK/FDK/UDK)** from the left list → it starts immediately.
3. Click **Export**. The window opens in **Log** mode (same as the main window). Switch to **Report/Full/Entity/Raw** as needed. Use **Copy** or **Select All** and Ctrl+C.
4. When you want to wipe everything: **Reset DB**.

## Where data is stored

All results are stored in `SavedVariables: RothSecretTesterDB`:

- `sessions[]`: human-readable session log lines + errors
- `schema`: deduplicated observation store used by export summaries

### Single source of truth

There are three UI surfaces, but only one database:

1) **SavedVariables DB** (`RothSecretTesterDB.schema`) — authoritative, persistent across reloads.
2) **In-addon "chat" panel** — operational runtime log (what started, what ran, errors, DB-updated notice). It is capped per-session.
3) **Export window** — a derived, grouped snapshot computed from the SavedVariables schema.

## Operational log levels and "Doctor" severity

The in-addon "chat" is an *operational* log. Each line is prefixed:

- `[HH:MM:SS][I][TAG] ...` for INFO
- `[HH:MM:SS][W][TAG] ...` for WARN
- `[HH:MM:SS][E][TAG] ...` for ERROR
- `[HH:MM:SS][C][TAG] ...` for CRITICAL

Tags include: `CORE`, `SESSION`, `TESTER`, `MODULE`, `DB`, `DOCTOR`.

The **Doctor** classifies errors into:
- `tested_api` (expected restrictions / secret-value behavior) → usually `WARN`
- `addon_bug` (our code issue) → `ERROR` or `CRITICAL`
- `unknown` → `ERROR`

Module lifecycle crashes (`Start/Stop`) are always marked **CRITICAL**.

The Export window includes a `Data quality:` line derived from session severity counts, so you can quickly see whether a run was clean or had failures.


## SavedVariables write semantics

WoW addons cannot write arbitrary files. They can only mutate Lua tables in memory; the client serializes SavedVariables to disk on **Reload UI / Logout / Exit**.

The **Export window does not require** a `/reload`: it reads the current in-memory database. However, if you want your newly collected data to survive a client crash or a full game restart, you should `/reload` (or logout/exit) at convenient checkpoints.

This addon therefore keeps a compact aggregated database (`schema`) and caps per-session text logs (`maxLinesPerSession`) to prevent multi-context testing from creating megabytes of SV.

## Files

- `Docs/Modules.md`: module interface + template
- `Docs/DK.md`: DK-specific probing checklists (Blood/Frost/Unholy)
- `Docs/Database.md`: how the SecretValue database is aggregated (and how to avoid log bloat)
- `Docs/Export.md`: export modes and copy workflow
- `Docs/TODO.md`: remaining work items
