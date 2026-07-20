# Cross-platform encrypted-export container fixtures

These are the artifacts that make "BADAN's encrypted export format is one format" a fact rather
than an intention. Each `.badanenc` file was produced by one platform's real shipped encryptor and
is asserted to decrypt on the **other** platform:

| Fixture | Written by | Must decrypt on | Asserted by |
|---|---|---|---|
| `ios-written-v1.badanenc` | iOS `ExportEncryptor` (CryptoKit + CommonCrypto) | Android | `ExportEncryptorTest.iosWrittenContainerDecryptsOnAndroid` |
| `android-written-v1.badanenc` | Android `ExportEncryptor` (`javax.crypto`) | iOS | `ExportEncryptionTests.testAndroidWrittenFixtureDecryptsOnIOS` |

Neither direction alone is sufficient: a shared misunderstanding of the format would still
round-trip within one platform. Both directions together are EPIC-06's acceptance criterion.

`manifest.json` carries, per container: the passphrase, the exact expected plaintext of every
inner file, the iteration count, and the container's SHA-256. Both test suites read it — the
fixtures are shared files, never copied into either platform's test sources, because a copy is one
more thing that can drift from the artifact it is supposed to police.

## Why the passphrase is not ASCII

`بادان-fixture-🌙-2026` is deliberately Arabic + an astral-plane emoji. iOS derives the key from
the passphrase's raw UTF-8 bytes; JCE's `PBEKeySpec` takes a `char[]` and leaves the char→byte
encoding to the provider, and Android's own history includes providers that fold each char to its
low 8 bits (which is why `PBKDF2WithHmacSHA1And8BIT` exists as a separate algorithm name). Under
that convention an **ASCII** passphrase derives the same key on both platforms and a non-ASCII one
silently does not. An ASCII fixture would pass while the bug shipped.

The inner file `ملاحظات.txt` exists for the same reason one level up: it exercises the UTF-8 name
field of the inner multi-file layout.

## Format

Specified in `docs/adr/ADR-0008-sensitive-export-encryption.md` and restated byte-by-byte at the
top of `apps/android/app/src/main/java/net/albayyan/badan/export/ExportEncryptor.kt`. The
reference implementation is `apps/ios/Sources/Export/ExportEncryption.swift`.

These fixtures pin container format **version 1** with the shipped 600,000-round PBKDF2 count, so
the real security parameter is exercised end to end rather than a fast test-only value.

## Regenerating (rare — read this first)

Do **not** regenerate a fixture to make a failing test pass. A failure here means the two
implementations disagree about the format, and the answer is to find out which one changed. The
whole point of a frozen artifact is that it cannot be edited into agreement.

Regenerate only when the container format version is deliberately bumped — and then regenerate
**both** halves, keeping the version-1 fixtures alongside the new ones (ADR-0008: old exports must
keep opening in new builds, so an added format version adds fixtures, it never replaces them).

**Android half** — the regeneration path lives in the test suite, gated on an environment
variable so it cannot fire during a normal run:

```sh
cd apps/android
BADAN_REGENERATE_ENCRYPTION_FIXTURES=1 ./gradlew :app:testDebugUnitTest \
  --tests "net.albayyan.badan.ExportEncryptorTest"
```

It rewrites `android-written-v1.badanenc` and then fails with the new SHA-256 to paste into
`manifest.json` — regeneration is deliberately a two-step act, so a reviewer gets a diff that says
which fixture changed and to what.

**iOS half** — compile the shipped encryptor into a small command-line tool and run it; salt and
nonce are fresh per call, so the bytes differ every time:

```sh
swiftc -O apps/ios/Sources/Export/ExportEncryption.swift <your-generator>.swift -o genfixture
./genfixture packages/fixtures/encryption/ios-written-v1.badanenc
```

The generator must call `ExportEncryptor.encrypt(files:passphrase:iterations:)` with the
manifest's passphrase, the manifest's exact plaintext file set, and
`ExportEncryptor.defaultIterations` — then update the manifest's `sha256`.
