# Code index

| Area | Files | Responsibility |
| --- | --- | --- |
| Bootstrap and commands | `core.lua` | database initialization, module lifecycle, `/rst`, event frame |
| Safe boundary | `safe.lua` | SecretValue-safe normalization and sanitization helpers |
| Collection | `Tester/tester.lua`, `Tester/scanner.lua`, `Tester/suites.lua` | event-driven probing, scans, suites |
| DK modules | `Modules/BDK.lua`, `Modules/FDK.lua`, `Modules/UDK.lua` | interactive class-specific probes |
| Persistent data and quality | `schema.lua`, `log.lua`, `doctor.lua` | aggregation, bounded operational log, error classification |
| Presentation | `ui.lua` | main harness and export windows |
| Optional integrations | `integration.lua` | BugGrabber/BugSack availability and UI bridge |

Primary anchors: `Addon:AddFinding`, `Addon:AutoLoadOnUIOpen`, `Addon:LoadAddOnByName`, and the event frame plus `SlashCmdList["ROTHSECRETT"]` in `core.lua`.
