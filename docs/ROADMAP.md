# Badan platform roadmap

Use this page to choose a contribution. It describes the scope of the current source and open verification work. An item in the original product blueprint is a proposal until it has an implementation and supporting evidence.

| Area | Available in source | Useful next contribution |
|---|---|---|
| iOS and Android phones | Permission-based native ingestion, a synthetic demo, local health records, Readiness and offline export generation. Coverage differs by source and metric. | Try the same synthetic input on each platform. Report the metric, unit, locale and difference. Keep the source's HRV method visible in comparisons. [Technical blueprint](TECHNICAL_BLUEPRINT.md) |
| Score explanations | Versioned methodology pages, confidence information and input provenance. | Improve an explanation or translation with a worked example that agrees with the algorithm. [Methodology](algorithms/README.md) |
| Export and recovery | CSV/JSON exports and a preview for supported backup bundles. Applying a preview as a restore is outside the current preview flow. | Document a file-format edge case with a synthetic fixture. Discuss restore semantics before proposing a change that writes user records. [Export compatibility](export-schema-changelog.md) |
| Watches and connected services | iOS has watch and widget consumers and optional online features. The Android Wear module provides a starting point. | Qualify snapshot display on a paired watch. Discuss scope before proposing a Wear implementation or a change that adds a permission or network transfer. [Data and privacy](DATA_PRIVACY.md) |

The [decision records](adr/) explain earlier tradeoffs. The [original product blueprint](../BADAN_MASTER_BLUEPRINT.md) and [execution plan](EXECUTION_PLAN.md) preserve longer-term ideas. Propose a specific change through the [contribution guide](../CONTRIBUTING.md). Dates and store availability belong in the release record once verified.
