# BADAN — Privacy Policy

**Policy date: 9 October 2026**

**Applies to BADAN for iOS, version 1.2**

**Repository draft dated 22 November 2026.** This draft describes BADAN revision `8b83fed`. The app and hosted policy have their own published text. [Bilingual policy source](legal/privacy.html)

Your health history is stored on your device. Optional coach requests send your current question, earlier messages in the open chat and a score summary. The optional BADAN account carries purchase and referral information. Your health history stays outside the account.

## What BADAN is

BADAN organizes your own health readings and what you choose to log. You can use its core health features without an account. Optional Sign in with Apple supports purchase entitlements and referrals. BADAN receives an Apple identity token and stores a keyed hash of the app-specific identifier to recognize your account. We do not request your name or email from Apple.

BADAN is a wellness and self-tracking tool. It is not a medical device and does not diagnose, treat, or give medical advice.

## What data BADAN accesses

With your permission, BADAN reads sleep and stages, heart rate, resting heart rate and heart rate variability, VO₂ max, respiratory rate and blood oxygen, steps, active and resting energy, walking and running distance, floors climbed, weight, body fat and lean mass, blood glucose, and workouts. The permission request also includes height and sleeping wrist temperature, which are not imported. You can revoke reading access in iOS Settings or Apple Health. Workout routes require separate BADAN consent.

You choose what to log, including workouts, nutrition, hydration and notes. Optional sensitive records include medications, symptoms, journal entries, labs, cycles and pregnancy.

Lab input can use camera scans, photos you select and PDF files you choose. Text recognition runs on your device. BADAN can read consented workout routes from Apple Health or receive them in an import. BADAN does not track your live location or access contacts, microphone, calendar or an advertising identifier.

## Where your data lives

BADAN uses a local main database for ordinary readings, sources, summaries, workouts and nutrition, and a separate encrypted database for sensitive records such as medications, symptoms, glucose, journals, labs, cycles and pregnancy. Imported documents are kept in an encrypted local vault. Sensitive modules have their own controls.

BADAN requests iOS file protection and device backup exclusion for the health database directory on a best-effort basis. Depending on your display choices, a small summary can appear on widgets and your paired Apple Watch. The widget and watch cache writers in this revision do not set an explicit backup exclusion. The app has no cloud health-history sync. Choosing a share or file destination can create a copy there.

## Advertising and tracking

BADAN has no advertising or tracking SDKs and no crash reporting service. It does not track you across apps or websites.

## Optional online services

- **AI coach.** The coach is off by default. Enabling it verifies the app with Apple App Attest and obtains an installation token. The service stores a token hash and attestation metadata. Each request sends your current question, earlier questions and replies from the open chat, and the available Readiness, Effort and Sleep summary for today, with confidence, method and date when available. BADAN assembles the summary locally and shows it with the sent message. It does not automatically attach raw records. The BADAN service forwards requests through OpenRouter to a hosted AI model, with no chat-content storage in the BADAN service source. The hosted provider processes requests under its own policies. Turning off the coach clears the local token and attempts to revoke it with the service. A request already sent may finish processing.
- **Methodology feedback.** Sharing is off until you opt in, and a metric needs at least ten responses before a summary is eligible. The app schedules eligible summaries with a random delay of one to three days. The payload gives the metric and calculation method version, the response direction, a count range, whether calibration was applied, and app and format versions. The request includes an App Attest key identifier and assertion. The service uses a network address to limit requests. Stored feedback rows include the receipt day and omit the attestation key identifier, account or device identifiers, health readings and the dates of readings or answers. Stored rows have no per-user key for deletion. The server source defaults to pruning records older than 400 days when it receives a new batch. To review submitted summaries or turn sharing off, open **Settings → Privacy & security → Send methodology feedback** when available.
- **Account and purchases.** The optional account stores an account ID, a keyed hash of the Apple sign-in identifier, creation date, purchase entitlement and expiry information, and referral details including codes, rewards and their expiry. A signed-in installation can check or send entitlement information. The account service stores purchase status reported by the app. StoreKit handles purchases and restores with Apple.
- **Maps and sharing.** If you choose **Show on map** for a workout route, Apple Maps provides the background and may use the network. Export files are created locally and handed to a share or file destination you choose.

## Your control

- **Export.** Open **Settings → Backup & restore → Export your data** for CSV or JSON with a checksum manifest. The **Advanced builder** lets you choose sensitive data and workout routes separately. Exports that include sensitive records require a passphrase.
- **Clear BADAN’s records.** **Settings → Privacy & security → Data management → Delete all data** clears BADAN’s stored health records and manual logs and keeps app preferences. Afterward BADAN attempts to read eligible records again if Apple Health is connected, or loads sample data if it is disconnected. Revoke Apple Health access before clearing BADAN’s records if you want to prevent re-import. Your source records, previously saved exports and optional account are managed separately.
- **Remove sample data.** While sample data is active, open **Settings → Privacy & security → Manage sample data → Delete sample data** to start empty. This can also clear entries added during the demo.
- **Erase sensitive records.** Open **Settings → Privacy & security → Sensitive records**, switch off **Meds & symptoms**, and confirm. This permanently clears the sensitive store and imported lab documents. The store can include records beyond medications and symptoms.
- **Delete your account.** While signed in, open **Settings → Account & subscription → Delete account**. This removes the account, referral code and associated purchase entitlement records from the BADAN server. Your local records and Apple subscription are managed separately.

## Children

BADAN is not directed at children. Sign in with Apple is optional and does not request your name or email. Health history is kept on your device.

## Health data and wellness

The readings, summaries and observations BADAN shows are informational. Always consult a qualified health professional about your health.

## Changes and contact

To read the policy included with your app, open **Settings → Privacy & security → Privacy Policy**.

Questions about privacy in BADAN can go to [support@binjamshid.com](mailto:support@binjamshid.com).
