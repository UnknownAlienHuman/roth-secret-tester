# Roth Secret Tester architecture

## Ownership

`core.lua` owns addon startup, database initialization, module discovery/registration, interactive-module lifecycle, legacy load-on-demand compatibility, session creation, the `/rst` command surface, and top-level event coordination.

`safe.lua` is the mandatory value-access boundary. It exposes:

- `Safe:CanAccess(value)`;
- `Safe:IsSecret(value)`;
- `Safe:SafeToString(value)`;
- `Safe:Key(value, options)`;
- `Safe:KeyNoIndex(value)`;
- `Safe:Sanitize(value, depth, options)`.

`doctor.lua`, `log.lua`, and `schema.lua` own bounded error quality, operational findings, and persistent observation aggregation. `Tester/tester.lua`, `Tester/scanner.lua`, `Tester/suites.lua`, and the BDK/FDK/UDK modules produce observations. `ui.lua` renders the harness and derived export views. `integration.lua` optionally bridges BugGrabber/BugSack.

## Load order

```text
RothSecretTester.toc
  -> core.lua
  -> safe.lua
  -> doctor.lua
  -> log.lua
  -> schema.lua
  -> integration.lua
  -> Tester/tester.lua
  -> Tester/scanner.lua
  -> Tester/suites.lua
  -> Modules/BDK.lua
  -> Modules/FDK.lua
  -> Modules/UDK.lua
  -> ui.lua
```

The tester and DK modules are packaged and TOC-loaded in the current repository. Compatibility code may still reference optional external loader/tester/pack addons, but those are not authority over the checked-in load graph.

## Retail 12.1 value boundary

Every untrusted runtime value must enter through `Safe:CanAccess` before any Lua operation that could observe or retain it. The canonical sequence is:

```text
canaccessvalue
  -> accessible?
       no  -> ordinary placeholder
       yes -> issecretvalue / issecrettable
                secret -> ordinary placeholder
                clear  -> bounded ordinary processing
```

`pcall` is only an error boundary. It does not grant access and must not precede the accessibility decision merely to test whether an operation throws.

`scrubsecretvalues` is not used as a classification or declassification mechanism. An inaccessible value is represented as `<inaccessible>`; an accessible secret value/table is represented as `<secret>`.

Key normalization follows the same boundary before indexing sanitized output. Ordinary accessible tables are copied with depth, item-count, string-length, and cycle bounds. No raw secret/inaccessible value may enter `RothSecretTesterDB`.

## Data flow

```text
module / suite / passive probe
  -> Safe access and key/sanitize boundary
  -> Addon:AddFinding / schema observation
  -> bounded log, doctor and schema owners
  -> sanitized RothSecretTesterDB
  -> derived UI/export views
```

The schema database is the durable observation source. Export text is a derived view and must not become an alternate unbounded store.

## State and caps

`RothSecretTesterDB` stores settings, sessions, schema observations, catalog data, and metadata. Existing caps such as log lines, schema rows, paths per case, contexts per path, and sources per path remain authoritative. New collections require explicit finite caps and drop telemetry before admission.

## Evidence boundary

`tests/safe_12_1_spec.lua` proves the centralized helper behavior against inaccessible proxies, secret values, secret tables, nested ordinary tables, inaccessible keys, truncation, and cycles. It does not prove that every existing suite/module call site correctly routes through `safe.lua`; that repository-wide audit remains part of the implementation PR checklist. Live API semantics require a named Retail build/context.
