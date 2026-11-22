# Badan iOS

The SwiftUI app includes targets for the phone, iOS widgets, the watch app and its complication. XcodeGen generates the Xcode project from `project.yml`. The repository carries the shared project, schemes, and generated plists so Xcode Cloud can open a clean checkout. [Target configuration](project.yml)

## Setup and run

Use macOS with Xcode 26.x and an installed iPhone simulator runtime. Install watchOS platform support for the embedded watch target. Open the checked-in project directly. When changing the spec or target file layout, regenerate and commit the resulting shared project and plist changes using XcodeGen 2.45.4, which GitHub CI also uses.

```bash
cd apps/ios
xcodegen generate            # writes BADAN.xcodeproj from project.yml
open BADAN.xcodeproj
```

Select the **BADAN** scheme and an available iPhone simulator. During onboarding, choose **Explore with sample data** to try the local demo. The [development guide](../../docs/DEVELOPMENT.md#ios) includes the focused test command and signing requirements for physical devices.

## Source layout (`Sources/`)

| Folder | Responsibility |
|---|---|
| `Core/` | ULID, injectable Clock, unit conversion, localization (en/ar + `Loc` catalog) |
| `Domain/` | Canonical entities, day-attribution, `Ingestion/`, `Derivation/` |
| `Ontology/` | Loaders that compile `packages/*.json` into typed registries |
| `Platform/Health/` | `HealthStorePort` + `FakeHealthStore` (seed) + `HealthKitAdapter` (real boundary) |
| `Storage/` | SQLite wrapper, main database, separate SQLCipher sensitive database, migrations and repositories |
| `Export/` | CSV/JSON writers, local export runner and destination adapters |
| `DesignSystem/` | Tokens, theme, reusable components |
| `Features/` | One folder per screen: `<X>State` / `<X>ViewModel` / `<X>View` |
| `App/` | `BADANApp` entry, `AppEnvironment` (DI), `RootView` (navigation) |
| `Resources/` | Bundled `packages/` JSON (via `scripts/sync_ios_resources.sh`) |

`Tests/` holds phone unit tests. `BadanWatchTests/` tests the watch snapshot behavior under the separate `BadanWatch` scheme. Run the [SwiftUI source reachability check](../../scripts/check-reachability.py) for navigation changes.

## Conventions

- Use the app environment, services and repositories for feature access to health data.
- Use `ULID.newID()` for new local record identities and an injected `Clock` for time-dependent domain logic.
- Update English and Arabic strings together using `LocalizedString` or `Loc`. Check right-to-left layout on affected screens.
- Edit `project.yml` and regenerate for project configuration changes.
