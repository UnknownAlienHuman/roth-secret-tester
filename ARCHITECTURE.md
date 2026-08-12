# Architecture

`core.lua` owns addon startup, module discovery/loading, lifecycle coordination, and the `/rst` command. `safe.lua` provides the boundary helpers used by collection paths. `Tester/` runs suites and scanner logic; class-specific DK probes live in `Modules/`. Observations flow through `log.lua`, `schema.lua`, and `doctor.lua` into `RothSecretTesterDB`. `ui.lua` displays the module list, operational log, and derived export views; `integration.lua` optionally bridges BugGrabber/BugSack.

The TOC loads the core/support files before Tester and Modules, then UI. The optional tester/loader addons referenced in `core.lua` are load-on-demand integration points, not files committed in this directory.

No live API semantics are asserted here beyond the checked-in code paths.
