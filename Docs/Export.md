# Export & Report

## Modes

- **Log** (default): operational UI log (same lines as the main window).
- **Report**: human-readable schema report. One entry per spell/aura id; aggregated; by default will auto-show clear-only entities if there are no secret/mixed/unknown findings.
- **Full**: Report + Audit (no raw dump).
- **Entity**: machine-friendly Lua table. One entry per id; includes contexts and APIs.
- **Raw**: raw schema rows (apiKey/caseKey/path) + Audit. Heavy.

## Buttons

- **Select All**: focuses the box and selects all text (disabled in combat).
- **Copy**: selects all and focuses the box; press **Ctrl+C** to copy (disabled in combat).

## SavedVariables

- Export reads the live, in-memory database (`RothSecretTesterDB`). You do **not** need `/reload` before exporting.
- WoW writes SavedVariables to disk on **/reload**, **logout**, or **exit**.
