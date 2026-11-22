# Maintaining Badan

## Reviewing contributions

The repository owner triages issues, reviews pull requests and selects releases. External contributors work in forks. Read the [contribution guide](../CONTRIBUTING.md) for the workflow and the [security policy](../SECURITY.md) for reports that belong in private.

GitHub requires a pull request into the default branch and resolution of review conversations before merge. The default branch is protected against deletion and force pushes. The ruleset has no bypass actors. With a sole maintainer, the general approval count is zero so the owner can merge their own pull request. A contributor's fork gives them no upstream merge permission. Maintainers review the actual checks on each pull request, including any checks skipped because a prerequisite failed.

## Preparing a source release

1. Select the exact revision and the history to publish. Review the content of the release candidate and its history, including examples, screenshots, research, and old operational notes. Keep the private review inventory outside the release.
2. Verify ownership and the applicable grants for code, text, translations, data and assets. Include the exact [project license](../LICENSE), [third-party notices](../THIRD_PARTY_NOTICES.md) and required notices for each distribution format. Use synthetic examples whose origin you can document.
3. Follow the [development guide](DEVELOPMENT.md) from a clean checkout and record the platform and focused checks that passed. Confirm the privacy guide matches that revision. Verify the private reporting mailbox and the issue and pull request forms visible to contributors.
4. Document what changed in the [changelog](../CHANGELOG.md). Record known limitations and identify the release commit. Public designation of the source and publication require the owner's release decision.
5. When distributing an app build, separately verify the binary's notices, store privacy disclosures, signing and actual upload state. Keep signing material, customer data and private operational records out of the source release.

## Fork identity and optional support

A fork should identify its maintainer, summarize its changes and give users the correct support contact. The project license grants no trademark rights. Check the applicable terms for names, logos and third-party artwork before distributing a branded fork. Voluntary support confers no extra source permissions. An official Badan purchase is governed by the app's store flow and terms. [Source license](../LICENSE) · [App EULA](legal/eula.html)
