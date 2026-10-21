//! SQLite index. It stores text, facts and vectors — never file contents.

use crate::embed::from_blob;
use crate::facts::Facts;
use anyhow::Result;
use chrono::NaiveDate;
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::time::Duration;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS files (
    id          INTEGER PRIMARY KEY,
    path        TEXT NOT NULL UNIQUE,
    root        TEXT NOT NULL,
    size        INTEGER NOT NULL,
    mtime       INTEGER NOT NULL,
    hash        TEXT NOT NULL,
    kind        TEXT NOT NULL,
    method      TEXT NOT NULL,
    status      TEXT NOT NULL,
    error       TEXT,
    file_date   TEXT NOT NULL,
    doc_date    TEXT,
    amount      REAL,
    currency    TEXT,
    facts       TEXT NOT NULL,
    text_len    INTEGER NOT NULL DEFAULT 0,
    embedding   BLOB,
    indexed_at  INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS chunks (
    id        INTEGER PRIMARY KEY,
    file_id   INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    ord       INTEGER NOT NULL,
    text      TEXT,
    embedding BLOB NOT NULL
);
CREATE INDEX IF NOT EXISTS chunks_file ON chunks(file_id);
-- category is a category id ("invoices") or a view key ("view:3").
-- source: auto | user_yes | user_no
CREATE TABLE IF NOT EXISTS labels (
    file_id    INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    category   TEXT NOT NULL,
    source     TEXT NOT NULL,
    confidence REAL NOT NULL,
    included   INTEGER NOT NULL,
    reasons    TEXT NOT NULL DEFAULT '[]',
    PRIMARY KEY (file_id, category, source)
);
CREATE TABLE IF NOT EXISTS views (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    query      TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS view_items (
    view_id INTEGER NOT NULL REFERENCES views(id) ON DELETE CASCADE,
    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    score   REAL NOT NULL,
    reasons TEXT NOT NULL DEFAULT '[]',
    PRIMARY KEY (view_id, file_id)
);
CREATE TABLE IF NOT EXISTS state (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS log (
    id      INTEGER PRIMARY KEY,
    ts      INTEGER NOT NULL,
    level   TEXT NOT NULL,
    message TEXT NOT NULL
);
"#;

pub struct Db {
    pub conn: Connection,
}

#[derive(Debug, Clone, Serialize)]
pub struct FileRow {
    pub id: i64,
    pub path: PathBuf,
    pub root: PathBuf,
    pub size: u64,
    pub mtime: i64,
    pub hash: String,
    pub kind: String,
    pub method: String,
    pub status: String,
    pub file_date: NaiveDate,
    pub doc_date: Option<NaiveDate>,
    pub amount: Option<f64>,
    pub currency: Option<String>,
    pub facts: Facts,
    pub text_len: i64,
    #[serde(skip)]
    pub embedding: Vec<f32>,
}

impl FileRow {
    pub fn file_name(&self) -> String {
        self.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
    }

    pub fn extension(&self) -> String {
        self.path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default()
    }

    /// Name of the folder the original lives in, used to disambiguate duplicates.
    pub fn origin(&self) -> String {
        self.path
            .parent()
            .and_then(|p| p.file_name())
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct ViewRow {
    pub id: i64,
    pub name: String,
    pub query: serde_json::Value,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct LogRow {
    pub ts: i64,
    pub level: String,
    pub message: String,
}

pub fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

const FILE_COLUMNS: &str =
    "id, path, root, size, mtime, hash, kind, method, status, file_date, doc_date, amount, currency, facts, text_len, embedding";

fn file_from_row(r: &rusqlite::Row) -> rusqlite::Result<FileRow> {
    let file_date: String = r.get(9)?;
    let doc_date: Option<String> = r.get(10)?;
    let facts: String = r.get(13)?;
    let emb: Option<Vec<u8>> = r.get(15)?;
    Ok(FileRow {
        id: r.get(0)?,
        path: PathBuf::from(r.get::<_, String>(1)?),
        root: PathBuf::from(r.get::<_, String>(2)?),
        size: r.get::<_, i64>(3)? as u64,
        mtime: r.get(4)?,
        hash: r.get(5)?,
        kind: r.get(6)?,
        method: r.get(7)?,
        status: r.get(8)?,
        file_date: file_date.parse().unwrap_or_default(),
        doc_date: doc_date.and_then(|d| d.parse().ok()),
        amount: r.get(11)?,
        currency: r.get(12)?,
        facts: serde_json::from_str(&facts).unwrap_or_default(),
        text_len: r.get(14)?,
        embedding: emb.map(|b| from_blob(&b)).unwrap_or_default(),
    })
}

impl Db {
    pub fn open(path: &Path) -> Result<Db> {
        let conn = Connection::open(path)?;
        conn.busy_timeout(Duration::from_secs(10))?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL;")?;
        conn.execute_batch(SCHEMA)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
        }
        Ok(Db { conn })
    }

    /// Opens the index in the user's data directory.
    pub fn open_default() -> Result<Db> {
        let dir = crate::config::ensure_data_dir()?;
        Db::open(&dir.join("index.sqlite"))
    }

    pub fn open_in_memory() -> Result<Db> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch("PRAGMA foreign_keys=ON;")?;
        conn.execute_batch(SCHEMA)?;
        Ok(Db { conn })
    }

    // ---- state -----------------------------------------------------------

    pub fn get_state(&self, key: &str) -> Result<Option<String>> {
        Ok(self
            .conn
            .query_row("SELECT value FROM state WHERE key = ?1", [key], |r| r.get(0))
            .optional()?)
    }

    pub fn set_state(&self, key: &str, value: &str) -> Result<()> {
        self.conn.execute(
            "INSERT INTO state(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    /// Monotonic counter that changes whenever what the drive shows changes.
    pub fn generation(&self) -> Result<i64> {
        Ok(self.get_state("generation")?.and_then(|v| v.parse().ok()).unwrap_or(0))
    }

    pub fn bump_generation(&self) -> Result<i64> {
        let g = self.generation()? + 1;
        self.set_state("generation", &g.to_string())?;
        Ok(g)
    }

    pub fn log(&self, level: &str, message: &str) -> Result<()> {
        self.conn
            .execute("INSERT INTO log(ts, level, message) VALUES (?1, ?2, ?3)", params![now(), level, message])?;
        self.conn.execute("DELETE FROM log WHERE id <= (SELECT MAX(id) - 1000 FROM log)", [])?;
        Ok(())
    }

    pub fn recent_log(&self, limit: usize) -> Result<Vec<LogRow>> {
        let mut st = self.conn.prepare("SELECT ts, level, message FROM log ORDER BY id DESC LIMIT ?1")?;
        let rows = st.query_map([limit as i64], |r| Ok(LogRow { ts: r.get(0)?, level: r.get(1)?, message: r.get(2)? }))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    // ---- files -----------------------------------------------------------

    pub fn file_by_path(&self, path: &Path) -> Result<Option<FileRow>> {
        let sql = format!("SELECT {FILE_COLUMNS} FROM files WHERE path = ?1");
        Ok(self.conn.query_row(&sql, [path.to_string_lossy()], file_from_row).optional()?)
    }

    pub fn file_by_id(&self, id: i64) -> Result<Option<FileRow>> {
        let sql = format!("SELECT {FILE_COLUMNS} FROM files WHERE id = ?1");
        Ok(self.conn.query_row(&sql, [id], file_from_row).optional()?)
    }

    pub fn files(&self) -> Result<Vec<FileRow>> {
        let sql = format!("SELECT {FILE_COLUMNS} FROM files WHERE status = 'ok' ORDER BY mtime DESC");
        let mut st = self.conn.prepare(&sql)?;
        let rows = st.query_map([], file_from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn file_stamps(&self) -> Result<Vec<(i64, PathBuf, u64, i64)>> {
        let mut st = self.conn.prepare("SELECT id, path, size, mtime FROM files")?;
        let rows = st.query_map([], |r| {
            Ok((r.get(0)?, PathBuf::from(r.get::<_, String>(1)?), r.get::<_, i64>(2)? as u64, r.get(3)?))
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn delete_file(&self, id: i64) -> Result<()> {
        self.conn.execute("DELETE FROM files WHERE id = ?1", [id])?;
        Ok(())
    }

    pub fn count_files(&self) -> Result<(i64, i64)> {
        Ok(self.conn.query_row(
            "SELECT COUNT(*), COALESCE(SUM(status = 'ok'), 0) FROM files",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?)
    }

    /// Embeddings of every chunk of a file (text may be NULL in vectors-only mode).
    pub fn chunks(&self, file_id: i64) -> Result<Vec<(Option<String>, Vec<f32>)>> {
        let mut st = self.conn.prepare("SELECT text, embedding FROM chunks WHERE file_id = ?1 ORDER BY ord")?;
        let rows = st.query_map([file_id], |r| Ok((r.get(0)?, from_blob(&r.get::<_, Vec<u8>>(1)?))))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Full stored text of a file (chunks joined).
    pub fn text(&self, file_id: i64) -> Result<String> {
        let mut st = self.conn.prepare("SELECT text FROM chunks WHERE file_id = ?1 ORDER BY ord")?;
        let rows = st.query_map([file_id], |r| r.get::<_, Option<String>>(0))?;
        let mut out = String::new();
        for t in rows.flatten().flatten() {
            out.push_str(&t);
            out.push('\n');
        }
        Ok(out)
    }

    // ---- labels ----------------------------------------------------------

    /// Effective membership for a category or view key: user labels win.
    pub fn members(&self, category: &str) -> Result<Vec<(i64, f32)>> {
        let mut st = self.conn.prepare(
            "SELECT file_id, MAX(CASE source WHEN 'user_yes' THEN 2.0 ELSE confidence END)
             FROM labels l
             WHERE category = ?1
               AND NOT EXISTS (SELECT 1 FROM labels n WHERE n.file_id = l.file_id AND n.category = l.category AND n.source = 'user_no')
               AND (source = 'user_yes' OR (source = 'auto' AND included = 1))
             GROUP BY file_id",
        )?;
        let rows = st.query_map([category], |r| Ok((r.get(0)?, r.get::<_, f64>(1)? as f32)))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn labels_for(&self, file_id: i64) -> Result<Vec<(String, String, f32, bool, Vec<String>)>> {
        let mut st = self.conn.prepare(
            "SELECT category, source, confidence, included, reasons FROM labels WHERE file_id = ?1 ORDER BY confidence DESC",
        )?;
        let rows = st.query_map([file_id], |r| {
            let reasons: String = r.get(4)?;
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get::<_, f64>(2)? as f32,
                r.get::<_, i64>(3)? == 1,
                serde_json::from_str(&reasons).unwrap_or_default(),
            ))
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Records a user correction. `yes = true` means "belongs here".
    pub fn set_user_label(&self, file_id: i64, category: &str, yes: bool) -> Result<()> {
        let (set, clear) = if yes { ("user_yes", "user_no") } else { ("user_no", "user_yes") };
        self.conn.execute(
            "DELETE FROM labels WHERE file_id = ?1 AND category = ?2 AND source = ?3",
            params![file_id, category, clear],
        )?;
        self.conn.execute(
            "INSERT OR REPLACE INTO labels(file_id, category, source, confidence, included, reasons)
             VALUES (?1, ?2, ?3, 1.0, ?4, '[\"set by you\"]')",
            params![file_id, category, set, yes as i64],
        )?;
        Ok(())
    }

    pub fn clear_user_label(&self, file_id: i64, category: &str) -> Result<()> {
        self.conn.execute(
            "DELETE FROM labels WHERE file_id = ?1 AND category = ?2 AND source != 'auto'",
            params![file_id, category],
        )?;
        Ok(())
    }

    // ---- views -----------------------------------------------------------

    pub fn views(&self) -> Result<Vec<ViewRow>> {
        let mut st = self.conn.prepare("SELECT id, name, query, created_at FROM views ORDER BY created_at, id")?;
        let rows = st.query_map([], |r| {
            let q: String = r.get(2)?;
            Ok(ViewRow { id: r.get(0)?, name: r.get(1)?, query: serde_json::from_str(&q).unwrap_or_default(), created_at: r.get(3)? })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn view_by_name(&self, name: &str) -> Result<Option<ViewRow>> {
        Ok(self.views()?.into_iter().find(|v| v.name.eq_ignore_ascii_case(name)))
    }

    pub fn insert_view(&self, name: &str, query: &serde_json::Value) -> Result<i64> {
        self.conn.execute(
            "INSERT INTO views(name, query, created_at) VALUES (?1, ?2, ?3)",
            params![name, query.to_string(), now()],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    pub fn update_view(&self, id: i64, name: &str, query: &serde_json::Value) -> Result<()> {
        self.conn
            .execute("UPDATE views SET name = ?2, query = ?3 WHERE id = ?1", params![id, name, query.to_string()])?;
        Ok(())
    }

    pub fn delete_view(&self, id: i64) -> Result<()> {
        self.conn.execute("DELETE FROM views WHERE id = ?1", [id])?;
        self.conn.execute("DELETE FROM labels WHERE category = ?1", [format!("view:{id}")])?;
        Ok(())
    }

    pub fn view_items(&self, view_id: i64) -> Result<Vec<(i64, f32, Vec<String>)>> {
        let mut st =
            self.conn.prepare("SELECT file_id, score, reasons FROM view_items WHERE view_id = ?1 ORDER BY score DESC")?;
        let rows = st.query_map([view_id], |r| {
            let reasons: String = r.get(2)?;
            Ok((r.get(0)?, r.get::<_, f64>(1)? as f32, serde_json::from_str(&reasons).unwrap_or_default()))
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn replace_view_items(&mut self, view_id: i64, items: &[(i64, f32, Vec<String>)]) -> Result<()> {
        let tx = self.conn.transaction()?;
        tx.execute("DELETE FROM view_items WHERE view_id = ?1", [view_id])?;
        {
            let mut st = tx.prepare("INSERT INTO view_items(view_id, file_id, score, reasons) VALUES (?1, ?2, ?3, ?4)")?;
            for (file_id, score, reasons) in items {
                st.execute(params![view_id, file_id, *score as f64, serde_json::to_string(reasons)?])?;
            }
        }
        tx.commit()?;
        Ok(())
    }
}
