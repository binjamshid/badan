# ADR-0008 — Passphrase-encrypted `includeSensitive` exports

- Status: Accepted
- Date: 2026-07-20
- Supersedes ADR-0004's "Encryption posture (MVP, stated honestly)" section for the **exported-file**
  case only. Device-at-rest encryption is unchanged: iOS Data Protection still protects
  `badan.db`/`badan_sensitive.db`, SQLCipher is still not adopted, and ADR-0004 still governs
  that decision. This ADR is scoped to files that leave the device through Export.

## Context

Review ledger #19 ("Sensitive health data is exported as plaintext to the temp directory") had
three remediations. Two shipped already, both visible in `ExportRunner.swift`: `.complete` file
protection on the export temp folder, and prompt deletion of plaintext export files the moment
the share sheet dismisses (or, as a backstop, an hours-not-days sweep of orphaned folders). The
third was deferred and tracked separately as FEAT-185: exported files themselves — `raw.csv`,
`derived.csv`, `events.csv`, `bundle.json`, `manifest.json` — are plain, unencrypted text. This
ADR is that deferred fix.

`docs/runbooks/disaster-recovery.md` names the same gap in its Known Gaps section: "there is no
passphrase-protected export a user could safely store off-device today." Export is BADAN's *only*
backup mechanism (there is no server, no sync — ADR-0002, ADR-0003), and `ExportCenterScreen`'s
own `sensitiveNote` copy already tells the user to "keep the file somewhere private" — a promise
the app did nothing technical to back up.

**Threat model.** By design, an export leaves BADAN's hardened container the moment the user taps
Share — that's the entire point of Export. It goes through `UIActivityViewController` to
wherever the user sends it: AirDrop, Files, Mail, a third-party app. None of that destination is
BADAN's to protect. The only portable secret in this threat model is a passphrase the user
chooses and remembers; there is no server-side key, no Keychain-synced secret that would survive
a fresh install, and (per ADR-0002) no account to recover one from. This is a narrower, more
tractable problem than "protect the file everywhere it might ever go" — it is "make the file
useless to whoever it wasn't meant for, using a secret only the intended recipient has."

