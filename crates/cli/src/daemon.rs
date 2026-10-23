//! `slim daemon`: watches folders, indexes in the background at low priority,
//! and keeps the drive (mirror folder or FUSE mount) up to date.

use anyhow::Result;
use notify::{RecursiveMode, Watcher};
use slim_core::config::{data_dir, ensure_data_dir, Config};
use slim_core::db::Db;
use slim_core::embed::default_embedder;
use slim_core::index::{lower_priority, on_battery, Indexer, Outcome};
use slim_core::views;
use slim_core::volume::SmartVolume;
use std::collections::BTreeSet;
use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, RecvTimeoutError};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

pub enum Backend {
    None,
    Mirror(PathBuf),
    #[cfg_attr(not(feature = "fuse"), allow(dead_code))]
    Fuse(PathBuf),
}

static STOP: AtomicBool = AtomicBool::new(false);

extern "C" fn on_signal(_: libc::c_int) {
    STOP.store(true, Ordering::SeqCst);
}

fn stopping() -> bool {
    STOP.load(Ordering::SeqCst)
}

/// Full rescan interval, as a safety net next to FSEvents.
const RESCAN: Duration = Duration::from_secs(15 * 60);

/// Held for the entire daemon lifetime. The lock inode is never unlinked.
struct DaemonGuard(File);

impl DaemonGuard {
    fn acquire() -> Result<Self> {
        let file = OpenOptions::new().read(true).write(true).create(true).truncate(false)
            .mode(0o600).custom_flags(libc::O_NOFOLLOW).open(data_dir().join("daemon.lock"))?;
        anyhow::ensure!(unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0, "Smart Disk is already running for this index");
        slim_core::config::write_private(&data_dir().join("daemon.pid"), std::process::id().to_string().as_bytes())?;
        Ok(Self(file))
    }
}

impl Drop for DaemonGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(data_dir().join("daemon.pid"));
        unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN); }
    }
}

pub fn running_pid() -> Option<i32> {
    let file = OpenOptions::new().read(true).write(true).custom_flags(libc::O_NOFOLLOW).open(data_dir().join("daemon.lock")).ok()?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 { return None; }
    let pid: i32 = std::fs::read_to_string(data_dir().join("daemon.pid")).ok()?.trim().parse().ok()?;
    (pid > 1 && unsafe { libc::kill(pid, 0) } == 0).then_some(pid)
}

pub fn run(backend: Backend) -> Result<()> {
    ensure_data_dir()?;
    let _guard = DaemonGuard::acquire()?;
    unsafe {
        libc::signal(libc::SIGTERM, on_signal as *const () as libc::sighandler_t);
        libc::signal(libc::SIGINT, on_signal as *const () as libc::sighandler_t);
    }
    let db = Db::open_default()?;
    db.log("info", "daemon started")?;

    let config = Config::load()?;
    let volume = Arc::new(SmartVolume::new(Db::open_default()?, config.clone(), default_embedder())?);
    if let Backend::Mirror(root) = &backend {
        slim_fs::mirror::Mirror::new(root.clone(), &volume).sync(&config)?;
    }

    // Keep capability info around for the app (spawning the helper is not free).
    if let Some(h) = slim_core::helper::Helper::locate(config.helper_path.as_deref()) {
        if let Ok(c) = h.capabilities() {
            db.set_state("capabilities", &serde_json::json!({ "ocr": c.ocr, "foundation_models": c.foundation_models }).to_string())?;
        }
    }

    let indexer = thread::Builder::new().name("indexer".into()).spawn(index_loop)?;

    #[cfg(feature = "fuse")]
    let mut _session = None;
    let mut mirror_root = None;
    match backend {
        Backend::None => db.set_state("mount", "null")?,
        Backend::Mirror(root) => {
            db.set_state("mount", &serde_json::json!({ "backend": "mirror", "path": root }).to_string())?;
            mirror_root = Some(root);
        }
        #[cfg(feature = "fuse")]
        Backend::Fuse(mp) => {
            _session = Some(slim_fs::fuse::mount(volume.clone(), &mp)?);
            db.set_state("mount", &serde_json::json!({ "backend": "fuse", "path": mp }).to_string())?;
        }
        #[cfg(not(feature = "fuse"))]
        Backend::Fuse(_) => {
            anyhow::bail!("this build has no FUSE support: install FUSE-T or macFUSE and rebuild with `--features fuse`, or use --mirror")
        }
    }

    // Main thread: keep the drive in step with the index and the user's actions.
    let mut last_generation = -1;
    let mut last_config = std::fs::read(Config::path()).unwrap_or_default();
    while !stopping() {
        let raw = std::fs::read(Config::path()).unwrap_or_default();
        if raw != last_config {
            last_config = raw;
            volume.reload_config();
        }
        if let Some(root) = &mirror_root {
            let config = Config::load().unwrap_or_default();
            let mirror = slim_fs::mirror::Mirror::new(root.clone(), &volume);
            match mirror.sync(&config) {
                Ok(r) if r.user_changes() => log::info!("mirror: {r:?}"),
                Ok(_) => {}
                Err(e) => log::warn!("mirror sync failed: {e}"),
            }
        } else {
            let g = db.generation().unwrap_or(0);
            if g != last_generation {
                last_generation = g;
                volume.invalidate();
            }
        }
        thread::sleep(Duration::from_millis(1500));
    }

    let _ = indexer.join();
    db.log("info", "daemon stopped")?;
    db.set_state("state", "stopped")?;
    db.set_state("mount", "null")?;
    Ok(())
}

