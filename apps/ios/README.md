# BADAN iOS

The runnable SwiftUI flagship. Single Swift module (`BADAN`); the Xcode project is **generated**
from `project.yml` by [XcodeGen](https://github.com/yonyz/XcodeGen) and is git-ignored.

## Setup

```bash
brew install xcodegen        # once
cd apps/ios
xcodegen generate            # writes BADAN.xcodeproj from project.yml
```

## Build / run / test

```bash
# Build
xcodebuild -project BADAN.xcodeproj -scheme BADAN \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' build

# Test
xcodebuild -project BADAN.xcodeproj -scheme BADAN \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17' test

# Or use the repo helper (build + boot + install + launch):
../../scripts/run_ios.sh
```

Open `BADAN.xcodeproj` in Xcode to run interactively. First launch seeds a 90-day demo dataset;
**Settings → Reset demo data** re-seeds.

## Source layout (`Sources/`)

| Folder | Responsibility |
|---|---|
| `Core/` | ULID, injectable Clock, unit conversion, localization (en/ar + `Loc` catalog) |
| `Domain/` | Canonical entities, day-attribution, `Ingestion/`, `Derivation/` |
| `Ontology/` | Loaders that compile `packages/*.json` into typed registries |
| `Platform/Health/` | `HealthStorePort` + `FakeHealthStore` (seed) + `HealthKitAdapter` (real boundary) |
| `Storage/` | `SQLite/` wrapper, `Database` (two files), `Migrations`, `Repositories/` |
| `Export/` | CSV/JSON writers + `ExportRunner` (offline, no networking imports) |
| `DesignSystem/` | Tokens, theme, reusable components |
| `Features/` | One folder per screen: `<X>State` / `<X>ViewModel` / `<X>View` |
| `App/` | `BADANApp` entry, `AppEnvironment` (DI), `RootView` (navigation) |
| `Resources/` | Bundled `packages/` JSON (via `scripts/sync_ios_resources.sh`) |

`Tests/` holds domain/dedup/baseline/export/repository unit tests.

## Conventions

- Features depend on view models and repositories only — never on the DB or health adapters (D-5).
- All ids are ULIDs (`ULID.newID()`); domain code takes a `Clock`, never reads the wall clock.
- User-facing strings carry both languages (`LocalizedString` / `Loc`); no English-only screens.
- Never hand-edit generated `.xcodeproj`; change `project.yml` and re-run `xcodegen generate`.
