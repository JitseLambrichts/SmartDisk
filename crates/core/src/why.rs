//! `slim why`: why is a file in a folder? Mistakes must be understandable
//! and fixable, so every placement carries its evidence.

use crate::categories;
use crate::config::Config;
use crate::db::{Db, FileRow};
use crate::facts::Facts;
use crate::text::snippet;
use crate::volume::{resolve_drive_path, DirKind, Tree};
use anyhow::{anyhow, Result};
use serde::Serialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Serialize)]
pub struct Placement {
    pub folder: String,
    pub kind: String,
    pub included: bool,
    pub score: f32,
    /// auto | user_yes | user_no
    pub source: String,
    pub reasons: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct Explanation {
    pub file_id: i64,
    pub original: PathBuf,
    pub kind: String,
    pub text_method: String,
    pub text_chars: i64,
    pub facts: Facts,
    /// The folder this question was asked about, if it came from a drive path.
    pub asked_folder: Option<String>,
    pub placements: Vec<Placement>,
    /// Quoted text that triggered the match.
    pub snippets: Vec<String>,
}

/// Accepts a path on the drive, a mirror path, or the original's own path.
pub fn explain(db: &Db, config: &Config, path: &str) -> Result<Explanation> {
    let tree = Tree::build(db, config)?;
    let mounts = [config.fuse_mount_point.clone(), config.mirror_path.clone()];
    let (file, asked) = if let Some((dir, vf)) = resolve_drive_path(&tree, path, &mounts) {
        (db.file_by_id(vf.file_id)?, Some(dir.name))
    } else {
        let p = Path::new(path);
        let p = p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
        (db.file_by_path(&p)?, None)
    };
    let file = file.ok_or_else(|| anyhow!("{path} is not in the index"))?;
    explain_file(db, &tree, &file, asked)
}

pub fn explain_file(db: &Db, tree: &Tree, file: &FileRow, asked: Option<String>) -> Result<Explanation> {
    let mut placements = Vec::new();
    let labels = db.labels_for(file.id)?;
    let user_no: Vec<String> = labels.iter().filter(|l| l.1 == "user_no").map(|l| l.0.clone()).collect();
    let user_yes: Vec<String> = labels.iter().filter(|l| l.1 == "user_yes").map(|l| l.0.clone()).collect();
    for (category, source, conf, included, reasons) in labels {
        // A correction by the user overrides the automatic verdict; show only the correction.
        if source == "auto" && (user_no.contains(&category) || user_yes.contains(&category)) {
            continue;
        }
        let (folder, kind) = if let Some(id) = category.strip_prefix("view:") {
            let Ok(id) = id.parse::<i64>() else { continue };
            let name = tree.dirs.iter().find(|d| d.kind == DirKind::View(id)).map(|d| d.name.clone()).unwrap_or(category.clone());
            (name, "smart_folder")
        } else {
            (categories::by_id(&category).map(|c| c.name.to_owned()).unwrap_or(category.clone()), "category")
        };
        placements.push(Placement { folder, kind: kind.into(), included: included && source != "user_no", score: conf, source, reasons });
    }
    for d in &tree.dirs {
        if let DirKind::View(_) = d.kind {
            if let Some(e) = d.entries.iter().find(|e| e.file_id == file.id) {
                if !placements.iter().any(|p| p.folder == d.name) {
                    placements.push(Placement {
                        folder: d.name.clone(),
                        kind: "smart_folder".into(),
                        included: true,
                        score: e.score,
                        source: "auto".into(),
                        reasons: e.reasons.clone(),
                    });
                }
            }
        }
    }
    placements.sort_by(|a, b| b.included.cmp(&a.included).then(b.score.total_cmp(&a.score)));

    // Quote the text around the words that mattered.
    let text = db.text(file.id)?;
    let mut snippets: Vec<String> = Vec::new();
    let mut terms: Vec<String> = Vec::new();
    for p in &placements {
        for r in &p.reasons {
            if let Some(list) = r.strip_prefix("keywords: ") {
                terms.extend(list.split(", ").map(str::to_owned));
            } else if let Some(start) = r.rfind("mentions \"") {
                terms.push(r[start + 10..].trim_end_matches('"').to_owned());
            }
        }
    }
    for t in terms {
        if snippets.len() >= 3 {
            break;
        }
        // One quote per passage: skip terms already visible in an earlier quote.
        if snippets.iter().any(|s| crate::text::fold(s).contains(&crate::text::fold(&t))) {
            continue;
        }
        if let Some(s) = snippet(&text, &t, 70) {
            if !snippets.contains(&s) {
                snippets.push(s);
            }
        }
    }

    Ok(Explanation {
        file_id: file.id,
        original: file.path.clone(),
        kind: file.kind.clone(),
        text_method: file.method.clone(),
        text_chars: file.text_len,
        facts: file.facts.clone(),
        asked_folder: asked,
        placements,
        snippets,
    })
}
