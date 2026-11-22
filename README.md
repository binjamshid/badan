# Badan · بدن

Badan is a local-first personal health journal for iOS and Android. It brings readings from Apple Health or Health Connect together with the things you log yourself. You can open a Readiness score to see which signals contributed, inspect individual readings and their sources, or export a date range for your own analysis. The app supports English and Arabic, including right-to-left layouts.

All features in the current source are free to use, including export for any available date range.

## Try it with sample data

Follow the [developer setup guide](docs/DEVELOPMENT.md) to run the iOS simulator or Android emulator build. During onboarding, choose **Explore with sample data**. Open **Today → Readiness** to inspect a score, then open **Body** to explore its underlying readings. You can try this without connecting a health source or signing in. The [user guide](docs/USER_GUIDE.md) explains how to switch to your own data, export it, and manage permissions.

## What the source includes

| Component | Where to start |
|---|---|
| iOS and watchOS | The SwiftUI phone app reads HealthKit with permission. Widgets and the watch app can show selected summaries. The iOS app also has optional coach, account, and methodology-feedback flows. [iOS sources](apps/ios/) |
| Android | The Kotlin/Compose phone app reads Health Connect with permission and supports local logging, scoring and exports. Sensor inputs and storage protection differ by platform. The Wear OS module is a scaffold. [Platform scope](docs/TECHNICAL_BLUEPRINT.md#platform-scope-and-parity) · [Data flows and privacy controls](docs/DATA_PRIVACY.md) |
| Shared contracts | The metric registry, localized dictionaries, algorithm parameters, export formats and synthetic conformance cases define behavior shared by the native apps. [Technical blueprint](docs/TECHNICAL_BLUEPRINT.md) · [Algorithm methodology](docs/algorithms/README.md) |
| Optional backend | The FastAPI service handles connected iOS features. The local demo runs independently of it. [Data flows and privacy controls](docs/DATA_PRIVACY.md) · [Service code](backend/api/) |

For export consumers, the [data dictionary](DATA_DICTIONARY.md) defines the fields and the [export compatibility guide](docs/export-schema-changelog.md) explains version changes. For developers, the [roadmap](docs/ROADMAP.md) distinguishes implemented features from open work.

## License and forks

Badan uses the source-available **Binjamshid Public Fork License, Version 1.0** for covered software the rights holder publicly releases under those terms. Publication requires the rights holder's authorization. Commercial use by or on behalf of a for-profit organization is prohibited. The license requires public, same-license corresponding source for modified versions, including private edits, on the timetable in section 4. Third-party components retain their own terms. Mobile app distribution has a separate EULA. [Source license](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md) · [App EULA](docs/legal/eula.html)

To propose a change to a released revision, fork it, make a topic branch, and open a pull request. The [contribution guide](CONTRIBUTING.md) covers review, licensing, and a worked example. See the [code of conduct](CODE_OF_CONDUCT.md) for community expectations and [security policy](SECURITY.md) for private reporting. Use synthetic data in examples and issue reports.
