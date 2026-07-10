# ADR-0004 — Sensitive-plus namespace and encryption posture

- Status: Accepted
- Date: 2026-07-10

## Context

Medications, symptoms, and conditions are more sensitive than sleep or steps. "Disable this
module and remove its data" must be a hard guarantee, not a best-effort row delete.

## Decision

Sensitive-plus entities (medication regimens, adherence events, symptom entries, conditions)
live in a **separate physical database file** (`badan_sensitive.db`), distinct from the main
`badan.db`. Disabling those modules purges by **deleting the file** (`purgeSensitiveNamespace`)
— the main DB is untouched. Export includes this namespace only when `includeSensitive` is
explicitly enabled.

**Encryption posture (MVP, stated honestly):** the MVP relies on OS file-level encryption
(iOS Data Protection; Android FBE on the eventual port). SQLCipher is **not** yet adopted.

## SQLCipher decision (tracked, M4)

Adopting SQLCipher is a deliberate future decision, needed before sync or passphrase-protected
export. It is flagged, not silently assumed.

## Consequences

- Module-disable is mechanically trustworthy (file gone, main DB intact).
- Extra care needed at the repository seam (two connections); handled by `LoggingRepository`.
