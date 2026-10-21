//! Small, dependency-free text utilities shared by matching and embeddings.

/// Lowercases and strips the most common Latin diacritics so that
/// "Identiteitskaart", "identiteitskaart" and "café"/"cafe" compare equal.
pub fn fold(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        for lc in c.to_lowercase() {
            out.push(match lc {
                'á' | 'à' | 'â' | 'ä' | 'ã' | 'å' => 'a',
                'é' | 'è' | 'ê' | 'ë' => 'e',
                'í' | 'ì' | 'î' | 'ï' => 'i',
                'ó' | 'ò' | 'ô' | 'ö' | 'õ' => 'o',
                'ú' | 'ù' | 'û' | 'ü' => 'u',
                'ç' => 'c',
                'ñ' => 'n',
                'ß' => 's',
                // Typographic apostrophes, so "foto's" and "foto’s" match.
                '’' | '‘' => '\'',
                other => other,
            });
        }
    }
    out
}

/// Words that carry no meaning in folder names or documents (Dutch + English).
pub const STOPWORDS: &[&str] = &[
    "a", "about", "alle", "alles", "an", "and", "at", "de", "den", "der", "die", "dit", "een",
    "en", "erin", "for", "from", "het", "in", "is", "it", "me", "met", "mijn", "my", "of", "on",
    "op", "or", "the", "this", "that", "to", "van", "voor", "with", "all", "everything", "mn",
    "m'n", "uit", "bij", "te", "ik", "je", "we", "our", "ons", "onze", "these", "those", "deze",
];

pub fn is_stopword(w: &str) -> bool {
    STOPWORDS.contains(&w)
}

/// Splits folded text into alphanumeric tokens of at least two characters.
pub fn tokens(s: &str) -> Vec<String> {
    fold(s)
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| t.chars().count() >= 2)
        .map(str::to_owned)
        .collect()
}

/// A normalised " tok tok tok " string. Searching for `" factuur"` in it is a
/// cheap prefix-boundary match ("factuur" also matches "factuurnummer").
pub fn token_string(s: &str) -> String {
    let mut out = String::from(" ");
    for t in tokens(s) {
        out.push_str(&t);
        out.push(' ');
    }
    out
}

/// True if the folded phrase occurs at a word boundary in a [`token_string`].
pub fn contains_term(token_str: &str, term: &str) -> bool {
    let needle = token_string(term);
    let needle = needle.trim_end();
    !needle.trim().is_empty() && token_str.contains(needle)
}

/// Crude multilingual stem: the first five characters of a long word.
/// Good enough to tie "factuur"/"facturen" and "invoice"/"invoices" together.
pub fn stem(w: &str) -> Option<String> {
    let n = w.chars().count();
    (n >= 6).then(|| w.chars().take(5).collect())
}

/// Turns a file name into searchable words: "factuur_0423-kot.pdf" -> "factuur 0423 kot".
pub fn file_name_words(name: &str) -> String {
    let stem = name.rsplit_once('.').map(|(s, _)| s).unwrap_or(name);
    stem.replace(['_', '-', '.', '+'], " ")
}

/// Returns up to `radius` characters on both sides of the first hit of `term`.
pub fn snippet(text: &str, term: &str, radius: usize) -> Option<String> {
    let folded = fold(text);
    let needle = fold(term);
    let byte_pos = folded.find(&needle)?;
    // `fold` can change byte lengths, so work in characters.
    let char_pos = folded[..byte_pos].chars().count();
    let chars: Vec<char> = text.chars().collect();
    let start = char_pos.saturating_sub(radius);
    let end = (char_pos + needle.chars().count() + radius).min(chars.len());
    let mut s: String = chars[start..end].iter().collect();
    s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if start > 0 {
        s.insert(0, '…');
    }
    if end < chars.len() {
        s.push('…');
    }
    Some(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folds_and_matches_terms() {
        let ts = token_string("Factuurnummer: 0423 — Identiteitskaart van België");
        assert!(contains_term(&ts, "factuur"));
        assert!(contains_term(&ts, "belgie"));
        assert!(!contains_term(&ts, "uur"));
    }

    #[test]
    fn snippet_handles_unicode() {
        let s = snippet("Één zin over de opzegtermijn van drie maanden.", "opzegtermijn", 10).unwrap();
        assert!(s.contains("opzegtermijn"));
    }
}
