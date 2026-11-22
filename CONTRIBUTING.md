# Contributing to Badan

This workflow applies to revisions the rights holders have publicly released. If you have access to a private checkout, keep its code, history, and patches within the authorized audience until the owner releases the relevant material.

## From issue to pull request

1. Search the existing issues and pull requests. Use the bug form for a reproducible problem and the feature form for a proposal. Small documentation fixes can go straight to a pull request. Report potential security or privacy problems privately. [Security policy](SECURITY.md)
2. Discuss changes to data collection, health methodology, permissions, exports, or shared contracts before implementing them. Explain which platforms and existing users the change affects.
3. Fork the published repository, clone your fork, and create a topic branch from the upstream default branch. Set up the platform you are changing and use the smallest relevant local check. [Development guide](docs/DEVELOPMENT.md)
4. Open a pull request from your branch to the upstream default branch. Link any issue, describe the behavior change and why it matters, and list the checks you ran and their results. Identify affected platforms and any checks still pending. Credit the people who contributed and preserve upstream notices. [Code of conduct](CODE_OF_CONDUCT.md)

Use invented data for reproductions, fixtures, and screenshots. If a log excerpt is useful, share only the relevant sanitized lines. Keep real health information, exports, account or device identifiers, credentials, and raw production logs out of issues, pull requests, and fork history.

## Licensing your changes

The source-available Binjamshid Public Fork License, Version 1.0, applies to covered software the rights holders publicly release under it. By submitting a covered contribution, you offer the changes you own under that same license. Submit material you have the right to share and identify any separately licensed material with its source, license, and required notices. [License](LICENSE)

Section 4 requires corresponding source for every modified version, including local and uncommitted edits, in a public version-control repository under the same license. Publish within 30 calendar days of making a change or before distributing the modified version or letting others use it as a service, whichever comes first. A public fork can meet the publication requirement independently of upstream review. Follow the license for downloadable history, redistribution notices, and the limited exception for security fixes. [License](LICENSE)

## Shared contracts and platform parity

- Update the canonical source under `packages/` first. Regenerate the platform mirrors that consume it and include those changes in the same pull request. Keep a shared synthetic fixture where both platforms can check the same expected result. [Technical blueprint](docs/TECHNICAL_BLUEPRINT.md) · [Domain invariants](packages/contracts/INVARIANTS.md)
- For user-facing changes, update English and Arabic together and check the affected layout in right-to-left mode as well as left-to-right mode. For changes to imports, storage, or exports, describe how existing records and files are handled and update the relevant schema, documentation, and checks.
- For a score change, explain the input or formula change, update its published methodology and algorithm version, and check both platform implementations against the same synthetic inputs where both implement the score. Preserve the version on previously derived results. [Algorithm methodology](docs/algorithms/README.md)

### Example adding a metric

Suppose you propose an absolute-temperature metric. Discuss the source and platform scope first. If the owner accepts the proposal, define its own canonical metric ID and `degC` unit in `packages/metric-ontology/registry.json`, with English and Arabic labels and the applicable provenance and sensitivity rules. Keep the existing wrist-temperature deviation metric distinct. Update any adapter that will actually supply an absolute reading. [Fixture scope](packages/fixtures/canonicalization/README.md#known-gap)

Run `bash scripts/sync_ios_resources.sh` and `bash scripts/sync_android_assets.sh` from the repository root to refresh the registry copies. Regenerate `DATA_DICTIONARY.md` with `python3 scripts/gen_data_dictionary.py`. Add an invented case to the shared canonicalization fixture where an absolute reading of `32 degF` becomes `0 degC`. Set `emittedBy` according to the adapter types and units in the source. Use an empty list for a conversion-only case. Run `scripts/check_fixture_hashes.sh --update` for the deliberate revision and run iOS `CanonicalizationParityTests` and Android `HealthConnectCanonicalParityTest`. Report the resulting canonical pair and any platform still pending in the pull request. [Fixture format](packages/fixtures/canonicalization/README.md#what-a-row-pins), [development guide](docs/DEVELOPMENT.md#shared-contract-changes)

## Review and maintainer responsibilities

The repository owner handles triage, decides which changes to merge, and owns releases. Review covers behavior, privacy, shared contracts and platform parity, health methodology where relevant, and the evidence in the pull request. The owner may seek subject-matter input and retains the merge decision.

The public contribution workflow keeps upstream write access with the repository owner. The active GitHub rules for the upstream default branch require pull requests and resolved review conversations and block direct pushes, force pushes, and branch deletion.
