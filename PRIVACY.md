# Privacy

Smart Disk indexes selected source folders and its Inbox locally. It does not
send documents to a server, collect telemetry or require an account. OCR uses
Apple Vision; PDF extraction uses PDFKit. Optional folder-name interpretation
uses Apple's on-device Foundation Models. Indexing skips iCloud placeholders.

The app starts with no selected sources. Removing a source removes its indexed
records, unless a file remains under another selected root or the Inbox.

The SQLite index and configuration live in
`~/Library/Application Support/SmartDisk`, restricted to the current user.
They include filenames, original paths, extracted dates/amounts and other
facts, labels, vectors, search names and activity logs. Document text is kept
by default. Turning that option off clears text from active chunk records and
prevents an in-flight scan restoring it. Facts, vectors and category evidence
remain. Filesystem snapshots, backups and SQLite free pages may retain old data.
The index is not separately encrypted; normal macOS disk protection applies.

Recognised identity documents are hidden from the drive, search and text search
until sensitive categories are enabled. Recognition is imperfect. This setting
is not a substitute for choosing appropriate source folders or controlling
other apps' access. Software running as your macOS user may be able to read
the private index and original files using the permissions already granted.

The mirror drive is made of links to originals. Editing through a link edits
the original. Removing a smart folder removes a query; excluding a file
removes its membership. New files saved onto the mirror are moved into
`~/Documents/Slim Inbox` and then indexed.

The website's interactive demo uses fictitious sample files. Websites and
downloads use normal network access; the installed app's indexing and search
do not use a remote service. The standard app does not auto-update.

To remove your index, quit the app and delete its Application Support folder.
Keep your original files and any files saved to Slim Inbox. Do not attach an
index, a configuration containing private paths, or personal documents to
public support requests.
