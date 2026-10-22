//! Looks for words inside documents, in the text the index keeps.

use crate::db::Db;
use crate::text::{contains_term, is_stopword, snippet, token_string, tokens};
use anyhow::Result;
use serde::Serialize;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct TextHit {
    pub file_id: i64,
    /// A few words around the first hit, to show why the file matched.
    pub snippet: String,
}

/// Files among `file_ids` whose text holds every word of `text`, in that order of ids.
/// Words match at their start ("factuur" also finds "factuurnummer") and ignore case and
/// accents. Finds nothing when the index keeps no document text (`store_full_text` off).
pub fn find_text(db: &Db, file_ids: &[i64], text: &str) -> Result<Vec<TextHit>> {
    let mut words: Vec<String> = tokens(text).into_iter().filter(|w| !is_stopword(w)).collect();
    if words.is_empty() {
        // Only stopwords, like "de": search for them after all.
        words = tokens(text);
    }
    if words.is_empty() {
        return Ok(Vec::new());
    }
    let mut hits = Vec::new();
    for &id in file_ids {
        let body = db.text(id)?;
        if body.is_empty() {
            continue;
        }
        let words_in_body = token_string(&body);
        if words.iter().all(|w| contains_term(&words_in_body, w)) {
            // PDFs mark images with U+FFFC; it shows as a box.
            let snippet = snippet(&body, &words[0], 40).unwrap_or_default().replace('\u{fffc}', "").trim().to_owned();
            hits.push(TextHit { file_id: id, snippet });
        }
    }
    Ok(hits)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(db: &Db, id: i64, text: &str) {
        db.conn
            .execute(
                "INSERT INTO files (id, path, root, size, mtime, hash, kind, method, status, file_date, facts, indexed_at)
                 VALUES (?1, ?2, '/', 0, 0, '', 'pdf', 'text', 'ok', '2025-01-01', '{}', 0)",
                rusqlite::params![id, format!("/f{id}.pdf")],
            )
            .unwrap();
        db.conn
            .execute("INSERT INTO chunks (file_id, ord, text, embedding) VALUES (?1, 0, ?2, x'')", rusqlite::params![id, text])
            .unwrap();
    }

    #[test]
    fn finds_every_word_at_word_starts() {
        let db = Db::open_in_memory().unwrap();
        file(&db, 1, "Huurcontract voor de studio in Leuven. Opzegtermijn: drie maanden.");
        file(&db, 2, "Factuurnummer 0423 voor het café");
        file(&db, 3, "Niets over huur hier");

        let hits = find_text(&db, &[1, 2, 3], "huurcontract leuven").unwrap();
        assert_eq!(hits.iter().map(|h| h.file_id).collect::<Vec<_>>(), [1]);
        assert!(hits[0].snippet.contains("Huurcontract"));

        // Prefix, case and accents.
        let ids = |q| find_text(&db, &[1, 2, 3], q).unwrap().iter().map(|h| h.file_id).collect::<Vec<_>>();
        assert_eq!(ids("FACTUUR cafe"), [2]);
        assert_eq!(ids("huur"), [1, 3]);
        // Not in the middle of a word.
        assert!(ids("contract").is_empty());
        // Only the files asked about.
        assert_eq!(find_text(&db, &[3], "huur").unwrap().len(), 1);
    }
}
