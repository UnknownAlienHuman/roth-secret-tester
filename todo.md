# RothSecretTester2 — todo

## Stage 1 — Core stability + export UX (DONE in v1.6.4)
- [x] Export window defaults to **Log** (migration sets `db.settings.export.defaultMode="log"`).
- [x] Export window no longer opens "empty": cursor + scroll reset to top after generating text.
- [x] Copy works reliably: export box focuses on click; Select All / Copy force focus (disabled in combat).
- [x] Full export is lighter (report + audit; raw schema moved to separate **Raw** mode).
- [x] Report view no longer appears empty when everything is **clear** (auto-unhides clear entities even if unknown filters are enabled).
## Stage 2 — Reporting quality (NEXT)
- [ ] Add UI toggles in export window:
  - [ ] checkbox: show clear entities
  - [ ] checkbox: show clear paths
  - [ ] checkbox: show unknown entities/paths
  - [ ] checkbox: compact mode
  - [ ] persist to `db.settings.export.report.*`
- [ ] Improve report ordering:
  - [ ] group by kind (aura/spell) and then by secrecy (secret→mixed→unknown→clear)
  - [ ] optional: show per-entity "top APIs" even in compact mode (counts only)

## Stage 3 — Packs / suites (LATER)
- [ ] Restore/implement additional packs that were previously removed (user request):
  - [ ] Aura packs (unit/filter variants, index-based scans)
  - [ ] Spell packs
  - [ ] Item packs (if needed)
  - [ ] Keep each pack as a separate module under `Modules/`.

## Stage 4 — Performance + SavedVariables hygiene
- [ ] Add periodic SV compaction / pruning utilities (manual + optional auto):
  - [ ] prune stale contexts
  - [ ] prune entities older than N sessions
- [ ] Add schema growth telemetry in UI (rows/paths/ctx/src, dropped counters trends).