**Constraints from the rest of the codebase.** D-8 (`ExportRunner`'s own header comment) forbids
networking/entitlement imports on this path — no cloud KMS, no server-issued key. `CLAUDE.md` and
every prior ADR here favor standard-library/first-party primitives over new dependencies
(ADR-0005, ADR-0007) — no bundled crypto library, no SQLCipher (that's a separate, larger,
still-deferred decision per ADR-0004, and orthogonal: SQLCipher would protect the on-device
files, not the ones already handed to the share sheet).

## Decision

An export produced with `scope.includeSensitive == true` is wrapped in one encrypted container
before it ever reaches the share sheet, using a passphrase the user types at export time.
`ExportCenterScreen` requires and validates that passphrase (entry + confirm, minimum length);
`ExportRunner.run` independently refuses to produce a sensitive export without one
(`ExportRunError.sensitiveExportRequiresPassphrase`) — the UI gate and the data-layer gate are
two enforcement points for the same rule, not one delegated to the other. A non-sensitive export
is completely unaffected: still plain CSV/JSON, no passphrase, no behavior change.

Standard primitives only, both already reachable from this codebase without a new dependency:

- **AES-256-GCM** (CryptoKit, already imported by `ExportRunner.swift`) for authenticated
  encryption — one seal covers integrity and confidentiality together, so a tampered container
  fails closed rather than silently decrypting to garbage.
- **PBKDF2-HMAC-SHA256** (CommonCrypto's `CCKeyDerivationPBKDF`, reachable via `import
  CommonCrypto` — Apple ships a system module map for it, no bridging header needed) to stretch
  the user's passphrase into a 256-bit key. CryptoKit has no PBKDF2 API, which is why this one
  piece uses CommonCrypto instead.

One container per export run, not one per file: the CSV format produces four files
(`raw.csv`/`derived.csv`/`events.csv`/`manifest.json`); rather than pay the KDF's deliberately
slow ~600k-round cost four times (or reuse one derived key across four independent GCM seals,
which is safe but adds moving parts for no benefit here), all of it is bundled into a small
custom multi-file plaintext layout, then sealed once. The JSON format's single `bundle.json` goes
through the identical mechanism with a one-entry file list — one code path for both formats,
not two.

The runner reads each already-written plaintext file back off disk, encrypts them together,
writes the single container (`export.badanenc`) under the same `.complete` file protection the
plaintext files already had, and deletes the plaintext originals immediately — before the share
sheet ever appears. This closes the tmp/ exposure window from ledger #19 even further for the
sensitive case: previously that window ran from "export finishes" to "share sheet dismisses or
the hours-later sweep fires"; for an encrypted export it now ends at "encryption finishes,"
typically well under a second later.

## Container format (byte-exact)

Implemented in `apps/ios/Sources/Export/ExportEncryption.swift` (`ExportEncryptor`); the format
version below is version `1`.

**Outer container — fixed 26-byte header, then an AES-GCM combined blob:**

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 4 | magic | ASCII `"BDNX"` |
| 4 | 1 | format version | `0x01` |
| 5 | 1 | KDF id | `0x01` = PBKDF2-HMAC-SHA256 |
| 6 | 4 | iterations | `UInt32`, big-endian |
| 10 | 16 | salt | random, freshly generated per export |
| 26 | — | AES-GCM combined | `CryptoKit`'s `SealedBox.combined`: 12-byte nonce, then ciphertext (same length as the inner plaintext below), then a 16-byte authentication tag |

**Inner plaintext** (the bytes AES-GCM encrypts/authenticates — a minimal multi-file layout, not
JSON, to avoid base64 bloat and because the outer GCM tag already authenticates every byte of it
as one unit):

| Field | Size | Notes |
|---|---|---|
| file count | `UInt16` BE | |
| *(repeated `file count` times)* | | |
| — name length | `UInt16` BE | |
| — name | UTF-8, `name length` bytes | e.g. `"raw.csv"` |
| — data length | `UInt32` BE | |
| — data | `data length` bytes | the file's exact original bytes |

No per-file checksum field: a single tampered byte anywhere in the container fails the outer
GCM tag before this layout is ever parsed, so a second integrity mechanism at this layer would be
redundant. `docs/runbooks/disaster-recovery.md`'s "recompute a checksum by hand" guidance still
applies to the manifest's existing SHA-256 checksums, which continue to describe the real
plaintext content (unaffected by whether that content ended up encrypted on disk) — a reader who
decrypts a container can still verify each file against them.

**Format stability.** `apps/ios/Tests/ExportEncryptionTests.swift` hardcodes a golden container
(fixed salt/nonce/passphrase, produced once by this exact algorithm) as a base64 fixture and
asserts this build still decrypts it correctly. A future byte-layout change must bump
`formatVersion` and add a **new** fixture alongside the existing one — old exports must keep
opening in new builds, not just new exports in old ones.

## KDF parameters chosen, and why

**PBKDF2-HMAC-SHA256, 600,000 rounds, 16-byte random salt, 256-bit derived key.**

- **Algorithm/rounds:** 600,000 matches OWASP's Password Storage Cheat Sheet (December 2023
  revision) minimum recommendation for PBKDF2-HMAC-SHA256. It is a deliberately slow, one-time
  cost paid once per export (not per app launch, not per screen render) — a few hundred
  milliseconds on an A-series/M-series iPhone, immaterial next to the rest of an export run
  (gather + write + checksum).
- **Why not Argon2id/scrypt:** both would be the stronger modern choice against GPU/ASIC
  cracking, but neither ships in CryptoKit or CommonCrypto — adopting either means a new
  third-party dependency, which this ADR's constraints (D-8, ADR-0005/0007's dependency
  discipline) rule out for this pass. Flagged below as a re-evaluation trigger, not silently
  assumed adequate forever (the same honesty pattern ADR-0004 uses for SQLCipher).
- **Salt:** 16 random bytes per export (`SecRandomCopyBytes`), so two exports of identical
  content under the same passphrase never produce the same container.
- **Key size:** 256 bits, matching AES-256-GCM.

## No-go trigger (gated)

This design is a **no-go as shipped**, and must be revisited before it ships more broadly, if
either becomes true:

1. A security review finds 600,000-round PBKDF2-HMAC-SHA256 insufficient against realistic
   offline attacker hardware for a file that may sit in a user's Files app or inbox indefinitely
   (unlike an online-guessable account password, an attacker with the file can brute-force
   offline at whatever rate their hardware allows) — in which case a memory-hard KDF (Argon2id/
   scrypt) needs its own ADR and dependency decision, not a quiet swap here.
2. Apple's export-compliance classification changes such that this feature can no longer rely on
   the app's existing `ITSAppUsesNonExemptEncryption: false` self-classification (standard
   AES/PBKDF2 used for local data protection, not sold as an encryption product) — in which case
   TestFlight/App Store submission needs the compliance paperwork updated first, not after.

## Re-evaluation gate (numeric)

Revisit `ExportEncryptor.defaultIterations` when **either**:

- OWASP raises its PBKDF2-HMAC-SHA256 minimum above 600,000 — bump to match within the next
  release after the guidance changes, same cadence as any other security-parameter update; or
- Measured KDF wall-clock time on the oldest device this app's `deploymentTarget` (iOS 17)
  actually supports exceeds **1.5 seconds**, at which point either lower the iteration count (and
  accept the corresponding cryptographic trade-off, documented at that time) or add a progress
  indicator to `ExportCenterScreen` so the wait doesn't read as the app being hung — encryption
  must never make Export feel broken.

## Consequences

- `includeSensitive` exports are meaningfully protected once they leave BADAN — the same "keep it
  somewhere private" advice now has a technical backstop, not just a warning sentence.
- `docs/runbooks/disaster-recovery.md`'s FEAT-185 gap closes; a new, honestly-stated gap replaces
  it: a forgotten passphrase makes that export permanently unrecoverable. No reset, no backend to
  recover it from (ADR-0002) — this is a deliberate design consequence of "the passphrase is the
  only portable secret," not a defect to fix later.
- An `includeSensitive` export is now one `.badanenc` file instead of several plain files —
  `ExportCenterViewModel.availableFileURLs` and `ExportManifest` (`encrypted`/
  `encryptedContainerName`) both had to learn this, since re-sharing a past export now means
  finding one container, not reconstructing filenames from `checksums.keys`.
- "Export again" for a past sensitive job can no longer silently re-run — the passphrase was
  never stored anywhere (by design). `ExportCenterScreen.handleRunAgain` reloads that job's scope
  into the form instead of re-running blind, so the passphrase fields reappear and a fresh
  passphrase is required, same as any other sensitive export.
- Decrypting is a first-class, tested capability (`ExportEncryptor.decrypt`), not an encrypt-only
  dead end — `ExportEncryptionTests.swift` covers the round trip, a wrong passphrase, a tampered
  container, and the format-stability fixture. A dedicated in-app "open an encrypted export"
  screen is not built in this pass (nothing in the app currently reads an export back in at all —
  see `docs/runbooks/disaster-recovery.md` §1 on the absence of a restore path); the internal API
  plus tests is the floor this ADR commits to, and is enough to keep the DR runbook's export
  story honest rather than making it worse.

## Addendum: Android parity (EPIC-06)

- Status: Accepted
- Date: 2026-07-22

The Kotlin mirror of this ADR's container format is implemented in
`apps/android/app/src/main/java/net/albayyan/badan/export/ExportEncryptor.kt` (`ExportEncryptor`,
`ExportContainerFile`, `ExportEncryptionException`, `ExportPassphrasePolicy`), wired into
`ExportRunner.kt`'s `run`/`encryptResult` the same way `ExportRunner.swift` wires the iOS one:
`scope.includeSensitive` without a passphrase meeting `ExportPassphrasePolicy` throws
`ExportRunException.SensitiveExportRequiresPassphrase` before any file is written, and a
successful sensitive run reads its own just-written plaintext files back off disk, seals them
into one `export.badanenc` container, deletes the plaintext, and re-persists the job with
`manifest.encrypted = true`. `AdvancedExportScreen.kt`'s passphrase entry+confirm fields
(`PassphraseFields`) gate the Run button exactly like `ExportCenterScreen`'s do, and carry the
same "BADAN never stores it. If you forget it, this export cannot be recovered." EN/AR copy
word-for-word.

No new dependency was needed: `javax.crypto` (`Cipher`/`AES/GCM/NoPadding`,
`SecretKeyFactory`/`PBKDF2WithHmacSHA256`, `Mac`/`HmacSHA256`) ships every primitive the format
requires, matching this ADR's constraint that CryptoKit/CommonCrypto on iOS and the platform JCE
on Android are both "standard primitives only, no new dependencies" — same rule, different
platform toolbox. Byte-exact agreement with the format above (magic, version, KDF id, big-endian
iteration count, salt placement, AES-GCM combined nonce/ciphertext/tag ordering, inner multi-file
layout) required one Android-specific wrinkle worth recording: JCE's `PBEKeySpec` leaves the
passphrase's `char[]` → byte encoding to the provider, and at least one provider lineage
(`PBKDF2WithHmacSHA1And8BIT`) is known to fold each character to its low 8 bits rather than use
UTF-8 — silently wrong only for non-ASCII passphrases, which is exactly BADAN's Arabic-first
case. `ExportEncryptor.kt` resolves this with a byte-exact reference PBKDF2 implementation
(`macPbkdf2`, pinned to published RFC 2898 test vectors) and a one-time per-process probe
(`fastKdfAvailable`) that only trusts the provider's faster `SecretKeyFactory` path once it has
proven, on a deliberately non-ASCII/emoji probe passphrase, that it agrees with the reference —
falling back to the reference path otherwise. `ExportPassphrasePolicy.length` also counts Unicode
extended grapheme clusters via `java.text.BreakIterator` rather than UTF-16 code units, matching
Swift's `String.count` so a passphrase of, say, ten emoji is accepted or rejected identically on
both platforms rather than Android being the more lenient one.

**Cross-platform proof.** `packages/fixtures/encryption/` holds two containers under source
control: `ios-written-v1.badanenc` (produced by the iOS `ExportEncryptor`) and
`android-written-v1.badanenc` (produced by the Kotlin one), both under the real 600,000-round
shipped default, both keyed by `manifest.json` (id, passphrase, expected plaintext, SHA-256 of
the container bytes so a mangled fixture reports as "altered in git" rather than "wrong
passphrase"). Each platform's test suite decrypts the OTHER platform's container:
`ExportEncryptorTest.iosWrittenContainerDecryptsOnAndroid` (Kotlin, reads the iOS-written file)
and `ExportEncryptionTests.testAndroidWrittenFixtureDecryptsOnIOS` (Swift, reads the
Android-written file) are the epic's acceptance criterion — byte-level container interop proven
in both directions, not just each platform round-tripping its own output. `ExportEncryptorTest`
additionally decrypts iOS's original hardcoded format-stability golden fixture
(`iosFormatStabilityGoldenContainerDecryptsOnAndroid`), and both suites assert a wrong passphrase
and a tampered Android-written container fail with the identical typed error
(`IncorrectPassphraseOrTamperedData` / `.incorrectPassphraseOrTamperedData`) as a same-platform
failure would. All of the above passed as of this addendum
(`./gradlew :app:testDebugUnitTest :app:assembleDebug`, 22/22 in `ExportEncryptorTest`).

**Known gap, stated rather than hidden:** the 600,000-round KDF has been measured on a JVM
desktop host (~110-120ms) but not yet on physical Android hardware — `ExportEncryptor.kt`'s own
doc comment on `DEFAULT_ITERATIONS` records this explicitly. The re-evaluation gate above (revisit
if wall-clock exceeds 1.5s on the oldest supported device) applies identically to Android; a real
device measurement is still owed before this gap can close.
