//! `slim`: the command line for the Smart Disk, and its background daemon.

mod daemon;

use anyhow::{anyhow, bail, Result};
use chrono::Local;
use clap::{Parser, Subcommand};
use serde::Serialize;
use serde_json::json;
use slim_core::categories;
use slim_core::config::{data_dir, Config};
use slim_core::db::Db;
use slim_core::embed::default_embedder;
use slim_core::helper::Helper;
use slim_core::index::Indexer;
use slim_core::query::{self, ViewQuery};
use slim_core::volume::{self, DirKind, Tree};
use slim_core::{views, why};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "slim", version, about = "Smart Disk: folders that fill themselves. mkdir is a search query.")]
struct Cli {
    /// Machine-readable output.
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Indexing state, file counts and folders.
    Status,
    /// Index the watched folders once.
    Index,
    /// Watch folders, keep the index fresh and keep the drive mounted.
    Daemon {
        /// Render the drive as a folder of links (default: ~/Slim).
        #[arg(long, value_name = "PATH", num_args = 0..=1)]
        mirror: Option<Option<PathBuf>>,
        /// Mount a real drive with macFUSE / FUSE-T (default: /Volumes/Slim).
        #[arg(long, value_name = "PATH", num_args = 0..=1)]
        fuse: Option<Option<PathBuf>>,
    },
    /// List the folders on the drive with their file counts.
    Tree,
    /// List the files in a folder of the drive.
    Ls { folder: String },
    /// Search without saving: what would a folder with this name contain?
    Query { text: String },
    /// Show how a folder name is read as a query.
    Parse { name: String },
    /// Create a smart folder (same as mkdir on the drive), or bring back a removed category.
    Mkdir { name: String },
    /// Remove a smart folder or a category. No file is touched.
    Rmdir { name: String },
    /// Rename a smart folder; its contents are recomputed.
    Mv { from: String, to: String },
    /// Explain why a file is in a folder.
    Why { path: String },
    /// Correct the drive: a file does (not) belong in a folder.
    Label {
        /// Path on the drive, or the original file's path together with --folder.
        path: String,
        #[arg(long)]
        folder: Option<String>,
        #[arg(long, conflicts_with_all = ["no", "reset"])]
        yes: bool,
        #[arg(long, conflicts_with = "reset")]
        no: bool,
        #[arg(long)]
        reset: bool,
    },
    /// Manage watched folders.
    Folders {
        #[command(subcommand)]
        action: Option<FolderAction>,
    },
    /// Show or change settings.
    Settings {
        #[command(subcommand)]
        action: Option<SettingsAction>,
    },
    /// Built-in categories.
    Categories {
        #[command(subcommand)]
        action: Option<CategoryAction>,
    },
    /// Recent activity.
    Log {
        #[arg(long, default_value_t = 50)]
        limit: usize,
    },
    /// Render the mirror folder once.
    Sync,
    /// What this Mac supports (OCR, Apple Intelligence, FUSE).
    Capabilities,
}

#[derive(Subcommand)]
enum FolderAction {
    List,
    Add { path: PathBuf },
    Remove { path: PathBuf },
}

#[derive(Subcommand)]
enum CategoryAction {
    List,
    /// Remove a category folder (by id or name). Files keep their labels.
    Hide { name: String },
    /// Bring back a removed category (by id or name).
    Show { name: String },
}

#[derive(Subcommand)]
enum SettingsAction {
    Show,
    /// Keys: sensitive, full-text, pause-on-battery, paused, apple-intelligence, mirror-path, fuse-mount-point, inbox-path
    Set { key: String, value: String },
}

fn print<T: Serialize>(json: bool, value: &T, human: impl FnOnce(&T)) -> Result<()> {
    if json {
        println!("{}", serde_json::to_string_pretty(value)?);
    } else {
        human(value);
    }
    Ok(())
}

fn helper_for_queries(config: &Config) -> Option<Helper> {
    config.use_apple_intelligence.then(|| Helper::locate(config.helper_path.as_deref())).flatten()
}

#[derive(Serialize)]
struct FolderSummary {
    name: String,
    kind: &'static str,
    id: serde_json::Value,
    symbol: String,
    count: usize,
    query: Option<serde_json::Value>,
    chips: Vec<String>,
}

