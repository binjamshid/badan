# Architecture Decision: Swift + Kotlin vs Flutter

## Summary

Both options are viable, but BADAN leans toward **Swift + Kotlin** because health-heavy apps benefit from stronger platform intimacy, especially for HealthKit, background execution, widgets, watch surfaces, permissions, and highly native interaction quality.

## Recommendation

### Prefer Swift + Kotlin when
- HealthKit excellence is a product differentiator.
- Apple Watch, widgets, complications, and background sync matter early.
- Android parity should still feel native rather than bridged.
- The team can sustain two client codebases with shared product/domain contracts.
- Long-term platform depth matters more than short-term UI speed.

### Prefer Flutter when
- team velocity with one UI stack is the dominant concern
- early UI experimentation matters more than platform-specific polish
- native health/platform integrations can live behind bridge layers
- watch/widget/platform-depth features can trail the main app roadmap

## BADAN-specific judgment

BADAN is not a normal CRUD app. It is a health-data product with:
- heavy OS-level integration
- background ingestion and permission nuance
- probable future Apple Watch / Wear OS surfaces
- dense charts and detail screens
- strong localization and RTL needs
- user trust requirements around provenance and native-feeling system integration

That makes **Swift + Kotlin the safer strategic default**.

## Practical compromise

Use an architecture-first monorepo that keeps the decision reversible for a short period:
- shared specs and data contracts in `packages/`
- parallel placeholders for `apps/ios`, `apps/android`, and `apps/flutter`
- run two prototype slices before committing fully

## Suggested evaluation slices

1. Health ingestion + provenance + daily home summary
2. Metric detail screen + export flow
3. Permission flows + background refresh behavior
4. Arabic/RTL UI stress test

## Decision deadline

Commit after prototype comparison, not after prolonged abstract debate.
