//! What the drive looks like, independent of how it is mounted.
//!
//! Golden rule: nothing done on the drive can damage or delete an original.
//! The drive only shows views; actions change labels and queries, never files.
//!
//! ```text
//! /Invoices/…           built-in categories
//! /facturen 2026 …/     smart folders (the folder name is the query)
//! /.slim/status.json    status, log and explanations for scripts
//! ```

use crate::categories;
use crate::config::Config;
use crate::db::Db;
use crate::embed::Embedder;
use crate::helper::Helper;
use crate::query::{self, FileFilter, ViewQuery};
use crate::views;
use anyhow::{anyhow, Result};
use chrono::Local;
use serde::Serialize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const META_DIR: &str = ".slim";

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", content = "id", rename_all = "snake_case")]
pub enum DirKind {
    Category(String),
    View(i64),
}

impl DirKind {
    /// Key used in the labels table.
    pub fn label_key(&self) -> String {
        match self {
            DirKind::Category(c) => c.clone(),
            DirKind::View(id) => format!("view:{id}"),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct VFile {
    /// Display name, unique inside its folder.
    pub name: String,
    pub file_id: i64,
    pub path: PathBuf,
    pub size: u64,
    pub mtime: i64,
    pub score: f32,
    pub reasons: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct VDir {
    pub name: String,
    pub kind: DirKind,
    pub entries: Vec<VFile>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Tree {
    pub generation: i64,
    pub dirs: Vec<VDir>,
    /// Generated files inside `.slim`.
    pub meta: Vec<(String, Vec<u8>)>,
}

/// Gives every file a unique name in its folder:
/// two "factuur.pdf" become "factuur (Downloads).pdf" and "factuur (Mail).pdf".
fn unique_names(files: &mut [VFile], origins: &[String]) {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for f in files.iter() {
        *counts.entry(f.name.to_lowercase()).or_default() += 1;
    }
    let mut used: HashMap<String, usize> = HashMap::new();
    for (f, origin) in files.iter_mut().zip(origins) {
        if counts[&f.name.to_lowercase()] > 1 {
            let (stem, ext) = match f.name.rsplit_once('.') {
                Some((s, e)) if !s.is_empty() => (s.to_owned(), format!(".{e}")),
                _ => (f.name.clone(), String::new()),
            };
            f.name = format!("{stem} ({origin}){ext}");
            let n = used.entry(f.name.to_lowercase()).or_default();
            *n += 1;
            if *n > 1 {
                f.name = format!("{stem} ({origin} {n}){ext}");
            }
        }
    }
}

impl Tree {
    pub fn build(db: &Db, config: &Config) -> Result<Tree> {
        let generation = db.generation()?;
        let files: HashMap<i64, _> = db.files()?.into_iter().map(|f| (f.id, f)).collect();
        let mut dirs = Vec::new();

        let mut make_dir = |name: String, kind: DirKind, items: Vec<(i64, f32, Vec<String>)>| {
            let mut entries = Vec::new();
            let mut origins = Vec::new();
            for (id, score, reasons) in items {
                if let Some(f) = files.get(&id) {
                    entries.push(VFile {
                        name: f.file_name(),
                        file_id: id,
                        path: f.path.clone(),
                        size: f.size,
                        mtime: f.mtime,
                        score: score.min(1.0),
                        reasons,
                    });
                    origins.push(f.origin());
                }
            }
            unique_names(&mut entries, &origins);
            entries.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
            dirs.push(VDir { name, kind, entries });
        };

        for cat in config.visible_categories() {
            let members = db.members(cat.id)?;
            let mut items = Vec::new();
            for (id, conf) in members {
                let reasons = db
                    .labels_for(id)?
                    .into_iter()
                    .find(|(c, src, _, _, _)| c == cat.id && src != "user_no")
                    .map(|(_, _, _, _, r)| r)
                    .unwrap_or_default();
                items.push((id, conf, reasons));
            }
            make_dir(cat.name.to_owned(), DirKind::Category(cat.id.to_owned()), items);
        }
        let hidden: Vec<&str> = categories::ALL.iter().filter(|c| c.sensitive && !config.sensitive_enabled).map(|c| c.id).collect();
        for v in db.views()? {
            let q: ViewQuery = serde_json::from_value(v.query.clone()).unwrap_or_default();
            // A smart folder over a hidden category stays empty too.
            let items = if q.category.as_deref().is_some_and(|c| hidden.contains(&c)) { Vec::new() } else { db.view_items(v.id)? };
            make_dir(v.name.clone(), DirKind::View(v.id), items);
        }

        let mut tree = Tree { generation, dirs, meta: Vec::new() };
        tree.meta = tree.meta_files(db)?;
        Ok(tree)
    }

    fn meta_files(&self, db: &Db) -> Result<Vec<(String, Vec<u8>)>> {
        let (total, ok) = db.count_files()?;
        let status = serde_json::json!({
            "generation": self.generation,
            "files_total": total,
            "files_indexed": ok,
            "state": db.get_state("state")?.unwrap_or_else(|| "idle".into()),
            "folders": self.dirs.iter().map(|d| serde_json::json!({"name": d.name, "count": d.entries.len()})).collect::<Vec<_>>(),
        });
        let log: String = db
            .recent_log(200)?
            .into_iter()
            .rev()
            .map(|l| format!("{} [{}] {}\n", chrono::DateTime::from_timestamp(l.ts, 0).map(|d| d.to_rfc3339()).unwrap_or_default(), l.level, l.message))
            .collect();
        let why: Vec<_> = self
            .dirs
            .iter()
            .map(|d| {
                serde_json::json!({
                    "folder": d.name,
                    "files": d.entries.iter().map(|e| serde_json::json!({
                        "name": e.name, "original": e.path, "score": e.score, "reasons": e.reasons
                    })).collect::<Vec<_>>()
                })
            })
            .collect();
        Ok(vec![
            ("status.json".into(), serde_json::to_vec_pretty(&status)?),
            ("log.txt".into(), log.into_bytes()),
            ("why.json".into(), serde_json::to_vec_pretty(&why)?),
            (
                "README.txt".into(),
                b"Smart Disk metadata. Read-only views of your files: nothing here is a copy,\nand nothing you do on this drive deletes or moves an original.\n".to_vec(),
            ),
        ])
    }

    pub fn dir(&self, name: &str) -> Option<&VDir> {
        self.dirs.iter().find(|d| d.name == name)
    }

    pub fn file(&self, dir: &str, name: &str) -> Option<&VFile> {
        self.dir(dir)?.entries.iter().find(|f| f.name == name)
    }
}

/// A node addressed by a path on the drive, such as "/Invoices/factuur.pdf".
#[derive(Debug, Clone)]
pub enum Node {
    Root,
    Dir(VDir),
    File(VFile),
    MetaDir,
    MetaFile(String, Vec<u8>),
}

#[derive(Debug)]
pub enum VolumeError {
    NotFound,
    /// The operation would change an original, or makes no sense here.
    NotPermitted(String),
    Exists,
    Other(anyhow::Error),
}

impl std::fmt::Display for VolumeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            VolumeError::NotFound => write!(f, "not found"),
            VolumeError::NotPermitted(why) => write!(f, "not permitted: {why}"),
            VolumeError::Exists => write!(f, "already exists"),
            VolumeError::Other(e) => write!(f, "{e}"),
        }
    }
}

impl From<anyhow::Error> for VolumeError {
    fn from(e: anyhow::Error) -> Self {
        VolumeError::Other(e)
    }
}

pub type VResult<T> = std::result::Result<T, VolumeError>;

/// The operations every backend (FUSE, mirror folder, FSKit) translates.
pub trait VirtualVolume: Send + Sync {
    fn tree(&self) -> Arc<Tree>;
    fn lookup(&self, path: &str) -> VResult<Node>;
    fn readdir(&self, path: &str) -> VResult<Vec<Node>>;
    fn read(&self, path: &str, offset: u64, size: u32) -> VResult<Vec<u8>>;
    /// New folder: the name becomes a saved query.
    fn mkdir(&self, path: &str) -> VResult<()>;
    /// Remove folder: only the query disappears.
    fn rmdir(&self, path: &str) -> VResult<()>;
    /// Rename folder: the query changes and contents are recomputed.
    fn rename(&self, from: &str, to: &str) -> VResult<()>;
    /// Remove file from a folder: "does not belong here". The original stays.
    fn unlink(&self, path: &str) -> VResult<()>;
}

fn split(path: &str) -> Vec<&str> {
    path.split('/').filter(|p| !p.is_empty()).collect()
}

/// Opens a fresh read handle to the original file. Reads go straight to it.
pub fn read_original(path: &std::path::Path, offset: u64, size: u32) -> std::io::Result<Vec<u8>> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(path)?;
    f.seek(SeekFrom::Start(offset))?;
    let mut buf = Vec::with_capacity(size as usize);
    f.take(size as u64).read_to_end(&mut buf)?;
    Ok(buf)
}

pub struct SmartVolume {
    db: Mutex<Db>,
    config: Mutex<Config>,
    embedder: Box<dyn Embedder>,
    helper: Option<Helper>,
    cache: Mutex<(Arc<Tree>, Instant)>,
}

impl SmartVolume {
    pub fn new(db: Db, config: Config, embedder: Box<dyn Embedder>) -> Result<SmartVolume> {
        let helper = Helper::locate(config.helper_path.as_deref());
        let tree = Arc::new(Tree::build(&db, &config)?);
        Ok(SmartVolume { db: Mutex::new(db), config: Mutex::new(config), embedder, helper, cache: Mutex::new((tree, Instant::now())) })
    }

