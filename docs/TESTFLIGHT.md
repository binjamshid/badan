# BADAN — TestFlight submission

This describes how to get the iOS app onto TestFlight. The repo is now **build- and
config-ready**; the remaining steps require your Apple credentials and must be done by you.

---

## What's already in place (in this repo)

- **App icon** — `apps/ios/App/Assets.xcassets/AppIcon.appiconset` (1024×1024, no alpha,
  App Store-compliant). Xcode generates all size variants from it. Replace `icon_1024.png`
  anytime with real artwork; the wiring stays the same.
- **Versioning** — `MARKETING_VERSION 0.1.0`, `CURRENT_PROJECT_VERSION 1` (project.yml).
  Info.plist `CFBundleShortVersionString`/`CFBundleVersion` reference them.
- **Bundle identifier** — `net.binjamshid.badan`.
- **Export-compliance** — `ITSAppUsesNonExemptEncryption = false` in Info.plist (app uses
  only standard HTTPS + SHA-256, which is exempt), so uploads skip the encryption question.
- **HealthKit** — real reads are wired (`HealthKitAdapter`), the `com.apple.developer.healthkit`
  entitlement is enabled (`apps/ios/App/BADAN.entitlements`), and the purpose string in
  Info.plist names exactly what's read. See the HealthKit note below.
- **Signing** — set to **Automatic**; `DEVELOPMENT_TEAM` is intentionally blank for you to fill.
- **Archive tooling** — `scripts/archive_ios.sh <TEAM_ID>` + `apps/ios/ExportOptions.plist`.
- Verified: Debug + Release both compile; 29 unit tests pass; icon compiles into the bundle.

## What only you can do (credential / account gated)

1. **Apple Developer Program** — enroll ($99/yr) if not already: <https://developer.apple.com/programs/>.
2. **Register the bundle ID** `net.binjamshid.badan` (Certificates, Identifiers & Profiles ▸ Identifiers).
   - Enable the **HealthKit** capability on it — the app entitlement now requests it (see note below).
3. **Create the app record** in App Store Connect (<https://appstoreconnect.apple.com>):
   - Platform iOS, name "BADAN", bundle ID `net.binjamshid.badan`, SKU (any unique string).
4. **Sign in to Xcode** with an account on that team: Xcode ▸ Settings ▸ Accounts. This lets
   Automatic signing fetch a Distribution provisioning profile — no manual certs needed.
5. **Find your Team ID** — the 10-character string in the Apple Developer portal (Membership),
   e.g. `ABCDE12345`.

## Build & upload

From the repo root, once signed into Xcode with your team:

```bash
scripts/archive_ios.sh ABCDE12345        # ← your Team ID
```

This archives Release, signs with your distribution profile, and exports
`apps/ios/build/export/BADAN.ipa`. Then upload it (this is the publishing step — you do it):

- **Easiest:** open **Transporter.app** (free, Mac App Store), sign in, drag in the `.ipa`, Deliver.
- **CLI:** create an App Store Connect API key (App Store Connect ▸ Users and Access ▸ Integrations),
  then:
  ```bash
  xcrun altool --upload-app -f apps/ios/build/export/BADAN.ipa -t ios \
    --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
  ```
- **Or skip the script entirely:** open `apps/ios/BADAN.xcodeproj` in Xcode, set your team on
  the BADAN target, Product ▸ Archive, then Distribute App ▸ TestFlight & App Store.

After the build finishes processing (a few minutes), it appears in App Store Connect ▸
TestFlight. Add internal testers (up to 100, no review needed) and they get it via the
TestFlight app. External testing (up to 10,000) needs a short Beta App Review.

## In App Store Connect before external testing / release

- **Test information** — what to test, a contact email.
- **Export compliance** — already answered by `ITSAppUsesNonExemptEncryption = false`.
- **Privacy** — a privacy policy URL and App Privacy "nutrition label". BADAN is local-first
  and stores health data only on-device; declare data collection accordingly (currently: none
  leaves the device).

## HealthKit note

As of FEAT-01, the app **actually uses** HealthKit: `HealthKitAdapter` performs real anchored
reads (sleep, heart rate, resting heart rate, steps; 90-day backfill) once a user taps "Connect
health data" in onboarding or "Connect" on the Data Sources screen. The
`com.apple.developer.healthkit` entitlement is enabled (`apps/ios/App/BADAN.entitlements`,
wired via `CODE_SIGN_ENTITLEMENTS` in `project.yml`), and the Info.plist purpose string names
exactly what's read. Users who skip connecting still get the deterministic demo dataset —
either path is honest about which one they're on (no HealthKit data is ever fabricated).

Before submitting: enable the **HealthKit** capability on the registered App ID in the Apple
Developer portal (step 2 above) — the entitlement alone doesn't provision it. Nothing else to
decide here; there's no "leave it unused" path anymore.

## Bump the build number for each new TestFlight upload

App Store Connect rejects a re-used build number. Before each upload, bump
`CURRENT_PROJECT_VERSION` in `apps/ios/project.yml` (1 → 2 → 3 …); keep `MARKETING_VERSION`
as the user-facing version (0.1.0) until you want a new version string.
