# BADAN — Privacy Policy

**Last updated: 2026-07-16**
**Applies to: BADAN for iOS, version 0.1.0**

BADAN is a private, on-device health repository. This policy describes exactly
what data the app touches, where it is kept, and what it never does. It is
written to match how the app actually behaves — not as boilerplate.

The short version: **everything stays on your device.** BADAN has no servers,
no accounts, and makes no network calls. Nothing you see in the app is ever
transmitted anywhere by the app.

---

## 1. Who this is for and what BADAN is

BADAN organizes your own health readings and the things you choose to log, and
presents them back to you. There is no sign-up and no account. You do not give
BADAN a name, email, phone number, or password, because there is nowhere for
that information to go — the app has no backend.

BADAN is a wellness and self-tracking tool. It is not a medical device and does
not diagnose, treat, or give medical advice. See section 7.

## 2. What data BADAN accesses

**From Apple Health (only if you connect it).** BADAN never reads Apple Health
until you tap "Connect" and grant permission in the system HealthKit dialog. On
a grant, it reads only these categories:

- Sleep analysis
- Heart rate
- Resting heart rate
- Step count

It reads these to show them back to you and to compute the on-device summaries
you see in the app. If you never connect Apple Health, BADAN reads none of it.
You can revoke access at any time in the iOS Settings → Health screen; BADAN
also links you there.

**What you log yourself.** BADAN lets you record entries by hand, including:

- Workouts and nutrition
- Notes
- Sensitive health records — **medications and symptoms**

You choose what to enter. Nothing is required.

BADAN does **not** access your contacts, location, photos, microphone, camera,
calendar, or advertising identifier. It reads the timestamps and size of its own
database files (to show on-device storage usage) and uses the app's own
preferences store for settings — both are inside the app's private container and
declared in the app's privacy manifest.

## 3. Where your data lives

All of your data is stored **on your device only**, in two local SQLite
databases inside the app's private container:

- A **main database** for readings, sources, summaries, workouts, nutrition, and
  notes.
- A **separate, sensitive database** used exclusively for medications and
  symptoms. Keeping these in their own store lets you turn them off and
  erase them independently of everything else.

Both databases are:

- **Excluded from iCloud and device backups**, so this data is not copied off the
  device through the backup system.
- **Protected with iOS file protection** (encrypted at rest, unlocked after first
  unlock), so the files are not readable while the device is locked before first
  unlock.

There is no cloud copy, no sync, and no shared server. If you delete the app, the
databases go with it.

## 4. What BADAN does not do

In this version, BADAN:

- **Makes no network calls.** There is no server to talk to. The app has no
  networking code paths in normal operation.
- **Has no accounts and no sign-in.**
- **Uses no third-party SDKs**, no analytics, no crash reporting, no telemetry,
  and no advertising.
- **Does not track you** across apps or websites, and collects no advertising
  identifier. The bundled privacy manifest (`PrivacyInfo.xcprivacy`) declares no
  tracking and no collected data types.
- **Shares nothing automatically.** The only way data leaves the app is an export
  that you start yourself (see section 5).

## 5. Your control over your data

- **Export.** From Settings → Data & privacy → Export, you can export your data
  as CSV or JSON, accompanied by a checksummed manifest so you can verify
  integrity. The export is created on your device and handed to you (for example
  through the iOS share sheet); BADAN does not send it anywhere. What you do with
  the exported file afterward is your choice.
- **Delete everything.** Settings → Data management → "Delete all data"
  permanently deletes everything on the device across both databases, including
  anything you logged yourself. This cannot be undone.
- **Erase sensitive records separately.** Turning off "Sensitive records" in
  Settings permanently removes all medication and symptom records
  from the device — independently of the rest of your data. Re-enabling later does
  not restore anything that was removed.
- **Revoke Apple Health access** anytime in iOS Settings → Health.

## 6. Children

BADAN is not directed at children and does not knowingly request or collect
personal information from anyone. Because the app has no accounts and transmits
nothing off the device, it does not gather age or identity information at all. A
device's owner is responsible for who uses the device.

## 7. Health data and wellness

BADAN is a self-tracking and wellness tool, not a medical device. The readings,
summaries, and any observations it shows are informational only. They are not a
diagnosis and are not medical advice. Always consult a qualified health
professional about your health and before making decisions based on anything you
see in the app.

## 8. Changes to this policy

If the app's behavior changes in a way that affects your privacy, this document
will be updated and the "Last updated" date at the top will change. Because there
is no account and no server, we cannot notify you individually; the current
policy always ships inside the app (Settings → Data & privacy → Privacy Policy)
and lives in this file.

## 9. Contact

Questions about privacy in BADAN can be sent to:

> **support@binjamshid.com**

---

*This policy reflects BADAN for iOS version 0.1.0 as of 2026-07-16. The in-app
Privacy Policy screen (Settings → Data & privacy → Privacy Policy) presents the
same statements in English and Arabic.*