    pub fn reload_config(&self) {
        if let Ok(c) = Config::load() {
            *self.config.lock().unwrap() = c;
            self.invalidate();
        }
    }

    pub fn invalidate(&self) {
        self.cache.lock().unwrap().1 = Instant::now() - Duration::from_secs(60);
    }

    fn helper_for_queries(&self) -> Option<&Helper> {
        self.config.lock().unwrap().use_apple_intelligence.then_some(self.helper.as_ref()).flatten()
    }

    /// Creates a smart folder from its name. Shared by every backend and the CLI.
    pub fn create_view(&self, name: &str) -> VResult<i64> {
        create_view(&mut self.db.lock().unwrap(), self.embedder.as_ref(), self.helper_for_queries(), name, FileFilter::default())
            .inspect(|_| self.invalidate())
    }

    /// Removes a smart folder, or hides a built-in category.
    pub fn delete_view(&self, name: &str) -> VResult<()> {
        delete_view(&self.db.lock().unwrap(), name)?;
        self.reload_config(); // a hidden category lives in the config
        self.invalidate();
        Ok(())
    }

    /// A new folder: brings back a removed category of that name, or makes a smart folder.
    pub fn create_folder(&self, name: &str) -> VResult<()> {
        if restore_category(&self.db.lock().unwrap(), name)? {
            self.reload_config();
            self.invalidate();
            return Ok(());
        }
        self.create_view(name).map(|_| ())
    }

