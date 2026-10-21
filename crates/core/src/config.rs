//! User configuration, stored as JSON next to the index.

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

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
    fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    Ok(dir)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    /// Folders the user chose to index. Nothing outside them is ever read.
    pub folders: Vec<PathBuf>,
    /// ID documents (and other sensitive categories) stay hidden until enabled.
    pub sensitive_enabled: bool,
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
            folders: vec![home.join("Downloads"), home.join("Documents")],
            sensitive_enabled: false,
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
        let path = Self::path();
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
        fs::rename(&tmp, &path)?;
        Ok(())
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
