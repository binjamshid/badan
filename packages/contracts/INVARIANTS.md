# BADAN — Domain Invariants (I1–I8)

This is the canonical statement of BADAN's domain invariants — referenced as "the constitution"
by `docs/architecture.md` §2 ("Canonical domain (D-1)"). That section quotes these invariants
inline in condensed form; this file is where each one is stated and elaborated on its own, and
is the source of truth if the two ever drift. Every entity under `apps/ios/Sources/Domain/`
(and its future Android equivalent, per ADR-0006) is expected to uphold all eight.

## I1. Every health datum carries full provenance

No measurement, derived value, or logged entry exists without a record of where it came from:
source, device, ingestion path, external id, batch id, and timestamps. Provenance is embedded on
the row itself (denormalized, per D-3), not reconstructed after the fact — so "where did this
number come from" is always answerable directly from the data, never from a separate audit trail
that could fall out of sync.

## I2. Derived values append, never overwrite

A recomputation of a baseline, insight, or other derived value never mutates or deletes the prior
result in place — it appends a new row. History of "what BADAN believed at the time" is
preserved, which is what makes later derivations auditable and lets a stale or wrong derivation be
distinguished from a value that was simply superseded by better data.

## I3. Dedup suppresses, never deletes

When ingestion reconciles a likely-duplicate reading (the same walk recorded by both a phone and a
watch, for example), the loser is marked suppressed — not removed. The original row, and the
`ReconciliationDecision` that suppressed it, both remain in the database, so a dedup decision is
always reversible and always inspectable, never a silent, permanent deletion of raw data.

## I4. Manual wins for weight/BP/labs, device wins elsewhere by source priority

Reconciliation between conflicting readings for the same metric/time isn't decided by "most
recent write wins" universally. For weight, blood pressure, and lab values, a manually-entered
reading is treated as authoritative over a device reading (people correct their scale, but rarely
mis-key a number by hand). For everything else, devices are reconciled against each other by a
defined source-priority order. This is a deliberate, metric-specific rule, not a blanket policy.

## I5. Raw and derived data are separable everywhere

Every read path, export, and API can distinguish "what a source actually recorded" from "what
BADAN computed from it." Raw data (I1's provenance-carrying rows) is never silently blended with
derived values (baselines, insights) in a way that makes the two indistinguishable — this is also
what keeps the "raw data is not paywalled" product guardrail meaningful in practice.

## I6. No entity references entitlement state

Domain entities (measurements, derived values, logs, etc.) carry no notion of subscription tier,
paywall status, or feature-flag entitlement. Presentation-layer concerns (what a given build or
plan is allowed to show) live entirely outside the domain layer, so the same canonical data model
serves every presentation policy without forking or annotating the data itself.

## I7. Sensitive-plus is a separate, purgeable namespace

Medications and symptoms live in a physically separate store (a distinct database file) from
everything else, specifically so that "turn off sensitive records" can be a literal file deletion
rather than a best-effort row-by-row purge. This namespace boundary is structural, not a filtered
view over shared storage — see `Database.purgeSensitiveNamespace()`.

## I8. All ids are on-device ULIDs

Every entity id is a ULID generated on-device — no server-assigned ids, no ids that imply a
round-trip to a backend that doesn't exist. ULIDs are lexicographically sortable by creation time
and collision-resistant without coordination, which matters because BADAN has no central
authority to hand out sequential ids in the first place.
