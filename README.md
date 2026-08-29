# Roth Secret Tester 2

Research harness for collecting and exporting bounded observations about SecretValue and inaccessible-value behavior on World of Warcraft Retail 12.1. It is not a gameplay tracker and must not treat restricted data as ordinary Lua values.

## Compatibility

- Game: World of Warcraft Retail / Midnight 12.1.0
- Interface: `120100`
- Version: `1.7.0`
- Verified Blizzard source baseline: `12.1.0.69497`
- SavedVariables: `RothSecretTesterDB`
- Optional integrations: `!BugGrabber`, `BugSack`

## Installation and use

Copy `RothSecretTester` into `World of Warcraft/_retail_/Interface/AddOns/`, enable it, and reload the UI.

Open the harness with `/rst`. Select a DK module (BDK, FDK, or UDK); the selected interactive module starts immediately. The Export window offers Log, Report, Full, Entity, and Raw views. Results reach SavedVariables only through sanitized, bounded ordinary primitives and tables.

## Retail 12.1 access boundary

`safe.lua` is the canonical boundary for every untrusted runtime value:

1. `canaccessvalue()` is called before `type`, comparison, formatting, indexing, key conversion, traversal, logging, or persistence;
2. inaccessible values become the ordinary marker `<inaccessible>`;
3. accessible secret values or secret tables become `<secret>`;
4. `pcall` contains errors but never authorizes use of a value;
5. `scrubsecretvalues()` is not used as a classifier or declassification mechanism;
6. ordinary accessible tables are copied with depth, item, string-length, and cycle bounds;
7. inaccessible or secret keys are normalized before indexing the sanitized output.

The deterministic `tests/safe_12_1_spec.lua` includes inaccessible proxy values whose `__index` and `__tostring` handlers fail if touched before the access gate.

## Current open work

The detailed TODO files have been moved into the implementation PR for version 1.7.0. Remaining work includes:

- export-window report toggles and deterministic secrecy/kind ordering;
- remaining suite call-site audit for direct branching, indexing, concatenation, or formatting;
- crash-origin classification and cross-module identity/dedup validation;
- optional, separately bounded data packs with explicit 12.1 access contracts;
- manual/optional SavedVariables pruning and schema-growth telemetry;
- DK module expansion;
- compact export UX and live-client verification.

No broad aura pack may be restored as a general truth source merely because it existed in an older build.

## Documentation

Detailed operator material is in [Docs/README.md](Docs/README.md), with database, module, pack, and export references. Code ownership is described in [ARCHITECTURE.md](ARCHITECTURE.md), [AGENT_GUIDE.md](AGENT_GUIDE.md), [CODE_INDEX.md](CODE_INDEX.md), and [CODE_GRAPH.md](CODE_GRAPH.md).

## Validation status

The exact committed `safe.lua` and `tests/safe_12_1_spec.lua` pass Lua syntax and deterministic mock execution. This proves the centralized helper boundary only. It does not certify every existing suite/probe call site or live Retail restricted behavior.

## License

Licensed under the [MIT License](LICENSE). Bundled or optional third-party components remain under their own notices.
