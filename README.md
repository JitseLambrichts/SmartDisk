# Smart Disk

**Folders that fill themselves. `mkdir` is a search query.**

Smart Disk is a virtual drive for macOS that organises your files by what is *in* them — without moving or copying a single file. Invoices, contracts, ID documents and screenshots each get a folder that fills itself, and any folder you create becomes a saved search:

```bash
mkdir ~/Slim/"invoices 2026 over 100 euro"
ls    ~/Slim/"invoices 2026 over 100 euro"
```

Three promises:

1. **Your files are never moved.** The drive only shows views. Deleting on the drive removes a label or a search, never an original.
2. **Everything stays on your Mac.** Text recognition, embeddings and folder-name parsing run on device. No telemetry, no network.
3. **No account.**

## What works today (v0.1–v0.3)

| On the drive | What really happens |
| --- | --- |
| Open or copy a file | Reads the original directly |
| Create a folder | The name becomes a saved query; the folder fills itself |
| Rename a folder | The query changes; contents are recomputed |
| Remove a folder | Only the query disappears |
| Remove a file from a folder | "Doesn't belong here" — the original stays |
| Drop a known file into a folder (mirror) | "Belongs here" |
| Save a new file onto the drive (mirror) | Moved to `~/Documents/Slim Inbox` and indexed |

Built-in categories: **Invoices, Contracts, ID Documents** (hidden until you enable sensitive categories), **Screenshots, Photos, Housing**. A file can live in several folders at once — a rent invoice shows up in both Invoices and Housing.

Folder names are understood in Dutch and English, for example `facturen 2026 boven 100 euro`, `contracten met opzegtermijn`, `alles over mijn kot`, `screenshots met een code erin`, `pdf van school deze maand`.

## Architecture

```
 Finder · open/save panels · terminal · AI agents
                     │
     ┌───────────────┼────────────────┐
  mirror folder   FUSE drive      FSKit (planned)     ← crates/fs
     └───────────────┼────────────────┘
              VirtualVolume trait                     ← crates/core/src/volume.rs
                     │
   Rust core: index · facts · categories · queries    ← crates/core
                     │
   slim-helper (Swift): PDFKit · Vision OCR · Foundation Models   ← macos/Sources/SlimHelper
```

| Path | Role |
| --- | --- |
| `crates/core` | SQLite index, text extraction, facts (dates, amounts, VAT, IBAN by rules — never by a model), embeddings, categories, folder-name parser, smart-folder evaluation, `why` explanations |
| `crates/fs` | Backends: `mirror` (a folder of symbolic links, no install needed) and `fuse` (real drive via macFUSE / FUSE-T, behind the `fuse` feature) |
| `crates/cli` | The `slim` command and `slim daemon` (file watcher, low-priority indexing, keeps the drive in sync) |
| `macos/Sources/SlimHelper` | `slim-helper`: PDF text, on-device OCR (Dutch, English, French, German), Apple Intelligence for folder names |
| `macos/Sources/SmartDisk` | The SwiftUI app: main window, menu bar status, settings |

**Rules first, model second.** The keyword parser owns every number. Apple Intelligence (when available) may only map an unknown word to a non-sensitive category. When in doubt, a file stays out — a missing file hurts less than a wrong one.

**Embeddings.** The default embedder hashes words, stems and trigrams (`hash-512-v1`): no download, works offline, but it captures spelling rather than meaning. A small concept list (e.g. *kot* → rent, landlord, deposit) bridges the gap. Plugging in EmbeddingGemma via ONNX means implementing the `Embedder` trait in `crates/core/src/embed.rs`.

## Build and run

Requirements: macOS 26+, Rust, Xcode command-line tools.

```bash
scripts/build-app.sh
```

```bash
open dist/SmartDisk.app
```

The app starts `slim daemon --mirror`, which indexes `~/Downloads` and `~/Documents` (change this in Settings) and renders the drive at `~/Slim`. Drag `~/Slim` to Finder's sidebar to reach it from every open and save panel.

### A real drive with FUSE

Install [FUSE-T](https://github.com/macos-fuse-t/fuse-t) (no kernel extension) or [macFUSE](https://osxfuse.github.io), then:

```bash
scripts/build-app.sh --fuse
```

Choose *Virtual drive (FUSE)* under Settings → Drive. The drive mounts at `/Volumes/Slim`.

### Try it on fake documents first

```bash
swift scripts/make-fixtures.swift /tmp/slim-demo
```

```bash
export SLIM_HOME=/tmp/slim-demo/.index
```

Then point `slim folders add` at the generated folders and run `slim index`. `SLIM_HOME` keeps this test index apart from your real one.

## Command line

```bash
slim status                      # indexing state and folders
slim tree                        # folders on the drive with counts
slim ls Invoices                 # files in a folder
slim query "huurcontract"        # search without saving
slim mkdir "invoices 2026 over 100 euro"
slim why ~/Slim/Invoices/factuur-0423.pdf
slim label ~/Slim/Housing/factuur-0423.pdf --no
slim settings set sensitive true
```

Every command takes `--json`. The hidden `.slim` folder on the drive holds `status.json`, `log.txt` and `why.json` for scripts and agents.

## Privacy notes

- Only the folders you choose are read. iCloud files that are not downloaded are skipped, so indexing never triggers a download.
- The index lives in `~/Library/Application Support/SmartDisk` with owner-only permissions. It contains document text; turn off *Keep document text* to store only vectors and facts.
- ID documents stay hidden until you enable sensitive categories.
- Give AI agents access to specific smart folders, not the whole drive: documents can contain hidden instructions.

## FAQ

**Does it move my files?** No. Never.
**What happens when I delete something on the drive?** A folder deletion removes the search; a file deletion removes it from that folder only.
**Which macOS version?** The app targets macOS 26+. The Rust core and CLI also build on older versions and on Linux.

## License

MIT
