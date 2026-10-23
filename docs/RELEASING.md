# Releasing Smart Disk

## Share a community ZIP

On macOS with Xcode 26+ and Rust installed:

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
cargo test --workspace --locked
swift test --package-path macos
scripts/check-secrets.sh
scripts/package-release.sh --universal
```

Share `dist/SmartDisk-0.3.0-macOS-universal.zip` and its `.sha256` file through
your chosen download host. The archive contains `SmartDisk.app`, an MIT license
and `READ ME FIRST.txt` with install and first-open instructions. It requires
macOS 26+ and supports Apple silicon and Intel. Recipients need no build tools.
The version comes from the workspace's Cargo.toml, so future versions use the
same command with a new versioned filename.

Before publication, extract the actual ZIP, run `scripts/verify-app.sh` against
the extracted app and try the download on a separate Mac. Verify folder access,
first launch, smart folders, app restart and Quit. Intel cross-compilation is
not a substitute for an Intel hardware smoke test.

The local ZIP is **not notarized**. Do not describe it as Apple-approved or
promise a warning-free installation. Follow Apple's [opening guidance](https://support.apple.com/en-us/102445).

## GitHub artifacts and releases

The checks workflow uploads a universal ZIP artifact. The manual release
workflow builds and validates the same package, then creates a **draft** release.
It does not need private signing credentials. Add a GitHub remote and push the
repository before running it under Actions. Review the draft and publish it
when ready; use that release's asset URL for a website download button.

No public host or remote URL is assumed by the local packaging commands.

## Optional signing and notarization

For installation under normal Gatekeeper policy, enroll in the Apple Developer
Program and install a **Developer ID Application** certificate and its private
key in Keychain. An Apple Development certificate does not replace it.

Use `xcrun notarytool store-credentials` interactively to store a Keychain
profile. Do not paste an app-specific password into a tracked file or command
history. Then set the identity and the profile's name in your shell:

```sh
export SMARTDISK_SIGNING_IDENTITY='Developer ID Application: YOUR NAME (TEAM ID)'
export SMARTDISK_NOTARY_PROFILE='smartdisk-notary'
scripts/package-release.sh --universal --notarize
```

The script enables hardened runtime and secure timestamps, signs from the
inside out, submits the app to Apple, staples and validates the ticket and
checks Gatekeeper acceptance. It packages the stapled app only after those
steps succeed and includes the notarized quick-start instructions.

Apple documents the requirements in [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
