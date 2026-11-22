# Using BADAN

BADAN brings supported health readings and your own logs together on your device. Use **Today** for a summary, **Body** for individual metrics and their sources, and **Log** to add a record. You can start without an account, a wearable, or access to your health history.

This guide follows BADAN revision `8b83fed` for iOS 1.2 (iOS 17 or later) and Android 0.1.0 (Android 8.0 or later). Health-source access and connected features depend on the device and build. [Data and privacy](DATA_PRIVACY.md) · [Android feature status](android-parity-status.md)

The sample-data walkthrough works without store access or personal health data, including in a developer build. Connecting your own readings requires a device with Apple Health or Health Connect and compatible records. The iOS coach requires a supported physical device, Apple App Attest, and a matching service environment.

## Try BADAN with sample data

1. Open BADAN and choose **English** or **العربية** on the welcome screen.
2. Continue until the app asks you to connect a health source, then choose **Explore with sample data**. The **Sample data** banner identifies synthetic readings. Leave health permissions off for this walkthrough.
3. Open **Today** and tap **Readiness** to inspect a score. Open **Body** to browse individual metrics, or use **Log** to explore the available types of entries.
4. When you are ready to use your own readings, connect your health source using the steps below. The first connection replaces the demo and can remove entries you logged while trying it. Export anything you want to keep before switching.

To keep your first personal logs separate from the demo, choose **Start empty** at onboarding. On iOS, you can also tap the **Sample data** banner or go to **Settings → Privacy & security → Manage sample data**, then choose **Delete sample data**. This can remove entries logged during the demo. On Android, choose **Start empty** during onboarding if you want an empty store.

## Connect and manage your health source

| | iOS | Android |
|---|---|---|
| Connect during setup | Choose **Connect health data**, review each group of readings, and grant the types you want BADAN to read in Apple Health. | Choose **Connect health data**, review each group of readings, and grant the types you want BADAN to read in Health Connect. |
| Connect after setup | Go to **Settings → Privacy & security → Data sources → Connect Apple Health**, then tap **Connect**. | Go to **Settings → Data & privacy → Data sources** and use the **Health Connect** card. If needed, choose **Set up Health Connect** first. |
| Change or revoke access | Open **BADAN**’s app access settings in Apple **Health** or in iOS Settings. Turn off individual read categories or all access. | Open **Health Connect → App permissions → BADAN** and switch off individual categories or remove access. On supported devices you can open Health Connect through Android Settings. |

The initial Apple Health import looks back up to 90 days. The initial Health Connect import is limited to about 30 days before permission was first granted, and it can be shorter depending on available data. Both sources require another app or a device to have saved compatible records. You can use manual logging while a source is unavailable or while your readings accumulate.

Workout routes have their own consent. On iOS, open **Data sources → Workout routes** to change **Read workout routes**. On Android, workout details show the consent entry while route reads are off, and Health Connect can withhold individual routes. You can revoke exercise access in Health Connect to stop future route reads. Revoking source access and removing saved copies are separate actions. [Data and privacy](DATA_PRIVACY.md#revoke-access-or-delete-data)

## Read a score

1. On **Today**, tap **Readiness** to open its detail. Readiness estimates how your recent overnight signals compare with your own patterns. It uses available inputs such as heart rate variability, resting heart rate, breathing rate, and sleep performance.
2. Check the score’s date and any learning or confidence message. A new or sparse history may show a learning state, a score based on fewer signals, or no score.
3. Open **How this was worked out** in the detail view to see how BADAN calculated the result. If that button is hard to find, select **Detailed** in **Detail level** and reopen the metric.

Readiness and other BADAN scores are personal wellness estimates and are intended for self-tracking. BADAN makes no diagnosis or treatment recommendation. [Readiness methodology](algorithms/readiness.md)

## Change language and detail

- **iOS** — Open **Settings → Personalization** and find **Language** or **Detail level**.
- **Android** — Find **Language** or **Detail level** directly in **Settings**.

Choose **العربية** for Arabic and a right-to-left layout. The **Arabic numerals** switch controls digit style separately. To switch back, look for **الإعدادات** (Settings), **التخصيص** (Personalization, on iOS), and **اللغة** (Language), then choose **English**.

## Export or preview a backup

1. On iOS, open **Settings → Backup & restore → Export your data**. On Android, find **Export your data** under **Settings → Data & privacy**.
2. In **Quick Export**, choose a date range and **CSV** for a spreadsheet or **JSON** for structured data. Tap **Prepare export** on iOS or **Create export** on Android, check the result, then tap **Share** to save or send the files. BADAN creates the export and its checksum manifest locally.
3. Use **Advanced builder** on iOS or **Advanced export** on Android to select particular metrics, sources, or dates. Quick exports omit medication and symptom records and workout routes. If you opt to include supported sensitive records, choose a passphrase you can retrieve later to open the file.

Choose **All time** to export the available history for the selected metrics and sources. On iOS, existing subscribers can open **Settings → Account → Manage App Store subscriptions**. Apple manages existing subscriptions and renewals.

You can use **Backup & restore → Preview a backup file** on either platform to inspect a supported BADAN JSON backup, including its contents and checksums. This version’s preview cannot write the backup back into BADAN. iOS has separate import actions for Apple Health archives and supported GPX, TCX, or CSV files. [Export format](../packages/export-schemas/src/export_bundle.md)

## Delete records or disconnect services

- **Delete your BADAN records** — On iOS, choose **Settings → Privacy & security → Data management → Delete all data**. After clearing its local records, BADAN attempts to read from Apple Health again if connected, or reloads sample data if disconnected. On Android, use **Settings → Delete all data**. The reset attempts to load sample data even when the confirmation says Health Connect data will be read again. It can reset customization preferences as well. Manual logs are lost on either platform. Export anything you need and revoke system health access first if you want to prevent later imports.
- **Remove sensitive records** — On iOS, look under **Settings → Privacy & security**. On Android, find **Sensitive records** in **Settings**. Turning off **Meds & symptoms** asks you to confirm a permanent deletion from the sensitive store. iOS also has separate controls for sensitive modules. [Sensitive record handling](DATA_PRIVACY.md#local-storage)
- **Remove your optional iOS account** — While signed in, choose **Settings → Account → Delete account**. This is separate from deleting your health history and managing an App Store subscription.
- **Turn off the iOS AI coach or methodology sharing** — Open **Log → AI coach → Manage AI coach** for the coach toggle. In this revision, sending a new question also sends earlier questions and replies from that chat. For methodology sharing, go to **Settings → Privacy & security → Send methodology feedback**. [Optional services](DATA_PRIVACY.md#optional-services)

## Get help

The iOS app has **Settings → Support**. For an issue on either platform, email [support@binjamshid.com](mailto:support@binjamshid.com) with your app version, device, OS version and steps to reproduce. A reproduction with sample data lets you explain the issue while keeping personal records private. [Support page source](legal/support.html)
