# CLAUDE.md

## Working mode

This repository is native-first.

- iOS UI and app integration should be implemented in Swift/SwiftUI.
- Android UI and app integration should be implemented in Kotlin/Jetpack Compose.
- Shared logic should begin as shared contracts, schemas, and domain specs before introducing runtime sharing.

## Product guardrails

- Raw data is not paywalled.
- Preserve provenance and source lineage.
- Casual and power-user modes are presentation layers over one underlying model.
- Wellness-safe language only.
- Arabic/RTL readiness is a first-order concern.

## Development priorities

1. Canonical domain contracts.
2. Metric ontology seed.
3. Health source abstraction.
4. Home summary shell.
5. Metric detail shell.
6. Export shell.
7. Logging shell.