fn summaries(db: &Db, tree: &Tree) -> Result<Vec<FolderSummary>> {
    let views = db.views()?;
    Ok(tree
        .dirs
        .iter()
        .map(|d| match &d.kind {
            DirKind::Category(c) => FolderSummary {
                name: d.name.clone(),
                kind: "category",
                id: json!(c),
                symbol: categories::by_id(c).map(|c| c.symbol).unwrap_or("folder").to_owned(),
                count: d.entries.len(),
                query: None,
                chips: Vec::new(),
            },
            DirKind::View(id) => {
                let q = views.iter().find(|v| v.id == *id).map(|v| v.query.clone());
                let chips = q.clone().and_then(|q| serde_json::from_value::<ViewQuery>(q).ok()).map(|q| q.describe()).unwrap_or_default();
                FolderSummary { name: d.name.clone(), kind: "smart_folder", id: json!(id), symbol: "sparkle.magnifyingglass".into(), count: d.entries.len(), query: q, chips }
            }
        })
        .collect())
}

#[derive(Serialize)]
struct Item {
    name: String,
    file_id: i64,
    original: PathBuf,
    origin: String,
    size: u64,
    kind: String,
    doc_date: Option<String>,
    file_date: String,
    amount: Option<f64>,
    currency: Option<String>,
    score: f32,
    reasons: Vec<String>,
}

fn item(db: &Db, name: String, file_id: i64, score: f32, reasons: Vec<String>) -> Result<Option<Item>> {
    let Some(f) = db.file_by_id(file_id)? else { return Ok(None) };
    let main = f.facts.main_amount().cloned();
    Ok(Some(Item {
        name,
        file_id,
        origin: f.origin(),
        original: f.path.clone(),
        size: f.size,
        kind: f.kind.clone(),
        doc_date: f.doc_date.map(|d| d.to_string()),
        file_date: f.file_date.to_string(),
        amount: main.as_ref().map(|a| a.value),
        currency: main.map(|a| a.currency),
        score,
        reasons,
    }))
}

fn print_items(items: &Vec<Item>) {
    if items.is_empty() {
        println!("(empty)");
    }
    for i in items {
        let amount = i.amount.map(|a| format!("  {a:.2} {}", i.currency.as_deref().unwrap_or(""))).unwrap_or_default();
        println!("{:>4.0}%  {}{}  ← {}", i.score * 100.0, i.name, amount, i.original.display());
    }
}

