# Smart Disk — Product and technical brief

Smart Disk adds content-based folders to macOS without reorganising originals.
The app is an English-language menu bar utility and window for choosing sources,
creating saved searches and inspecting why files match.

## Current experience

People download a ZIP, move SmartDisk.app to Applications and choose source
folders. No developer tools or account are needed. The standard build exposes
`~/Slim`, a folder of symbolic links that can be added to Finder's sidebar and
used in Open and Save dialogs. New downloads do not select sources automatically.

A query such as `invoices 2026 over 100 euro` becomes a folder. Files may appear
in several folders. Removing a search or excluding a link does not delete an
original. Editing through a link edits its original. New files saved to the
mirror go to `~/Documents/Slim Inbox`.

## Implementation

The Rust core owns the SQLite index, facts, labels, keyword queries and
embeddings. The Swift helper uses PDFKit, Vision and optional Foundation Models.
The SwiftUI app communicates through the bundled CLI's JSON interface. A file
watcher and periodic scans keep the index current. One daemon may own an index.

The default mirror backend requires no extra software. FUSE is an experimental
developer option; FSKit remains planned. The current embedding model hashes
words and trigrams rather than using a downloaded neural model.

## Privacy boundaries

- Read selected sources and the explicit save Inbox; skip cloud placeholders.
- Keep the index private to the current macOS user.
- Hide recognised sensitive files from every drive/search route until enabled.
- Remove revoked source records and prevent in-flight scans restoring them.
- Turning off text storage clears existing active chunk text and blocks new text.
- Refuse unowned nonempty drive folders and symlinks as managed directories.
- Never include an index, credentials or local configuration in a release ZIP.

These controls do not make classification perfect or encrypt the index. Users
must choose appropriate sources before granting other software drive access.

## Distribution

The universal ZIP targets macOS 26+ on Intel and Apple silicon. It includes an
English installation guide and MIT license. The local community build is
ad-hoc signed and requires macOS's first-open approval. Developer ID signing
and notarization are supported when the maintainer has the required account.

See [README.md](README.md), [Privacy](PRIVACY.md), and
[Release instructions](docs/RELEASING.md) for the maintained operational details.

## Future work

Native FSKit integration, stronger semantic embeddings and automatic updates
are possible future improvements. They are not included in this release.