fn index_loop() {
    lower_priority();
    if let Err(e) = index_loop_inner() {
        log::error!("indexer stopped: {e}");
        if let Ok(db) = Db::open_default() {
            let _ = db.log("error", &format!("indexer stopped: {e}"));
        }
    }
}

fn index_loop_inner() -> Result<()> {
    let embedder = default_embedder();
    let mut db = Db::open_default()?;
    let mut config = Config::load()?;

    let (tx, rx) = channel::<PathBuf>();
    let make_watcher = |config: &Config| -> Result<notify::RecommendedWatcher> {
        let tx = tx.clone();
        let mut w = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
            if let Ok(ev) = res {
                for p in ev.paths {
                    let _ = tx.send(p);
                }
            }
        })?;
        for f in config.folders.iter().chain(std::iter::once(&config.inbox_path)) {
            if f.is_dir() {
                if let Err(e) = w.watch(f, RecursiveMode::Recursive) {
                    log::warn!("cannot watch {}: {e}", f.display());
                }
            }
        }
        Ok(w)
    };
    let mut watcher = make_watcher(&config)?;
    let mut last_scan: Option<Instant> = None;
    let mut pending: BTreeSet<PathBuf> = BTreeSet::new();

    while !stopping() {
        let fresh = Config::load().unwrap_or_else(|_| config.clone());
        if fresh.folders != config.folders || fresh.store_full_text != config.store_full_text {
            watcher = make_watcher(&fresh)?;
            last_scan = None;
        }
        config = fresh;
        let _ = &watcher;
        // `slim rescan` (the app's refresh button) asks for a full pass now.
        if db.get_state("rescan_requested")?.as_deref() == Some("1") {
            db.set_state("rescan_requested", "")?;
            last_scan = None;
        }

        if config.paused {
            db.set_state("state", "paused")?;
            // Bound each collection pass so continuous events cannot prevent
            // Resume or Quit from being observed.
            let until = Instant::now() + Duration::from_secs(2);
            while !stopping() && Instant::now() < until {
                match rx.recv_timeout(Duration::from_millis(200)) {
                    Ok(p) => { pending.insert(p); }
                    Err(_) => break,
                }
            }
            continue;
        }
        // On battery only the big full scan waits; single new files are still indexed.
        let battery = config.pause_on_battery && on_battery();
        if !battery && last_scan.is_none_or(|t| t.elapsed() > RESCAN) {
            db.set_state("state", "indexing")?;
            let report = {
                let mut ix = Indexer::new(&mut db, &config, embedder.as_ref());
                let state_db = Db::open_default()?;
                ix.scan(
                    |i, n, p| {
                        if i % 5 == 0 || i + 1 == n {
                            let _ = state_db.set_state("progress_done", &i.to_string());
                            let _ = state_db.set_state("progress_total", &n.to_string());
                            let _ = state_db.set_state("current", &p.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_default());
                        }
                    },
                    || stopping() || Config::load().map(|c| c.paused || c.folders != config.folders || (c.pause_on_battery && on_battery())).unwrap_or(true),
                )?
            };
            db.set_state("progress_done", &report.total.to_string())?;
            db.set_state("current", "")?;
            views::refresh_all(&mut db, embedder.as_ref())?;
            db.bump_generation()?;
            db.set_state("last_scan", &chrono::Utc::now().timestamp().to_string())?;
            if report.indexed + report.removed + report.failed > 0 {
                db.log("info", &format!("scan: {} indexed, {} removed, {} failed", report.indexed, report.removed, report.failed))?;
            }
            if !report.interrupted {
                last_scan = Some(Instant::now());
            }
            db.set_state("state", "idle")?;
            continue;
        }
        let idle_state = if battery && last_scan.is_none_or(|t| t.elapsed() > RESCAN) { "battery" } else { "idle" };
        db.set_state("state", idle_state)?;

        // Debounce file events: collect for a moment, then index in one batch.
        match rx.recv_timeout(Duration::from_secs(2)) {
            Ok(p) => {
                pending.insert(p);
                let until = Instant::now() + Duration::from_millis(1500);
                while let Ok(p) = rx.recv_timeout(until.saturating_duration_since(Instant::now())) {
                    pending.insert(p);
                }
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
        if pending.is_empty() {
            continue;
        }
        db.set_state("state", "indexing")?;
        let mut changed = 0;
        {
            let mut ix = Indexer::new(&mut db, &config, embedder.as_ref());
            for p in std::mem::take(&mut pending) {
                let hidden = p.components().any(|c| c.as_os_str().to_string_lossy().starts_with('.'));
                if hidden || !(config.is_watched(&p) || p.starts_with(&config.inbox_path)) {
                    continue;
                }
                if !p.exists() {
                    if ix.forget(&p)? {
                        changed += 1;
                    }
                    continue;
                }
                match ix.index_path(&p) {
                    Ok(Outcome::Indexed) => changed += 1,
                    Ok(_) => {}
                    Err(e) => log::warn!("{}: {e}", p.display()),
                }
            }
        }
        if changed > 0 {
            views::refresh_all(&mut db, embedder.as_ref())?;
            db.bump_generation()?;
            db.log("info", &format!("{changed} file(s) updated"))?;
        }
        db.set_state("state", idle_state)?;
    }
    Ok(())
}