    pub fn rename_view(&self, from: &str, to: &str) -> VResult<()> {
        rename_view(&mut self.db.lock().unwrap(), self.embedder.as_ref(), self.helper_for_queries(), from, to).inspect(|_| self.invalidate())
    }

    /// Labels a file as (not) belonging to a folder.
    pub fn label(&self, dir: &str, file_id: i64, yes: bool) -> VResult<()> {
        let tree = self.tree();
        let d = tree.dir(dir).ok_or(VolumeError::NotFound)?;
        let mut db = self.db.lock().unwrap();
        db.set_user_label(file_id, &d.kind.label_key(), yes)?;
        // Smart folders built on a category follow the correction too.
        views::refresh_all(&mut db, self.embedder.as_ref())?;
        db.bump_generation()?;
        drop(db);
        self.invalidate();
        Ok(())
    }
}

/// Finder first creates "untitled folder" and lets you type the real name.
/// Such a folder stays empty until it is renamed.
pub fn is_placeholder(name: &str) -> bool {
    let n = name.to_lowercase();
    ["untitled folder", "naamloze map", "nieuwe map", "new folder"].iter().any(|p| n == *p || n.strip_prefix(p).is_some_and(|rest| rest.trim().parse::<u32>().is_ok()))
}

/// `filter` narrows the folder beyond what its name says; pass the default for none.
pub fn create_view(db: &mut Db, embedder: &dyn Embedder, helper: Option<&Helper>, name: &str, filter: FileFilter) -> VResult<i64> {
    let name = name.trim();
    if name.is_empty() || name.contains('/') {
        return Err(VolumeError::NotPermitted("invalid folder name".into()));
    }
    if categories::by_name(name).is_some() || db.view_by_name(name)?.is_some() {
        return Err(VolumeError::Exists);
    }
    if name.starts_with('.') {
        return Err(VolumeError::NotPermitted("hidden folders are not queries".into()));
    }
    let mut q = if is_placeholder(name) {
        ViewQuery { raw: name.to_owned(), parser: "placeholder".into(), ..Default::default() }
    } else {
        query::parse(name, Local::now().date_naive(), helper)
    };
    q.filter = filter;
    let id = db.insert_view(name, &serde_json::to_value(&q).map_err(anyhow::Error::from)?)?;
    views::refresh_all(db, embedder)?;
    db.bump_generation()?;
    db.log("info", &format!("smart folder created: \"{name}\" → {}", q.describe().join(", ")))?;
    Ok(id)
}

pub fn delete_view(db: &Db, name: &str) -> VResult<()> {
    if let Some(cat) = categories::by_name(name) {
        return hide_category(db, cat.id);
    }
    let v = db.view_by_name(name)?.ok_or(VolumeError::NotFound)?;
    db.delete_view(v.id)?;
    db.bump_generation()?;
    db.log("info", &format!("smart folder removed: \"{name}\" (no files were touched)"))?;
    Ok(())
}

/// Removes a built-in category folder. Files keep their labels and smart folders
/// built on the category keep working; only the folder disappears.
pub fn hide_category(db: &Db, id: &str) -> VResult<()> {
    let cat = categories::by_id(id).ok_or(VolumeError::NotFound)?;
    let mut config = Config::load()?;
    if !config.hidden_categories.iter().any(|h| h == cat.id) {
        config.hidden_categories.push(cat.id.to_owned());
        config.save()?;
    }
    db.bump_generation()?;
    db.log("info", &format!("category removed: \"{}\" (no files were touched)", cat.name))?;
    Ok(())
}

/// Brings back a removed category, matched by id or folder name.
/// Returns false when `name` is not a removed category.
pub fn restore_category(db: &Db, name: &str) -> VResult<bool> {
    let Some(cat) = categories::by_id(name).or_else(|| categories::by_name(name.trim())) else { return Ok(false) };
    let mut config = Config::load()?;
    let before = config.hidden_categories.len();
    config.hidden_categories.retain(|h| h != cat.id);
    if config.hidden_categories.len() == before {
        return Ok(false);
    }
    config.save()?;
    db.bump_generation()?;
    db.log("info", &format!("category restored: \"{}\"", cat.name))?;
    Ok(true)
}

pub fn rename_view(db: &mut Db, embedder: &dyn Embedder, helper: Option<&Helper>, from: &str, to: &str) -> VResult<()> {
    let v = db.view_by_name(from)?.ok_or(VolumeError::NotFound)?;
    let to = to.trim();
    if to.is_empty() || to.contains('/') || to.starts_with('.') {
        return Err(VolumeError::NotPermitted("invalid folder name".into()));
    }
    if categories::by_name(to).is_some() || db.view_by_name(to)?.is_some_and(|o| o.id != v.id) {
        return Err(VolumeError::Exists);
    }
    let mut q = query::parse(to, Local::now().date_naive(), helper);
    q.filter = serde_json::from_value::<ViewQuery>(v.query.clone()).unwrap_or_default().filter;
    db.update_view(v.id, to, &serde_json::to_value(&q).map_err(anyhow::Error::from)?)?;
    views::refresh_all(db, embedder)?;
    db.bump_generation()?;
    db.log("info", &format!("smart folder renamed: \"{from}\" → \"{to}\""))?;
    Ok(())
}

impl VirtualVolume for SmartVolume {
    fn tree(&self) -> Arc<Tree> {
        let mut cache = self.cache.lock().unwrap();
        if cache.1.elapsed() > Duration::from_millis(700) {
            let db = self.db.lock().unwrap();
            let current = db.generation().unwrap_or(-1);
            let stale_meta = cache.1.elapsed() > Duration::from_secs(5);
            if current != cache.0.generation || stale_meta || cache.1.elapsed() > Duration::from_secs(30) {
                let config = self.config.lock().unwrap().clone();
                if let Ok(t) = Tree::build(&db, &config) {
                    cache.0 = Arc::new(t);
                }
            }
            cache.1 = Instant::now();
        }
        cache.0.clone()
    }

