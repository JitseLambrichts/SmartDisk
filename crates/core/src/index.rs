//! Indexing: notice files, get their text and facts, embed and categorise.

use crate::categories::{classify, Doc};
use crate::config::Config;
use crate::db::{now, Db};
use crate::embed::{to_blob, Embedder};
use crate::extract::{chunk, extract, kind_of};
use crate::facts;
use crate::helper::Helper;
use anyhow::Result;
use chrono::{DateTime, Local, NaiveDate};
use rusqlite::params;
use rusqlite::OptionalExtension;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs::{self, Metadata};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::SystemTime;
use walkdir::WalkDir;

/// Files larger than this are ignored entirely.
const MAX_FILE_BYTES: u64 = 200 * 1024 * 1024;
/// macOS `st_flags` bit for iCloud files whose data is not downloaded.
const SF_DATALESS: u32 = 0x4000_0000;

const SKIP_DIRS: &[&str] = &["node_modules", ".git", "Library", ".Trash", "target", ".build", "venv", ".venv", "__pycache__", "DerivedData"];
const PACKAGE_EXT: &[&str] = &["app", "photoslibrary", "musiclibrary", "bundle", "framework", "xcodeproj", "xcworkspace", "lproj", "fcpbundle", "tvlibrary", "pages", "numbers", "key", "rtfd"];

#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    Indexed,
    Unchanged,
    Skipped(String),
}

pub struct Indexer<'a> {
    pub db: &'a mut Db,
    pub config: &'a Config,
    pub embedder: &'a dyn Embedder,
    pub helper: Option<Helper>,
}

/// True for iCloud placeholders: reading them would trigger a download.
pub fn is_dataless(meta: &Metadata) -> bool {
    #[cfg(target_os = "macos")]
    {
        use std::os::macos::fs::MetadataExt;
        meta.st_flags() & SF_DATALESS != 0
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = meta;
        false
    }
}

