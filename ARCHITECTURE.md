# Architecture

`core.lua` owns addon startup, module discovery/loading, lifecycle coordination, and the `/rst` command. In the current TOC, `Tester/` and the BDK/FDK/UDK class modules are packaged and loaded directly; the separate tester/loader addon names referenced by compatibility code are optional legacy paths. `safe.lua` provides the boundary helpers used by collection paths. Observations flow through `log.lua`, `schema.lua`, and `doctor.lua` into `RothSecretTesterDB`. `ui.lua` displays the module list, operational log, and derived export views; `integration.lua` optionally bridges BugGrabber/BugSack.

The TOC loads the core/support files before Tester and Modules, then UI. The optional tester/loader addons referenced in `core.lua` are load-on-demand integration points, not files committed in this directory.

No live API semantics are asserted here beyond the checked-in code paths.
