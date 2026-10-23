//! Mirror backend: renders the drive as a real folder of symbolic links.
//!
//! It needs no FUSE install, so it is the default during development. It
//! shows up in Finder (drag it to the sidebar), open/save panels and the
//! terminal, and it speaks the same rules as the FUSE drive:
//!
//! - `mkdir` of a new folder → saved query, the folder fills itself
//! - deleting a smart folder → only the query disappears
//! - deleting a link → "does not belong here"
//! - a file copied in → "belongs here" if it is a known original,
//!   otherwise it is moved to the real Slim Inbox folder
//!
//! Safety: the mirror only ever removes symbolic links and folders it created
//! itself; it never follows a link when deleting.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use slim_core::db::Db;
use slim_core::index::Indexer;
use slim_core::volume::{DirKind, SmartVolume, Tree, VirtualVolume, META_DIR};
use slim_core::{categories, config::write_private, Config};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::os::unix::fs::symlink;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};

const MANIFEST: &str = "manifest.json";

#[derive(Debug, Default, Serialize, Deserialize)]
struct Manifest {
    /// Folder name → links we created inside it (link name → target).
    dirs: BTreeMap<String, BTreeMap<String, PathBuf>>,
}

pub struct Mirror<'a> {
    pub root: PathBuf,
    pub volume: &'a SmartVolume,
}

#[derive(Debug, Default, Serialize)]
pub struct SyncReport {
    pub created_views: Vec<String>,
    pub removed_views: Vec<String>,
    pub unlabelled: Vec<String>,
    pub labelled: Vec<String>,
    pub inboxed: Vec<String>,
    pub links_added: usize,
    pub links_removed: usize,
}

impl SyncReport {
    pub fn user_changes(&self) -> bool {
        !(self.created_views.is_empty() && self.removed_views.is_empty() && self.unlabelled.is_empty() && self.labelled.is_empty() && self.inboxed.is_empty())
    }
}

fn is_symlink(p: &Path) -> bool {
    fs::symlink_metadata(p).map(|m| m.file_type().is_symlink()).unwrap_or(false)
}

