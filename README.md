# Roth Secret Tester 2

Research harness for collecting and exporting observations about SecretValue behaviour. It is not a gameplay tracker.

**Version:** 1.6.4
**Interface:** 120000, 120001
**SavedVariables:** `RothSecretTesterDB`
**Optional integrations:** !BugGrabber, BugSack

## Install

Copy the `RothSecretTester` folder into `World of Warcraft/_retail_/Interface/AddOns/`, enable it on the character-selection screen, then reload the UI.

## Use

Open the harness with `/rst`. Select a DK module (BDK, FDK, or UDK); the selected module starts immediately. The Export window offers Log, Report, Full, Entity, and Raw views, with Copy and Select All actions. Results are persisted only when the client writes SavedVariables (reload, logout, or exit).

## Current development status

The v1.6.4 core-stability and export-UX stage is documented as complete. Open work includes report controls and ordering, optional data packs, SavedVariables pruning/telemetry, remaining SecretValue audit edges, live crash/dedup validation, DK module expansion, and compact export UX. See [todo.md](todo.md) and [Docs/TODO.md](Docs/TODO.md).

## Documentation

The detailed operator material is retained in [Docs/README.md](Docs/README.md), including module, database, and export references. This repository adds [ARCHITECTURE.md](ARCHITECTURE.md), [CODE_INDEX.md](CODE_INDEX.md), and [CODE_GRAPH.md](CODE_GRAPH.md) as code-navigation aids.
