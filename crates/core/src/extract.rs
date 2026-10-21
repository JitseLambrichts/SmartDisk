//! Getting text out of files. Plain text is read here; PDFs, images and office
//! documents go through the Swift helper (PDFKit, Vision OCR, AppKit converters).

use crate::helper::Helper;
use std::path::Path;

pub const TEXT_EXT: &[&str] = &["txt", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm", "log", "eml", "ics", "vcf", "yaml", "yml", "tex"];
pub const IMAGE_EXT: &[&str] = &["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp"];
pub const DOC_EXT: &[&str] = &["doc", "docx", "rtf", "rtfd", "odt", "pages", "wordml"];

/// Everything bigger is indexed by name only.
const MAX_TEXT_BYTES: u64 = 4 * 1024 * 1024;
/// Text kept per file; the rest adds little for categorising.
pub const MAX_CHARS: usize = 60_000;

pub fn kind_of(ext: &str) -> Option<&'static str> {
    let ext = ext.to_lowercase();
    if ext == "pdf" {
        Some("pdf")
    } else if IMAGE_EXT.contains(&ext.as_str()) {
        Some("image")
    } else if DOC_EXT.contains(&ext.as_str()) {
        Some("document")
    } else if TEXT_EXT.contains(&ext.as_str()) {
        Some("text")
    } else {
        None
    }
}

pub struct Extraction {
    pub text: String,
    pub method: String,
    pub note: Option<String>,
}

pub fn extract(path: &Path, kind: &str, size: u64, helper: Option<&Helper>) -> Extraction {
    let result = match kind {
        "text" if size <= MAX_TEXT_BYTES => match std::fs::read(path) {
            Ok(bytes) => {
                let mut text = String::from_utf8_lossy(&bytes).into_owned();
                if matches!(path.extension().and_then(|e| e.to_str()), Some("html" | "htm" | "xml")) {
                    text = strip_tags(&text);
                }
                Ok((text, "plain".to_owned()))
            }
            Err(e) => Err(e.to_string()),
        },
        "text" => Err("file too large for text extraction".to_owned()),
        _ => match helper {
            Some(h) => h.extract(path).map(|e| (e.text, e.method)).map_err(|e| e.to_string()),
            None => Err("slim-helper not found; indexed by name only".to_owned()),
        },
    };
    match result {
        Ok((mut text, method)) => {
            if text.len() > MAX_CHARS {
                let cut = text.char_indices().nth(MAX_CHARS).map(|(i, _)| i).unwrap_or(text.len());
                text.truncate(cut);
            }
            Extraction { text, method, note: None }
        }
        Err(note) => Extraction { text: String::new(), method: "name-only".to_owned(), note: Some(note) },
    }
}

fn strip_tags(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                out.push(' ');
            }
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out
}

/// Splits text into overlapping chunks of roughly `size` characters.
pub fn chunk(text: &str, size: usize, overlap: usize) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    if chars.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut start = 0;
    while start < chars.len() {
        let mut end = (start + size).min(chars.len());
        // Prefer to cut at whitespace so words stay whole.
        if end < chars.len() {
            if let Some(ws) = (start + size / 2..end).rev().find(|i| chars[*i].is_whitespace()) {
                end = ws;
            }
        }
        out.push(chars[start..end].iter().collect::<String>().trim().to_owned());
        if end == chars.len() {
            break;
        }
        start = end.saturating_sub(overlap).max(start + 1);
    }
    out.retain(|c| !c.is_empty());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunks_cover_text() {
        let text = "woord ".repeat(500);
        let chunks = chunk(&text, 800, 100);
        assert!(chunks.len() >= 3);
        assert!(chunks.iter().all(|c| c.chars().count() <= 800));
    }
}
