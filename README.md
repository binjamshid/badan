# BADAN Native Starter

Phase 2 starter scaffold for a native-first BADAN implementation.

## Default direction

- iOS: Swift + SwiftUI
- Android: Kotlin + Jetpack Compose
- Shared: contracts/specs/docs in `packages/`

## First build target

Build one thin but real vertical slice:
1. source connection shell
2. home summary shell
3. metric detail shell
4. export shell

## Architecture note

This scaffold does not force Kotlin Multiplatform yet. It keeps the shared layer at the contracts/specification level so the team can validate product shape before increasing shared-runtime complexity.
