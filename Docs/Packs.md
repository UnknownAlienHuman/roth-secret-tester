# Packs (deprecated)

This build is **modules-only** (BDK/FDK/UDK).

Earlier versions used "packs" as a separate user-facing concept (data-only lists of spell IDs / aura IDs / item slots). That created terminology confusion and duplicated entries.

## Current approach

- Seed lists live **inside each module** (see `Modules/BDK.lua`, `Modules/FDK.lua`, `Modules/UDK.lua`).
- The canonical dataset is the SavedVariables schema: `RothSecretTesterDB.schema`.
- Export (Report mode) generates a de-noised view: one entry per entity (spell/aura ID), then fields and the contexts where each field is secret/clear.

## If you need to add more IDs

Edit the corresponding module and extend its seed lists (spells, auraIDs, items). Keep lists broad; rely on Report mode to remove noise.