fn mtime_of(meta: &Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// When the file arrived: creation time when known, else modification time.
fn file_date(meta: &Metadata) -> NaiveDate {
    let t = meta.created().or_else(|_| meta.modified()).unwrap_or(SystemTime::UNIX_EPOCH);
    DateTime::<Local>::from(t).date_naive()
}

/// Cheap content hash: size plus the first megabyte.
fn content_hash(path: &Path, size: u64) -> Result<String> {
    let mut file = fs::File::open(path)?;
    let mut buf = vec![0u8; 1024 * 1024];
    let mut n = 0;
    while n < buf.len() {
        let read = file.read(&mut buf[n..])?;
        if read == 0 {
            break;
        }
        n += read;
    }
    let mut h = Sha256::new();
    h.update(size.to_le_bytes());
    h.update(&buf[..n]);
    Ok(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

fn is_hidden(name: &str) -> bool {
    name.starts_with('.')
}

/// Every indexable file under the watched folders, most recent first.
pub fn candidates(config: &Config) -> Vec<(PathBuf, u64, i64)> {
    let mut roots = config.folders.clone();
    if !config.is_watched(&config.inbox_path) && config.inbox_path.is_dir() {
        roots.push(config.inbox_path.clone());
    }
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for root in roots {
        let walker = WalkDir::new(&root).follow_links(false).into_iter().filter_entry(|e| {
            let name = e.file_name().to_string_lossy();
            if e.depth() == 0 {
                return true;
            }
            if is_hidden(&name) {
                return false;
            }
            if e.file_type().is_dir() {
                let ext = Path::new(&*name).extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
                return !SKIP_DIRS.contains(&name.as_ref()) && !PACKAGE_EXT.contains(&ext.as_str());
            }
            true
        });
        for entry in walker.flatten() {
            if !entry.file_type().is_file() {
                continue;
            }
            let path = entry.path();
            if path.starts_with(&config.mirror_path) {
                continue;
            }
            let ext = path.extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
            if kind_of(&ext).is_none() || !seen.insert(path.to_path_buf()) {
                continue;
            }
            let Ok(meta) = entry.metadata() else { continue };
            out.push((path.to_path_buf(), meta.len(), mtime_of(&meta)));
        }
    }
    out.sort_by(|a, b| b.2.cmp(&a.2));
    out
}

impl<'a> Indexer<'a> {
    pub fn new(db: &'a mut Db, config: &'a Config, embedder: &'a dyn Embedder) -> Self {
        let helper = Helper::locate(config.helper_path.as_deref());
        Indexer { db, config, embedder, helper }
    }

    /// Indexes one file if it is new or changed.
    pub fn index_path(&mut self, path: &Path) -> Result<Outcome> {
        // Reject queued work from revoked sources before reading document data.
        // The transaction check below also covers revocation during extraction.
        if let Some(raw) = self.db.get_state("source_folders")? {
            let folders: Vec<PathBuf> = serde_json::from_str(&raw)?;
            if !folders.iter().any(|root| path.starts_with(root)) && !path.starts_with(&self.config.inbox_path) {
                return Ok(Outcome::Skipped("source folder was removed".into()));
            }
        }
        // Never index the drive itself, and never follow links into it.
        if path.starts_with(&self.config.mirror_path) || path.starts_with(&self.config.fuse_mount_point) {
            return Ok(Outcome::Skipped("on the Smart Disk itself".into()));
        }
        if fs::symlink_metadata(path).map(|m| m.file_type().is_symlink()).unwrap_or(false) {
            return Ok(Outcome::Skipped("symbolic link".into()));
        }
        let meta = match fs::metadata(path) {
            Ok(m) => m,
            Err(_) => {
                self.forget(path)?;
                return Ok(Outcome::Skipped("file no longer exists".into()));
            }
        };
        if !meta.is_file() {
            return Ok(Outcome::Skipped("not a regular file".into()));
        }
        let ext = path.extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
        let Some(kind) = kind_of(&ext) else { return Ok(Outcome::Skipped("unsupported type".into())) };
        if is_dataless(&meta) {
            return Ok(Outcome::Skipped("in iCloud, not downloaded".into()));
        }
        if meta.len() > MAX_FILE_BYTES {
            return Ok(Outcome::Skipped("larger than 200 MB".into()));
        }
        let size = meta.len();
        let mtime = mtime_of(&meta);
        if let Some(existing) = self.db.file_by_path(path)? {
            if existing.size == size && existing.mtime == mtime {
                return Ok(Outcome::Unchanged);
            }
        }

        let hash = content_hash(path, size)?;
        let ex = extract(path, kind, size, self.helper.as_ref());
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let today = Local::now().date_naive();
        let facts = facts::extract(&ex.text, today);
        let doc_text = format!("{} {}", crate::text::file_name_words(&name), ex.text);
        let doc_embedding = self.embedder.embed(&doc_text.chars().take(6000).collect::<String>());
        let chunks: Vec<String> = {
            let mut c = chunk(&ex.text, 800, 120);
            if c.is_empty() {
                c.push(crate::text::file_name_words(&name));
            }
            c
        };
        let classes = classify(
            &Doc { file_name: &name, extension: &ext, kind, text: &ex.text, facts: &facts, embedding: &doc_embedding },
            self.embedder,
        );
        let root = self.config.root_of(path).cloned().unwrap_or_else(|| path.parent().unwrap_or(path).to_path_buf());
        let main = facts.main_amount().cloned();

        let tx = self.db.conn.transaction()?;
        let source_folders: Option<String> = tx.query_row("SELECT value FROM state WHERE key='source_folders'", [], |r| r.get(0)).optional()?;
        if let Some(raw) = source_folders {
            let folders: Vec<PathBuf> = serde_json::from_str(&raw)?;
            if !folders.iter().any(|root| path.starts_with(root)) && !path.starts_with(&self.config.inbox_path) {
                return Ok(Outcome::Skipped("source folder was removed".into()));
            }
        }
        // The database flag is read under the same write lock as the insert, so
        // an in-flight scan cannot restore text after the privacy switch returns.
        let text_allowed: bool = tx.query_row("SELECT COALESCE((SELECT value FROM state WHERE key='full_text_enabled'),'1') != '0'", [], |r| r.get(0))?;
        tx.execute(
            "INSERT INTO files(path, root, size, mtime, hash, kind, method, status, error, file_date, doc_date, amount, currency, facts, text_len, embedding, indexed_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'ok', ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
             ON CONFLICT(path) DO UPDATE SET root=excluded.root, size=excluded.size, mtime=excluded.mtime, hash=excluded.hash,
               kind=excluded.kind, method=excluded.method, status='ok', error=excluded.error, file_date=excluded.file_date,
               doc_date=excluded.doc_date, amount=excluded.amount, currency=excluded.currency, facts=excluded.facts,
               text_len=excluded.text_len, embedding=excluded.embedding, indexed_at=excluded.indexed_at",
            params![
                path.to_string_lossy(),
                root.to_string_lossy(),
                size as i64,
                mtime,
                hash,
                kind,
                ex.method,
                ex.note,
                file_date(&meta).to_string(),
                facts.doc_date.map(|d| d.to_string()),
                main.as_ref().map(|a| a.value),
                main.as_ref().map(|a| a.currency.clone()),
                serde_json::to_string(&facts)?,
                ex.text.chars().count() as i64,
                to_blob(&doc_embedding),
                now(),
            ],
        )?;
        let file_id: i64 = tx.query_row("SELECT id FROM files WHERE path = ?1", [path.to_string_lossy()], |r| r.get(0))?;
        tx.execute("DELETE FROM chunks WHERE file_id = ?1", [file_id])?;
        {
            let mut st = tx.prepare("INSERT INTO chunks(file_id, ord, text, embedding) VALUES (?1, ?2, ?3, ?4)")?;
            for (i, c) in chunks.iter().enumerate() {
                let text = (self.config.store_full_text && text_allowed).then_some(c.as_str());
                st.execute(params![file_id, i as i64, text, to_blob(&self.embedder.embed(c))])?;
            }
        }
        tx.execute("DELETE FROM labels WHERE file_id = ?1 AND source = 'auto'", [file_id])?;
        {
            let mut st = tx.prepare(
                "INSERT INTO labels(file_id, category, source, confidence, included, reasons) VALUES (?1, ?2, 'auto', ?3, ?4, ?5)",
            )?;
            for c in &classes {
                st.execute(params![file_id, c.category, c.score as f64, c.included as i64, serde_json::to_string(&c.reasons)?])?;
            }
        }
        tx.commit()?;
        Ok(Outcome::Indexed)
    }

    /// Drops a file from the index (the original is untouched, it is just gone).
    pub fn forget(&mut self, path: &Path) -> Result<bool> {
        if let Some(f) = self.db.file_by_path(path)? {
            self.db.delete_file(f.id)?;
            return Ok(true);
        }
        Ok(false)
    }

    /// Removes index entries for files that disappeared or left the watched folders.
    pub fn prune(&mut self) -> Result<usize> {
        let mut removed = 0;
        for (id, path, _, _) in self.db.file_stamps()? {
            let watched = self.config.is_watched(&path) || path.starts_with(&self.config.inbox_path);
            if !watched || !path.exists() {
                self.db.delete_file(id)?;
                removed += 1;
            }
        }
        Ok(removed)
    }

    /// Full pass over the watched folders. `progress(done, total, current)`.
    /// `should_stop` is polled between files so the daemon can pause.
    pub fn scan(&mut self, mut progress: impl FnMut(usize, usize, &Path), should_stop: impl Fn() -> bool) -> Result<ScanReport> {
        let mut report = ScanReport { removed: self.prune()?, ..Default::default() };
        let files = candidates(self.config);
        let total = files.len();
        for (i, (path, _, _)) in files.iter().enumerate() {
            if should_stop() {
                report.interrupted = true;
                break;
            }
            progress(i, total, path);
            match self.index_path(path) {
                Ok(Outcome::Indexed) => report.indexed += 1,
                Ok(Outcome::Unchanged) => report.unchanged += 1,
                Ok(Outcome::Skipped(_)) => report.skipped += 1,
                Err(e) => {
                    report.failed += 1;
                    let _ = self.db.log("warn", &format!("could not index {}: {e}", path.display()));
                }
            }
        }
        report.total = total;
        Ok(report)
    }
}

#[derive(Debug, Default, Clone, serde::Serialize)]
pub struct ScanReport {
    pub total: usize,
    pub indexed: usize,
    pub unchanged: usize,
    pub skipped: usize,
    pub failed: usize,
    pub removed: usize,
    pub interrupted: bool,
}

/// Runs the current thread at background priority so indexing stays out of the way.
pub fn lower_priority() {
    #[cfg(target_os = "macos")]
    unsafe {
        // PRIO_DARWIN_THREAD / PRIO_DARWIN_BG: low CPU and I/O priority.
        libc::setpriority(3, 0, 0x1000);
    }
}

/// True when the Mac is running on battery power.
pub fn on_battery() -> bool {
    std::process::Command::new("/usr/bin/pmset")
        .args(["-g", "batt"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("'Battery Power'"))
        .unwrap_or(false)
}
