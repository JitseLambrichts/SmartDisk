//! Evaluating smart folders: which files does a [`ViewQuery`] select, and why.

use crate::db::{Db, FileRow};
use crate::embed::{cosine, Embedder};
use crate::query::ViewQuery;
use crate::text::{contains_term, file_name_words, token_string};
use anyhow::Result;
use chrono::{Datelike, NaiveDate};
use serde::Serialize;
use std::collections::HashMap;

#[derive(Debug, Clone, Serialize)]
pub struct Match {
    pub file_id: i64,
    pub score: f32,
    pub reasons: Vec<String>,
}

/// Below this, a topic-only match is not shown. Trust over recall.
const MIN_TOPIC_SCORE: f32 = 0.34;

fn in_range(d: NaiveDate, from: NaiveDate, to: NaiveDate) -> bool {
    d >= from && d <= to
}

pub fn evaluate(db: &Db, q: &ViewQuery, embedder: &dyn Embedder, view_key: Option<&str>) -> Result<Vec<Match>> {
    if q.is_empty() {
        return Ok(Vec::new());
    }
    let category_members: Option<HashMap<i64, f32>> = match &q.category {
        Some(c) => Some(db.members(c)?.into_iter().collect()),
        None => None,
    };
    let (user_yes, user_no): (Vec<i64>, Vec<i64>) = match view_key {
        Some(key) => {
            let mut yes = Vec::new();
            let mut no = Vec::new();
            let mut st = db.conn.prepare("SELECT file_id, source FROM labels WHERE category = ?1 AND source != 'auto'")?;
            for row in st.query_map([key], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))? {
                let (id, src) = row?;
                if src == "user_yes" { yes.push(id) } else { no.push(id) }
            }
            (yes, no)
        }
        None => (Vec::new(), Vec::new()),
    };
    let query_embedding = q.free_text.as_ref().map(|t| {
        let expanded: Vec<String> = q.topics.iter().flat_map(|t| t.terms.clone()).collect();
        embedder.embed(&format!("{t} {}", expanded.join(" ")))
    });

    let mut out = Vec::new();
    for f in db.files()? {
        if user_no.contains(&f.id) {
            continue;
        }
        if user_yes.contains(&f.id) {
            out.push(Match { file_id: f.id, score: 1.0, reasons: vec!["you added this file here".into()] });
            continue;
        }
        if let Some(m) = matches(db, &f, q, category_members.as_ref(), query_embedding.as_deref())? {
            out.push(m);
        }
    }
    out.sort_by(|a, b| b.score.total_cmp(&a.score));
    Ok(out)
}

fn matches(
    db: &Db,
    f: &FileRow,
    q: &ViewQuery,
    members: Option<&HashMap<i64, f32>>,
    query_embedding: Option<&[f32]>,
) -> Result<Option<Match>> {
    let mut reasons = Vec::new();
    let mut score = 1.0f32;

    if let (Some(members), Some(cat)) = (members, q.category.as_deref()) {
        let Some(conf) = members.get(&f.id) else { return Ok(None) };
        let name = crate::categories::by_id(cat).map(|c| c.name).unwrap_or(cat);
        reasons.push(format!("in {name} ({:.0}%)", conf.min(1.0) * 100.0));
        score *= conf.min(1.0).max(0.5);
    }
    if !q.extensions.is_empty() && !q.extensions.contains(&f.extension()) {
        return Ok(None);
    }
    if let Some(y) = q.year {
        // Absolute years: the date in the document wins over the file date.
        let (date, which) = match f.doc_date {
            Some(d) => (d, "document date"),
            None => (f.file_date, "file date"),
        };
        if date.year() != y {
            return Ok(None);
        }
        reasons.push(format!("{which} {date}"));
    }
    if let (Some(from), Some(to)) = (q.date_from, q.date_to) {
        // Relative periods: either the document date or when the file arrived.
        let doc_hit = f.doc_date.filter(|d| in_range(*d, from, to));
        if let Some(d) = doc_hit {
            reasons.push(format!("document date {d}"));
        } else if in_range(f.file_date, from, to) {
            reasons.push(format!("file date {}", f.file_date));
        } else {
            return Ok(None);
        }
    }
    if q.amount_min.is_some() || q.amount_max.is_some() {
        let Some(a) = f.facts.main_amount() else { return Ok(None) };
        if q.currency.as_deref().is_some_and(|c| c != a.currency) {
            return Ok(None);
        }
        if q.amount_min.is_some_and(|min| a.value <= min) || q.amount_max.is_some_and(|max| a.value >= max) {
            return Ok(None);
        }
        reasons.push(format!("amount {:.2} {}", a.value, a.currency));
    }
    if q.needs_code {
        if !f.facts.has_code {
            return Ok(None);
        }
        reasons.push("contains a code".into());
    }

    if !q.topics.is_empty() {
        let text = db.text(f.id)?;
        let tokens = token_string(&format!("{} {}", file_name_words(&f.file_name()), text));
        let mut hit_groups = 0;
        for topic in &q.topics {
            if let Some(term) = topic.terms.iter().find(|t| contains_term(&tokens, t)) {
                hit_groups += 1;
                if term == &topic.word {
                    reasons.push(format!("mentions \"{term}\""));
                } else {
                    reasons.push(format!("\"{}\" → mentions \"{term}\"", topic.word));
                }
            }
        }
        let lexical = hit_groups as f32 / q.topics.len() as f32;
        let semantic = match query_embedding {
            Some(qe) => db.chunks(f.id)?.iter().map(|(_, e)| cosine(qe, e)).fold(0.0f32, f32::max),
            None => 0.0,
        };
        let semantic_norm = ((semantic - 0.05) / 0.35).clamp(0.0, 1.0);
        let topic_score = 0.7 * lexical + 0.3 * semantic_norm;
        if topic_score < MIN_TOPIC_SCORE || (lexical == 0.0 && semantic < 0.4) {
            return Ok(None);
        }
        if semantic > 0.1 {
            reasons.push(format!("similarity {semantic:.2}"));
        }
        score *= topic_score.max(0.4);
    }
    Ok(Some(Match { file_id: f.id, score: score.clamp(0.0, 1.0), reasons }))
}

/// Recomputes the cached contents of every smart folder.
pub fn refresh_all(db: &mut Db, embedder: &dyn Embedder) -> Result<()> {
    for v in db.views()? {
        let q: ViewQuery = serde_json::from_value(v.query.clone()).unwrap_or_default();
        let items = evaluate(db, &q, embedder, Some(&format!("view:{}", v.id)))?;
        let rows: Vec<_> = items.into_iter().map(|m| (m.file_id, m.score, m.reasons)).collect();
        db.replace_view_items(v.id, &rows)?;
    }
    Ok(())
}