fn real_directory(path: &Path) -> Result<()> {
    fs::DirBuilder::new().recursive(true).mode(0o700).create(path)?;
    anyhow::ensure!(fs::symlink_metadata(path)?.file_type().is_dir(), "{} must be a real directory, not a symbolic link", path.display());
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

fn safe_component(name: &str) -> bool {
    !name.is_empty() && !name.starts_with('.') && !name.contains('/') && !name.contains('\0')
}

impl<'a> Mirror<'a> {
    pub fn new(root: PathBuf, volume: &'a SmartVolume) -> Self {
        Mirror { root, volume }
    }

    fn manifest_path(&self) -> PathBuf {
        self.root.join(META_DIR).join(MANIFEST)
    }

    fn load_manifest(&self) -> Result<Manifest> {
        let bytes = match fs::read(self.manifest_path()) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Manifest::default()),
            Err(e) => return Err(e.into()),
        };
        let manifest: Manifest = serde_json::from_slice(&bytes).context("reading the drive manifest")?;
        anyhow::ensure!(manifest.dirs.iter().all(|(dir, links)| safe_component(dir) && links.keys().all(|n| safe_component(n))), "invalid path in drive manifest");
        Ok(manifest)
    }

    fn save_manifest(&self, m: &Manifest) -> Result<()> {
        write_private(&self.manifest_path(), &serde_json::to_vec_pretty(m)?)
    }

    /// One reconciliation pass: first read what the user changed, then render.
    pub fn sync(&self, config: &Config) -> Result<SyncReport> {
        if let Ok(meta) = fs::symlink_metadata(&self.root) {
            anyhow::ensure!(meta.is_dir() && !meta.file_type().is_symlink(), "the drive root must be a real directory");
            let owned = fs::symlink_metadata(self.manifest_path()).map(|m| m.is_file() && !m.file_type().is_symlink()).unwrap_or(false);
            if !owned {
                let nonempty = fs::read_dir(&self.root)?.any(|e| e.map(|e| e.file_name() != ".DS_Store").unwrap_or(true));
                anyhow::ensure!(!nonempty, "{} is not an empty Smart Disk folder. Rename the existing folder to preserve its files, then restart Smart Disk", self.root.display());
            }
        }
        real_directory(&self.root)?;
        real_directory(&self.root.join(META_DIR))?;
        let mut report = SyncReport::default();
        let mut manifest = self.load_manifest()?;
        let fresh_mirror = manifest.dirs.is_empty();
        let mut blocked = BTreeSet::new();
        // Unsafe paths are never followed, but must not prevent privacy cleanup
        // in the other directories that we can safely reconcile.
        for name in manifest.dirs.keys().chain(self.volume.tree().dirs.iter().map(|d| &d.name)) {
            anyhow::ensure!(safe_component(name), "invalid folder name in drive");
            let p = self.root.join(name);
            if let Ok(meta) = fs::symlink_metadata(&p) {
                if !meta.is_dir() || meta.file_type().is_symlink() { blocked.insert(name.clone()); }
            }
        }
        let mut blocked_owned = BTreeMap::new();
        manifest.dirs.retain(|name, links| {
            if blocked.contains(name) { blocked_owned.insert(name.clone(), links.clone()); false } else { true }
        });
        if !fresh_mirror {
            self.apply_user_changes(&manifest, config, &mut report)?;
        }
        self.volume.invalidate();
        let mut tree = (*self.volume.tree()).clone();
        tree.dirs.retain(|d| !blocked.contains(&d.name));
        let mut manifest = self.render(&tree, manifest, &mut report)?;
        manifest.dirs.extend(blocked_owned);
        self.save_manifest(&manifest)?;
        anyhow::ensure!(blocked.is_empty(), "these drive folders must be real directories: {}", blocked.into_iter().collect::<Vec<_>>().join(", "));
        Ok(report)
    }

    fn apply_user_changes(&self, manifest: &Manifest, config: &Config, report: &mut SyncReport) -> Result<()> {
        let tree = self.volume.tree();
        let on_disk: BTreeSet<String> = fs::read_dir(&self.root)?
            .flatten()
            .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| !n.starts_with('.'))
            .collect();

        // New folders the user made: a removed category comes back, any other name becomes a query.
        for name in on_disk.iter().filter(|n| !manifest.dirs.contains_key(*n) && tree.dir(n).is_none()) {
            match self.volume.create_folder(name) {
                Ok(_) => report.created_views.push(name.clone()),
                Err(e) => log::warn!("could not create smart folder {name}: {e}"),
            }
        }
        // Folders the user removed: drop the query, or hide the category. A mirror
        // with no folders left was wiped as a whole; categories then come back.
        for name in manifest.dirs.keys().filter(|n| !on_disk.contains(*n)) {
            if let Some(d) = tree.dir(name) {
                let removable = match d.kind {
                    DirKind::View(_) => true,
                    DirKind::Category(_) => !on_disk.is_empty(),
                };
                if removable && self.volume.delete_view(name).is_ok() {
                    report.removed_views.push(name.clone());
                }
            }
        }
        // Inside folders: removed links and newly added files.
        for (dir, links) in &manifest.dirs {
            let dir_path = self.root.join(dir);
            if !dir_path.is_dir() {
                continue;
            }
            let Some(vdir) = tree.dir(dir) else { continue };
            for name in links.keys() {
                if !is_symlink(&dir_path.join(name)) {
                    if let Some(f) = vdir.entries.iter().find(|f| &f.name == name) {
                        if self.volume.label(dir, f.file_id, false).is_ok() {
                            report.unlabelled.push(format!("{dir}/{name}"));
                        }
                    }
                }
            }
            for entry in fs::read_dir(&dir_path)?.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') || links.contains_key(&name) {
                    continue;
                }
                let p = entry.path();
                self.adopt(dir, &p, &name, config, report)?;
            }
        }
        Ok(())
    }

    /// Something new appeared inside a folder of the mirror.
    fn adopt(&self, dir: &str, p: &Path, name: &str, config: &Config, report: &mut SyncReport) -> Result<()> {
        let meta = fs::symlink_metadata(p)?;
        let target = if meta.file_type().is_symlink() {
            fs::read_link(p).ok().map(|t| if t.is_absolute() { t } else { p.parent().unwrap().join(t) })
        } else {
            None
        };
        let mut db = Db::open_default()?;
        // A link to an original we know, or a copy of one: "belongs here".
        let known = match &target {
            Some(t) => db.file_by_path(&t.canonicalize().unwrap_or(t.clone()))?,
            None if meta.is_file() => {
                let size = meta.len();
                db.files()?.into_iter().find(|f| f.size == size && f.file_name() == name && same_content(&f.path, p))
            }
            None => None,
        };
        if let Some(f) = known {
            self.volume.label(dir, f.id, true).ok();
            report.labelled.push(format!("{dir}/{name}"));
            // Remove what the user dropped in: a link, or an identical copy of the original.
            if meta.file_type().is_symlink() || same_content(&f.path, p) {
                fs::remove_file(p)?;
            }
            return Ok(());
        }
        if meta.is_file() {
            // A brand-new file saved onto the drive goes to the real inbox folder.
            fs::create_dir_all(&config.inbox_path)?;
            let mut dest = config.inbox_path.join(name);
            let mut n = 2;
            while dest.exists() {
                let stem = Path::new(name).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                let ext = Path::new(name).extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
                dest = config.inbox_path.join(format!("{stem} {n}{ext}"));
                n += 1;
            }
            fs::rename(p, &dest).or_else(|_| fs::copy(p, &dest).and_then(|_| fs::remove_file(p)))?;
            let embedder = slim_core::embed::default_embedder();
            let mut indexer = Indexer::new(&mut db, config, embedder.as_ref());
            indexer.index_path(&dest)?;
            if let Some(f) = db.file_by_path(&dest)? {
                self.volume.label(dir, f.id, true).ok();
            }
            report.inboxed.push(dest.display().to_string());
        }
        Ok(())
    }

    /// Makes the folder match the tree. Only touches links and folders it owns.
    fn render(&self, tree: &Tree, old: Manifest, report: &mut SyncReport) -> Result<Manifest> {
        let mut new = Manifest::default();
        for d in &tree.dirs {
            let dir_path = self.root.join(&d.name);
            real_directory(&dir_path)?;
            let previous = old.dirs.get(&d.name).cloned().unwrap_or_default();
            let mut links = BTreeMap::new();
            for f in &d.entries {
                let link = dir_path.join(&f.name);
                let ok = fs::read_link(&link).map(|t| t == f.path).unwrap_or(false);
                if !ok {
                    if is_symlink(&link) {
                        fs::remove_file(&link)?;
                    } else if link.exists() {
                        continue; // a real file of the user's; never overwrite it
                    }
                    symlink(&f.path, &link)?;
                    report.links_added += 1;
                }
                links.insert(f.name.clone(), f.path.clone());
            }
            for name in previous.keys().filter(|n| !links.contains_key(*n)) {
                let p = dir_path.join(name);
                if is_symlink(&p) {
                    fs::remove_file(&p)?;
                    report.links_removed += 1;
                }
            }
            new.dirs.insert(d.name.clone(), links);
        }
        // Folders from the old manifest that no longer exist in the tree.
        for (name, links) in &old.dirs {
            if new.dirs.contains_key(name) {
                continue;
            }
            let dir_path = self.root.join(name);
            for l in links.keys() {
                let p = dir_path.join(l);
                if is_symlink(&p) {
                    fs::remove_file(&p)?;
                }
            }
            let _ = fs::remove_file(dir_path.join(".DS_Store"));
            let _ = fs::remove_dir(&dir_path); // only succeeds when empty
        }
        // Hidden categories (removed, or sensitive ones switched off) must not linger.
        for cat in categories::ALL {
            if tree.dir(cat.name).is_none() && !new.dirs.contains_key(cat.name) {
                let _ = fs::remove_dir(self.root.join(cat.name));
            }
        }
        for (name, bytes) in &tree.meta {
            write_private(&self.root.join(META_DIR).join(name), bytes)?;
        }
        Ok(new)
    }
}

