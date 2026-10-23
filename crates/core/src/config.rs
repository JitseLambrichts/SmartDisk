//! User configuration, stored as JSON next to the index.

use crate::categories::{self, Category};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// Where the index and configuration live. `SLIM_HOME` overrides it (tests, scripts).
pub fn data_dir() -> PathBuf {
    if let Some(home) = std::env::var_os("SLIM_HOME") {
        return PathBuf::from(home);
    }
    dirs::data_dir()
        .unwrap_or_else(|| home_dir().join("Library/Application Support"))
        .join("SmartDisk")
}

pub fn home_dir() -> PathBuf {
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("/"))
}

/// Creates the data directory with owner-only permissions: the index holds
/// text from every document, so nobody else on the Mac may read it.
pub fn ensure_data_dir() -> Result<PathBuf> {
    let dir = data_dir();
    fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir).with_context(|| format!("creating {}", dir.display()))?;
    anyhow::ensure!(!fs::symlink_metadata(&dir)?.file_type().is_symlink(), "the index directory must not be a symbolic link");
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    Ok(dir)
}

/// Replaces a file atomically without following an existing destination symlink.
pub fn write_private(path: &Path, bytes: &[u8]) -> Result<()> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let tmp = path.with_extension(format!("tmp-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
    let result = (|| -> Result<()> {
        let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&tmp, path)?;
        Ok(())
    })();
    if result.is_err() { let _ = fs::remove_file(&tmp); }
    result
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Folders the user chose to index. Nothing outside them is ever read.
    pub folders: Vec<PathBuf>,
    /// ID documents (and other sensitive categories) stay hidden until enabled.
    pub sensitive_enabled: bool,
    /// Built-in categories the user removed, by id. Files keep their labels,
    /// so bringing a category back is instant.
    pub hidden_categories: Vec<String>,
    /// When false, only vectors and extracted facts are kept, not document text.
    pub store_full_text: bool,
    /// Skip background indexing while the Mac runs on battery.
    pub pause_on_battery: bool,
    /// Manual pause from the menu bar.
    pub paused: bool,
    /// Use Apple Intelligence (via the helper) to read folder names.
    pub use_apple_intelligence: bool,
    /// Mount point for the FUSE backend.
    pub fuse_mount_point: PathBuf,
    /// Folder used by the mirror backend (works without any FUSE install).
    pub mirror_path: PathBuf,
    /// Real folder where files saved onto the drive end up.
    pub inbox_path: PathBuf,
    /// Explicit path to `slim-helper`; discovered automatically when empty.
    pub helper_path: Option<PathBuf>,
}

impl Default for Config {
    fn default() -> Self {
        let home = home_dir();
        Config {
            folders: Vec::new(),
            sensitive_enabled: false,
            hidden_categories: Vec::new(),
            store_full_text: true,
            pause_on_battery: true,
            paused: false,
            use_apple_intelligence: true,
            fuse_mount_point: PathBuf::from("/Volumes/Slim"),
            mirror_path: home.join("Slim"),
            inbox_path: home.join("Documents/Slim Inbox"),
            helper_path: None,
        }
    }
}

impl Config {
    pub fn path() -> PathBuf {
        data_dir().join("config.json")
    }

    pub fn load() -> Result<Config> {
        let path = Self::path();
        match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes).with_context(|| format!("parsing {}", path.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Config::default()),
            Err(e) => Err(e).with_context(|| format!("reading {}", path.display())),
        }
    }

    pub fn save(&self) -> Result<()> {
        ensure_data_dir()?;
        write_private(&Self::path(), &serde_json::to_vec_pretty(self)?)
    }

    /// Whether a category shows up as a folder: not removed by the user, and
    /// not a sensitive one while those are switched off.
    pub fn shows_category(&self, c: &Category) -> bool {
        (self.sensitive_enabled || !c.sensitive) && !self.hidden_categories.iter().any(|h| h == c.id)
    }

    /// Categories that appear as folders on the drive and in the app.
    pub fn visible_categories(&self) -> impl Iterator<Item = &'static Category> + '_ {
        categories::ALL.iter().filter(|c| self.shows_category(c))
    }

    /// True if `path` lies inside one of the watched folders.
    pub fn is_watched(&self, path: &Path) -> bool {
        self.folders.iter().any(|f| path.starts_with(f))
    }

    /// The watched folder that contains `path`, if any.
    pub fn root_of(&self, path: &Path) -> Option<&PathBuf> {
        self.folders.iter().filter(|f| path.starts_with(f)).max_by_key(|f| f.as_os_str().len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_launch_does_not_choose_source_folders() {
        assert!(Config::default().folders.is_empty());
    }

    #[test]
    fn removed_and_sensitive_categories_are_not_shown() {
        let mut c = Config { hidden_categories: vec!["invoices".into()], ..Config::default() };
        let names: Vec<_> = c.visible_categories().map(|c| c.id).collect();
        assert!(!names.contains(&"invoices"));
        assert!(!names.contains(&"id_documents"));
        assert!(names.contains(&"contracts"));
        c.sensitive_enabled = true;
        c.hidden_categories.clear();
        assert_eq!(c.visible_categories().count(), categories::ALL.len());
    }
}