fn daemon_pid() -> Option<i32> {
    let pid: i32 = std::fs::read_to_string(data_dir().join("daemon.pid")).ok()?.trim().parse().ok()?;
    (unsafe { libc::kill(pid, 0) } == 0).then_some(pid)
}

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn")).init();
    let cli = Cli::parse();
    let json = cli.json;
    let mut config = Config::load()?;
    let embedder = default_embedder();

    match cli.command {
        Command::Status => {
            let db = Db::open_default()?;
            let tree = Tree::build(&db, &config)?;
            let (total, indexed) = db.count_files()?;
            let state = |k: &str| db.get_state(k).ok().flatten();
            let pid = daemon_pid();
            let status = json!({
                "daemon_running": pid.is_some(),
                "daemon_pid": pid,
                "state": if pid.is_some() { state("state").unwrap_or_else(|| "idle".into()) } else { "stopped".into() },
                "progress_done": state("progress_done").and_then(|v| v.parse::<i64>().ok()).unwrap_or(0),
                "progress_total": state("progress_total").and_then(|v| v.parse::<i64>().ok()).unwrap_or(0),
                "current": state("current"),
                "last_scan": state("last_scan").and_then(|v| v.parse::<i64>().ok()),
                "mount": state("mount").and_then(|v| serde_json::from_str::<serde_json::Value>(&v).ok()),
                "files_total": total,
                "files_indexed": indexed,
                "generation": tree.generation,
                "folders": summaries(&db, &tree)?,
                "config": config,
                "data_dir": data_dir(),
            });
            print(json, &status, |s| {
                println!("Smart Disk — {}", s["state"].as_str().unwrap_or("?"));
                println!("{} files indexed ({} seen)", s["files_indexed"], s["files_total"]);
                if let Some(m) = s["mount"].as_object() {
                    println!("Drive: {} ({})", m["path"].as_str().unwrap_or("?"), m["backend"].as_str().unwrap_or("?"));
                }
                for f in s["folders"].as_array().into_iter().flatten() {
                    println!("  {:>5}  {}", f["count"], f["name"].as_str().unwrap_or(""));
                }
            })
        }
        Command::Index => {
            let mut db = Db::open_default()?;
            let report = {
                let mut ix = Indexer::new(&mut db, &config, embedder.as_ref());
                let quiet = json;
                ix.scan(
                    |i, n, p| {
                        if !quiet {
                            eprint!("\r\x1b[2K[{}/{}] {}", i + 1, n, p.file_name().map(|f| f.to_string_lossy()).unwrap_or_default());
                        }
                    },
                    || false,
                )?
            };
            if !json {
                eprintln!();
            }
            views::refresh_all(&mut db, embedder.as_ref())?;
            db.bump_generation()?;
            db.set_state("last_scan", &chrono::Utc::now().timestamp().to_string())?;
            print(json, &report, |r| {
                println!("{} indexed, {} unchanged, {} skipped, {} failed, {} removed", r.indexed, r.unchanged, r.skipped, r.failed, r.removed)
            })
        }
        Command::Daemon { mirror, fuse } => {
            let backend = match (fuse, mirror) {
                (Some(fuse), _) => daemon::Backend::Fuse(fuse.unwrap_or_else(|| config.fuse_mount_point.clone())),
                (None, Some(mirror)) => daemon::Backend::Mirror(mirror.unwrap_or_else(|| config.mirror_path.clone())),
                (None, None) => daemon::Backend::None,
            };
            daemon::run(backend)
        }
        Command::Tree => {
            let db = Db::open_default()?;
            let tree = Tree::build(&db, &config)?;
            print(json, &summaries(&db, &tree)?, |s| {
                for f in s {
                    let chips = if f.chips.is_empty() { String::new() } else { format!("   [{}]", f.chips.join(" · ")) };
                    println!("{:>5}  {}{}", f.count, f.name, chips);
                }
            })
        }
        Command::Ls { folder } => {
            let db = Db::open_default()?;
            let tree = Tree::build(&db, &config)?;
            let d = tree.dir(&folder).ok_or_else(|| anyhow!("no folder named \"{folder}\" (see `slim tree`)"))?;
            let mut items = Vec::new();
            for e in &d.entries {
                if let Some(i) = item(&db, e.name.clone(), e.file_id, e.score, e.reasons.clone())? {
                    items.push(i);
                }
            }
            print(json, &items, print_items)
        }
        Command::Query { text } => {
            let db = Db::open_default()?;
            let q = query::parse(&text, Local::now().date_naive(), helper_for_queries(&config).as_ref());
            let mut items = Vec::new();
            for m in views::evaluate(&db, &q, embedder.as_ref(), None)? {
                if let Some(f) = db.file_by_id(m.file_id)? {
                    if let Some(i) = item(&db, f.file_name(), m.file_id, m.score, m.reasons)? {
                        items.push(i);
                    }
                }
            }
            print(json, &json!({ "query": q, "chips": q.describe(), "items": items }), |_| {
                println!("query: {}", q.describe().join(" · "));
                print_items(&items);
            })
        }
        Command::Parse { name } => {
            let q = query::parse(&name, Local::now().date_naive(), helper_for_queries(&config).as_ref());
            print(json, &json!({ "query": q, "chips": q.describe() }), |_| {
                println!("{}", serde_json::to_string_pretty(&q).unwrap());
            })
        }
        Command::Mkdir { name } => {
            let mut db = Db::open_default()?;
            if volume::restore_category(&db, &name).map_err(|e| anyhow!("{e}"))? {
                return print(json, &json!({ "restored": name }), |_| println!("brought back \"{name}\""));
            }
            let id = volume::create_view(&mut db, embedder.as_ref(), helper_for_queries(&config).as_ref(), &name).map_err(|e| anyhow!("{e}"))?;
            let n = db.view_items(id)?.len();
            print(json, &json!({ "id": id, "name": name, "count": n }), |_| println!("created \"{name}\" with {n} files"))
        }
        Command::Rmdir { name } => {
            let db = Db::open_default()?;
            volume::delete_view(&db, &name).map_err(|e| anyhow!("{e}"))?;
            print(json, &json!({ "removed": name }), |_| println!("removed \"{name}\" — no files were touched"))
        }
        Command::Mv { from, to } => {
            let mut db = Db::open_default()?;
            volume::rename_view(&mut db, embedder.as_ref(), helper_for_queries(&config).as_ref(), &from, &to).map_err(|e| anyhow!("{e}"))?;
            print(json, &json!({ "from": from, "to": to }), |_| println!("renamed \"{from}\" → \"{to}\""))
        }
        Command::Why { path } => {
            let db = Db::open_default()?;
            let e = why::explain(&db, &config, &path)?;
            print(json, &e, |e| {
                println!("{}", e.original.display());
                println!("text: {} characters via {}", e.text_chars, e.text_method);
                if let Some(a) = e.facts.main_amount() {
                    println!("amount: {:.2} {}{}", a.value, a.currency, if a.is_total { " (total)" } else { "" });
                }
                if let Some(d) = e.facts.doc_date {
                    println!("date: {d}");
                }
                for p in &e.placements {
                    let mark = if p.included { "✓" } else { "·" };
                    let who = match p.source.as_str() { "user_yes" => " (you)", "user_no" => " (removed by you)", _ => "" };
                    println!("{mark} {:<24} {:>4.0}%{who}  {}", p.folder, p.score * 100.0, p.reasons.join("; "));
                }
                for s in &e.snippets {
                    println!("  “{s}”");
                }
            })
        }
        Command::Label { path, folder, yes, no, reset } => {
            if !(yes || no || reset) {
                bail!("pass --yes, --no or --reset");
            }
            let mut db = Db::open_default()?;
            let tree = Tree::build(&db, &config)?;
            let mounts = [config.fuse_mount_point.clone(), config.mirror_path.clone()];
            let (dir, file_id) = match (volume::resolve_drive_path(&tree, &path, &mounts), folder) {
                (_, Some(folder)) => {
                    let d = tree.dir(&folder).ok_or_else(|| anyhow!("no folder named \"{folder}\""))?.clone();
                    let p = std::path::Path::new(&path);
                    let p = p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
                    let f = db.file_by_path(&p)?.ok_or_else(|| anyhow!("{path} is not in the index"))?;
                    (d, f.id)
                }
                (Some((d, f)), None) => (d, f.file_id),
                (None, None) => bail!("give a path on the drive, or --folder with the original's path"),
            };
            let key = dir.kind.label_key();
            if reset {
                db.clear_user_label(file_id, &key)?;
            } else {
                db.set_user_label(file_id, &key, yes)?;
            }
            views::refresh_all(&mut db, embedder.as_ref())?;
            db.bump_generation()?;
            let verdict = if reset { "reset" } else if yes { "belongs here" } else { "does not belong here" };
            db.log("info", &format!("label for file {file_id} in \"{}\": {verdict}", dir.name))?;
            print(json, &json!({ "folder": dir.name, "file_id": file_id, "label": verdict }), |_| println!("{}: {verdict}", dir.name))
        }
        Command::Folders { action } => {
            match action.unwrap_or(FolderAction::List) {
                FolderAction::List => {}
                FolderAction::Add { path } => {
                    let p = path.canonicalize().map_err(|e| anyhow!("{}: {e}", path.display()))?;
                    if !p.is_dir() {
                        bail!("{} is not a folder", p.display());
                    }
                    if !config.folders.contains(&p) {
                        config.folders.push(p);
                        config.save()?;
                    }
                }
                FolderAction::Remove { path } => {
                    let p = path.canonicalize().unwrap_or(path);
                    config.folders.retain(|f| f != &p);
                    config.save()?;
                }
            }
            print(json, &config.folders, |f| f.iter().for_each(|p| println!("{}", p.display())))
        }
        Command::Settings { action } => {
            if let Some(SettingsAction::Set { key, value }) = action {
                let flag = || -> Result<bool> {
                    match value.as_str() {
                        "true" | "on" | "yes" | "1" => Ok(true),
                        "false" | "off" | "no" | "0" => Ok(false),
                        _ => bail!("expected true or false"),
                    }
                };
                match key.as_str() {
                    "sensitive" => config.sensitive_enabled = flag()?,
                    "full-text" => config.store_full_text = flag()?,
                    "pause-on-battery" => config.pause_on_battery = flag()?,
                    "paused" => config.paused = flag()?,
                    "apple-intelligence" => config.use_apple_intelligence = flag()?,
                    "mirror-path" => config.mirror_path = PathBuf::from(&value),
                    "fuse-mount-point" => config.fuse_mount_point = PathBuf::from(&value),
                    "inbox-path" => config.inbox_path = PathBuf::from(&value),
                    _ => bail!("unknown setting {key}"),
                }
                config.save()?;
                let db = Db::open_default()?;
                db.bump_generation()?;
            }
            print(json, &config, |c| println!("{}", serde_json::to_string_pretty(c).unwrap()))
        }
        Command::Categories { action } => {
            match action {
                Some(CategoryAction::Hide { name }) => {
                    let db = Db::open_default()?;
                    let cat = categories::by_id(&name).or_else(|| categories::by_name(&name)).ok_or_else(|| anyhow!("no category named \"{name}\""))?;
                    volume::hide_category(&db, cat.id).map_err(|e| anyhow!("{e}"))?;
                }
                Some(CategoryAction::Show { name }) => {
                    let db = Db::open_default()?;
                    if categories::by_id(&name).or_else(|| categories::by_name(&name)).is_none() {
                        bail!("no category named \"{name}\"");
                    }
                    volume::restore_category(&db, &name).map_err(|e| anyhow!("{e}"))?;
                }
                Some(CategoryAction::List) | None => {}
            }
            let config = Config::load()?;
            let rows: Vec<_> = categories::ALL
                .iter()
                .map(|c| {
                    let mut row = json!(c);
                    row["hidden"] = json!(!config.shows_category(c));
                    row
                })
                .collect();
            print(json, &rows, |_| {
                for c in categories::ALL {
                    let note = if config.hidden_categories.iter().any(|h| h == c.id) {
                        "  (removed)"
                    } else if c.sensitive && !config.sensitive_enabled {
                        "  (hidden: sensitive)"
                    } else {
                        ""
                    };
                    println!("{:<14} {}{note}", c.name, c.description);
                }
            })
        }
        Command::Log { limit } => {
            let db = Db::open_default()?;
            print(json, &db.recent_log(limit)?, |rows| {
                for r in rows.iter().rev() {
                    let t = chrono::DateTime::from_timestamp(r.ts, 0).map(|d| d.with_timezone(&Local).format("%H:%M:%S").to_string()).unwrap_or_default();
                    println!("{t} {:<5} {}", r.level, r.message);
                }
            })
        }
        Command::Sync => {
            let db = Db::open_default()?;
            let vol = volume::SmartVolume::new(db, config.clone(), default_embedder())?;
            let mirror = slim_fs::mirror::Mirror::new(config.mirror_path.clone(), &vol);
            let report = mirror.sync(&config)?;
            print(json, &report, |r| println!("{} links added, {} removed in {}", r.links_added, r.links_removed, config.mirror_path.display()))
        }
        Command::Capabilities => {
            let helper = Helper::locate(config.helper_path.as_deref());
            let caps = helper.as_ref().and_then(|h| h.capabilities().ok()).unwrap_or_default();
            let value = json!({
                "helper": helper.as_ref().map(|h| h.path.clone()),
                "ocr": caps.ocr,
                "foundation_models": caps.foundation_models,
                "foundation_models_reason": caps.foundation_models_reason,
                "fuse": slim_fs::FUSE_AVAILABLE,
                "embedder": embedder.id(),
            });
            print(json, &value, |v| println!("{}", serde_json::to_string_pretty(v).unwrap()))
        }
    }
}
