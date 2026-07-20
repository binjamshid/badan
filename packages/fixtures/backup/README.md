# Backup fixtures (EPIC-18)

Shared golden artifacts for the full backup & restore feature. They pin **cross-platform
byte-parity**: a backup written on iOS must be byte-identical to one written on Android from the
same inputs, so a backup made on one platform restores on the other.

## Files

- `backup-v1.json` — a plaintext backup built from a frozen fixture (empty data arrays + a fixed
  config: one export template, one destination, a customization object, one schedule). Both
  platforms build from the same fixed inputs and must produce these exact bytes.
- `DATA_DICTIONARY.md` — the schema companion embedded in every backup. Zero inputs, so both
  platforms must emit it identically (a Swift multiline literal vs. a Kotlin `trimIndent()`).

The data arrays are deliberately empty here: the byte-parity of every record shape is already
pinned by `packages/fixtures/export/bundle-v1.json`. These goldens add only what `BackupBundle`
layers on top — the plaintext wrapper, the backup manifest with per-file SHA-256, and the config
echo (with destinations excluded from plaintext, per §12 EPIC-18 requirement 3).

## The tests

- iOS: `apps/ios/Tests/BackupBundleTests.swift`
- Android: `apps/android/app/src/test/java/net/albayyan/badan/BackupBundleTest.kt`

Both build the identical frozen fixture and assert byte-equality against these files.

## Regenerating (rare)

Either platform may regenerate, but a golden verified on only one platform is not a parity
fixture — the OTHER platform must then pass against it unchanged. The regenerating run always
fails so it can never be mistaken for a pass.

- iOS: `BADAN_REGENERATE_BACKUP_GOLDENS=true` in the test scheme's environment.
- Android: `BADAN_REGENERATE_BACKUP_GOLDENS=true ./gradlew :app:testDebugUnitTest --tests "net.albayyan.badan.BackupBundleTest"`

After regenerating on one platform, run BOTH suites with the switch OFF.