    fn lookup(&self, path: &str) -> VResult<Node> {
        let tree = self.tree();
        match split(path).as_slice() {
            [] => Ok(Node::Root),
            [META_DIR] => Ok(Node::MetaDir),
            [META_DIR, file] => tree
                .meta
                .iter()
                .find(|(n, _)| n == file)
                .map(|(n, b)| Node::MetaFile(n.clone(), b.clone()))
                .ok_or(VolumeError::NotFound),
            [dir] => tree.dir(dir).cloned().map(Node::Dir).ok_or(VolumeError::NotFound),
            [dir, file] => tree.file(dir, file).cloned().map(Node::File).ok_or(VolumeError::NotFound),
            _ => Err(VolumeError::NotFound),
        }
    }

    fn readdir(&self, path: &str) -> VResult<Vec<Node>> {
        let tree = self.tree();
        match self.lookup(path)? {
            Node::Root => {
                let mut out: Vec<Node> = tree.dirs.iter().cloned().map(Node::Dir).collect();
                out.push(Node::MetaDir);
                Ok(out)
            }
            Node::MetaDir => Ok(tree.meta.iter().map(|(n, b)| Node::MetaFile(n.clone(), b.clone())).collect()),
            Node::Dir(d) => Ok(d.entries.into_iter().map(Node::File).collect()),
            _ => Err(VolumeError::NotPermitted("not a folder".into())),
        }
    }