fn same_content(a: &Path, b: &Path) -> bool {
    match (fs::read(a), fs::read(b)) {
        (Ok(x), Ok(y)) => x == y,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use slim_core::embed::default_embedder;

    #[test]
    fn unsafe_category_does_not_block_sensitive_link_cleanup() {
        let base = std::env::temp_dir().join(format!("smartdisk-cleanup-{}", std::process::id()));
        let root = base.join("drive");
        let source = base.join("source");
        let outside = base.join("outside");
        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(&outside).unwrap();
        let original = source.join("passport.txt");
        fs::write(&original, "Passport. Nationality: Example. Date of birth: 01/01/2000.").unwrap();
        let mut config = Config { sensitive_enabled: true, folders: vec![source], mirror_path: root.clone(), ..Config::default() };
        let db_path = base.join("index.sqlite");
        let mut db = Db::open(&db_path).unwrap();
        let embedder = default_embedder();
        slim_core::index::Indexer::new(&mut db, &config, embedder.as_ref()).index_path(&original).unwrap();
        let volume = SmartVolume::new(db, config.clone(), default_embedder()).unwrap();
        Mirror::new(root.clone(), &volume).sync(&config).unwrap();
        let link = root.join("ID Documents/passport.txt");
        assert!(is_symlink(&link));
        fs::remove_dir(root.join("Photos")).unwrap();
        symlink(&outside, root.join("Photos")).unwrap();
        config.sensitive_enabled = false;
        let hidden_volume = SmartVolume::new(Db::open(&db_path).unwrap(), config.clone(), default_embedder()).unwrap();
        let _ = Mirror::new(root, &hidden_volume).sync(&config);
        let remains = is_symlink(&link);
        drop(hidden_volume); drop(volume);
        fs::remove_dir_all(base).unwrap();
        assert!(!remains, "an unrelated unsafe directory must not leave sensitive links exposed");
    }

    #[test]
    fn refuses_to_adopt_an_existing_folder_of_originals() {
        let root = std::env::temp_dir().join(format!("smartdisk-unowned-{}", std::process::id()));
        fs::create_dir_all(root.join("Invoices")).unwrap();
        fs::write(root.join("Invoices/original.txt"), "keep me here").unwrap();
        let config = Config { mirror_path: root.clone(), ..Config::default() };
        let volume = SmartVolume::new(Db::open_in_memory().unwrap(), config.clone(), default_embedder()).unwrap();
        let result = Mirror::new(root.clone(), &volume).sync(&config);
        assert_eq!(fs::read_to_string(root.join("Invoices/original.txt")).unwrap(), "keep me here");
        fs::remove_dir_all(root).unwrap();
        assert!(result.is_err());
    }

    fn rejects_linked_directory(name: &str) {
        let base = std::env::temp_dir().join(format!("smartdisk-mirror-{}-{name}", std::process::id()));
        let root = base.join("drive");
        let outside = base.join("originals");
        fs::create_dir_all(&outside).unwrap();
        fs::write(outside.join("keep.txt"), "original content").unwrap();
        if name == "root" {
            symlink(&outside, &root).unwrap();
        } else {
            fs::create_dir_all(&root).unwrap();
            symlink(&outside, root.join(name)).unwrap();
        }
        let config = Config { mirror_path: root.clone(), ..Config::default() };
        let volume = SmartVolume::new(Db::open_in_memory().unwrap(), config.clone(), default_embedder()).unwrap();
        let result = Mirror::new(root, &volume).sync(&config);
        let contents: Vec<_> = fs::read_dir(&outside).unwrap().map(|e| e.unwrap().file_name()).collect();
        fs::remove_dir_all(base).unwrap();
        assert!(result.is_err(), "must refuse a symlink in a managed directory");
        assert_eq!(contents.len(), 1, "must not write metadata into originals");
    }

    #[test]
    fn refuses_a_symlink_as_the_drive_root() { rejects_linked_directory("root"); }

    #[test]
    fn refuses_a_symlink_as_the_metadata_directory() { rejects_linked_directory(".slim"); }

    #[test]
    fn refuses_a_symlink_as_a_category_directory() { rejects_linked_directory("Invoices"); }
}
