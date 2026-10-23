# Security

## Reporting a vulnerability

Use the hosting repository's private vulnerability reporting feature, when
enabled. Otherwise contact the person who supplied the release privately.
Do not publish personal documents, index databases or credentials in an issue.
Use synthetic files to demonstrate a problem.

## Credentials

The app needs no API keys. Never commit signing certificates, private keys,
notarization passwords, API tokens, local indexes or `.env` files. Signing
identities and `notarytool` credentials belong in macOS Keychain; CI secrets
belong in the hosting provider's encrypted secret store.

The repository ignores common credential/index files. CI also scans tracked
content and Git history with Gitleaks. Ignore rules alone do not remove a
credential that has already been committed: revoke it and then clean history.

## Release checks

The standard ZIP is built from an explicit app bundle and English instruction
files. It excludes source code, personal indexes and local configuration.
The build signs the bundled CLI and helper before the app and verifies the
bundle. Packaging checks that dependencies are supplied by macOS.

Community builds are ad-hoc signed and are not Apple-notarized. Users must
trust their download source and approve the first launch through macOS.
A SHA-256 checksum helps detect a damaged download; distribute it through a
trusted channel. A checksum alone does not establish the publisher's identity.

Developer ID signing and notarization can be enabled for future releases.
Neither a CI run nor the local test suite replaces testing on another Mac
with normal Gatekeeper settings. See [Releasing](docs/RELEASING.md).