    fn read(&self, path: &str, offset: u64, size: u32) -> VResult<Vec<u8>> {
        match self.lookup(path)? {
            Node::File(f) => read_original(&f.path, offset, size).map_err(|e| VolumeError::Other(e.into())),
            Node::MetaFile(_, bytes) => {
                let start = (offset as usize).min(bytes.len());
                let end = (start + size as usize).min(bytes.len());
                Ok(bytes[start..end].to_vec())
            }
            _ => Err(VolumeError::NotPermitted("is a folder".into())),
        }
    }

    fn mkdir(&self, path: &str) -> VResult<()> {
        match split(path).as_slice() {
            [name] => self.create_folder(name),
            _ => Err(VolumeError::NotPermitted("smart folders live at the top level".into())),
        }
    }

    fn rmdir(&self, path: &str) -> VResult<()> {
        match split(path).as_slice() {
            [name] => self.delete_view(name),
            _ => Err(VolumeError::NotFound),
        }
    }

    fn rename(&self, from: &str, to: &str) -> VResult<()> {
        match (split(from).as_slice(), split(to).as_slice()) {
            ([a], [b]) => self.rename_view(a, b),
            _ => Err(VolumeError::NotPermitted("only smart folders can be renamed".into())),
        }
    }

    fn unlink(&self, path: &str) -> VResult<()> {
        match split(path).as_slice() {
            [dir, file] => {
                let tree = self.tree();
                let f = tree.file(dir, file).ok_or(VolumeError::NotFound)?;
                let id = f.file_id;
                self.label(dir, id, false)?;
                let db = self.db.lock().unwrap();
                db.log("info", &format!("\"{file}\" removed from \"{dir}\" (original kept)"))?;
                Ok(())
            }
            _ => Err(VolumeError::NotPermitted("only files inside folders can be removed".into())),
        }
    }
}

/// Resolves a path on the drive ("/Volumes/Slim/Invoices/x.pdf", "Invoices/x.pdf")
/// to the folder and file it shows.
pub fn resolve_drive_path(tree: &Tree, path: &str, mount_points: &[PathBuf]) -> Option<(VDir, VFile)> {
    let mut rel = path.to_owned();
    for mp in mount_points {
        if let Ok(r) = std::path::Path::new(path).strip_prefix(mp) {
            rel = r.to_string_lossy().into_owned();
            break;
        }
    }
    match split(&rel).as_slice() {
        [dir, file] => {
            let d = tree.dir(dir)?;
            let f = d.entries.iter().find(|f| f.name == *file)?;
            Some((d.clone(), f.clone()))
        }
        _ => None,
    }
}

pub fn not_found(what: &str) -> anyhow::Error {
    anyhow!("{what} not found")
}
