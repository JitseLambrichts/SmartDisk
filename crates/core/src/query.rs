//! From folder name to query. "mkdir is a search query."
//!
//! The keyword parser always runs and owns every number (years, amounts).
//! When Apple Intelligence is available, its reading of the name may fill in
//! a category or a free-text topic the rules did not catch.

use crate::categories::{self, ALL};
use crate::facts::{month_from_name, parse_number};
use crate::helper::Helper;
use crate::text::{fold, is_stopword, tokens};
use chrono::{Datelike, Months, NaiveDate};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct ViewQuery {
    /// The folder name exactly as typed.
    pub raw: String,
    pub category: Option<String>,
    pub year: Option<i32>,
    /// Inclusive date range, from relative phrases like "this month".
    pub date_from: Option<NaiveDate>,
    pub date_to: Option<NaiveDate>,
    pub amount_min: Option<f64>,
    pub amount_max: Option<f64>,
    pub currency: Option<String>,
    /// File extensions, e.g. ["pdf"].
    pub extensions: Vec<String>,
    /// Must contain a verification code or source code.
    pub needs_code: bool,
    /// Whatever did not fit a field; searched by meaning and by words.
    pub free_text: Option<String>,
    /// Topic groups: a file matches a group when any of its terms appears.
    pub topics: Vec<Topic>,
    /// "rules" or "rules+apple-intelligence".
    pub parser: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Topic {
    pub word: String,
    pub terms: Vec<String>,
}

impl ViewQuery {
    pub fn is_empty(&self) -> bool {
        self.category.is_none()
            && self.year.is_none()
            && self.date_from.is_none()
            && self.amount_min.is_none()
            && self.amount_max.is_none()
            && self.extensions.is_empty()
            && !self.needs_code
            && self.topics.is_empty()
    }

    /// Human-readable chips, used by the app and `slim parse`.
    pub fn describe(&self) -> Vec<String> {
        let mut out = Vec::new();
        if let Some(c) = self.category.as_deref().and_then(categories::by_id) {
            out.push(format!("category: {}", c.name));
        }
        if let Some(y) = self.year {
            out.push(format!("year: {y}"));
        }
        if let (Some(f), Some(t)) = (self.date_from, self.date_to) {
            out.push(format!("between {f} and {t}"));
        }
        let cur = self.currency.as_deref().unwrap_or("EUR");
        if let Some(a) = self.amount_min {
            out.push(format!("amount > {a} {cur}"));
        }
        if let Some(a) = self.amount_max {
            out.push(format!("amount < {a} {cur}"));
        }
        for e in &self.extensions {
            out.push(format!("type: .{e}"));
        }
        if self.needs_code {
            out.push("contains a code".into());
        }
        for t in &self.topics {
            out.push(format!("about: {}", t.word));
        }
        out
    }
}

/// Small bilingual concept list so that everyday words find their documents.
/// A stand-in for real semantic search until a neural embedder is plugged in.
const CONCEPTS: &[(&[&str], &[&str])] = &[
    (&["kot", "studentenkamer", "kamer"], &["kot", "studentenkamer", "huur", "huurcontract", "huurovereenkomst", "verhuurder", "kotbaas", "waarborg", "plaatsbeschrijving", "rent", "landlord"]),
    (&["wonen", "huis", "home", "housing", "appartement"], &["huur", "huurovereenkomst", "verhuurder", "appartement", "waarborg", "plaatsbeschrijving", "syndic", "energie", "rent", "landlord", "lease"]),
    (&["school", "universiteit", "hogeschool", "university", "college", "studie", "study", "les", "lessen", "cursus"], &["school", "universiteit", "hogeschool", "university", "faculteit", "cursus", "course", "syllabus", "examen", "exam", "lessen", "lecture", "college", "opleiding", "studiepunten"]),
    (&["opzegtermijn", "opzeg", "opzeggen", "opzegging", "notice"], &["opzegtermijn", "opzeggingstermijn", "opzeg", "opzegging", "notice period", "termination", "beeindiging", "beëindiging", "opzeggen"]),
    (&["belastingen", "belasting", "taxes", "tax", "fiscaal", "aangifte"], &["belasting", "belastingen", "fiscale fiche", "fiscaal attest", "aanslagbiljet", "aangifte", "tax", "giftbewijs", "attest", "fod financien", "myminfin"]),
    (&["gezondheid", "medisch", "medical", "health", "dokter", "ziekenhuis"], &["dokter", "arts", "ziekenhuis", "ziekenfonds", "mutualiteit", "medisch", "voorschrift", "patient", "hospital", "doctor", "prescription"]),
    (&["werk", "job", "work", "loon", "salary"], &["loonbrief", "loonfiche", "salaris", "werkgever", "werknemer", "arbeidsovereenkomst", "payslip", "salary", "employer"]),
    (&["auto", "car", "wagen"], &["auto", "wagen", "voertuig", "inschrijvingsbewijs", "verzekering", "keuring", "vehicle", "car"]),
    (&["verzekering", "verzekeringen", "insurance"], &["verzekering", "polis", "verzekeraar", "premie", "insurance", "policy", "premium"]),
    (&["reis", "reizen", "travel", "vakantie", "holiday", "vlucht", "flight"], &["reis", "vlucht", "boarding", "hotel", "booking", "reservatie", "reservation", "flight", "ticket", "vakantie"]),
    (&["bank", "rekeninguittreksel", "statement"], &["bank", "rekeninguittreksel", "afschrift", "statement", "iban", "saldo", "balance"]),
];

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("valid regex"))
}

fn month_range(year: i32, month: u32) -> (NaiveDate, NaiveDate) {
    let from = NaiveDate::from_ymd_opt(year, month, 1).unwrap();
    let to = from.checked_add_months(Months::new(1)).unwrap().pred_opt().unwrap();
    (from, to)
}

/// Rule-based parse of a folder name, in Dutch or English.
pub fn parse_rules(name: &str, today: NaiveDate) -> ViewQuery {
    let mut q = ViewQuery { raw: name.to_owned(), parser: "rules".into(), ..Default::default() };
    // Work on a folded copy and blank out everything we consume.
    let mut s = format!(" {} ", fold(name).replace(['_', '/'], " "));

    let consume = |s: &mut String, m: regex::Match| {
        s.replace_range(m.range(), &" ".repeat(m.as_str().len()));
    };

    // Amounts: "boven 100 euro", "over €100", "meer dan 50", "under 20 eur".
    static MIN: OnceLock<Regex> = OnceLock::new();
    static MAX: OnceLock<Regex> = OnceLock::new();
    let cur = r"(€|eur|euro|euros|\$|usd|dollar|dollars)?";
    let min = re(&MIN, &format!(r"\b(boven|meer dan|groter dan|vanaf|over|above|more than|at least|minstens)\s*{cur}\s*(\d+(?:[.,]\d+)?)\s*{cur}"));
    let max = re(&MAX, &format!(r"\b(onder|minder dan|kleiner dan|tot|under|below|less than|at most|hoogstens)\s*{cur}\s*(\d+(?:[.,]\d+)?)\s*{cur}"));
    for (regex, is_min) in [(min, true), (max, false)] {
        if let Some(c) = regex.captures(&s.clone()) {
            let value = parse_number(&c[3]);
            let currency = c.get(2).or(c.get(4)).map(|m| m.as_str().to_owned());
            if is_min {
                q.amount_min = value;
            } else {
                q.amount_max = value;
            }
            if let Some(cur) = currency {
                q.currency = Some(if cur.contains('$') || cur.starts_with("usd") || cur.starts_with("dollar") { "USD" } else { "EUR" }.into());
            }
            consume(&mut s, c.get(0).unwrap());
        }
    }
    if (q.amount_min.is_some() || q.amount_max.is_some()) && q.currency.is_none() {
        q.currency = Some("EUR".into());
    }

    // Relative periods.
    let relative: &[(&str, &str)] = &[
        (r"\b(deze maand|this month)\b", "this_month"),
        (r"\b(vorige maand|last month|afgelopen maand)\b", "last_month"),
        (r"\b(dit jaar|this year)\b", "this_year"),
        (r"\b(vorig jaar|last year|afgelopen jaar)\b", "last_year"),
        (r"\b(deze week|this week)\b", "this_week"),
        (r"\b(vandaag|today)\b", "today"),
    ];
    for (pattern, kind) in relative {
        let regex = Regex::new(pattern).unwrap();
        if let Some(m) = regex.find(&s.clone()) {
            let (from, to) = match *kind {
                "this_month" => month_range(today.year(), today.month()),
                "last_month" => {
                    let d = today.checked_sub_months(Months::new(1)).unwrap();
                    month_range(d.year(), d.month())
                }
                "this_year" => (NaiveDate::from_ymd_opt(today.year(), 1, 1).unwrap(), NaiveDate::from_ymd_opt(today.year(), 12, 31).unwrap()),
                "last_year" => {
                    q.year = Some(today.year() - 1);
                    consume(&mut s, m);
                    continue;
                }
                "this_week" => (today - chrono::Duration::days(today.weekday().num_days_from_monday() as i64), today),
                _ => (today, today),
            };
            q.date_from = Some(from);
            q.date_to = Some(to);
            consume(&mut s, m);
        }
    }

    // "maart 2026", "march 2025".
    static MONTH_YEAR: OnceLock<Regex> = OnceLock::new();
    let my = re(&MONTH_YEAR, r"\b(januari|january|februari|february|maart|march|april|mei|may|juni|june|juli|july|augustus|august|september|oktober|october|november|december)\s+((?:19|20)\d{2})\b");
    if let Some(c) = my.captures(&s.clone()) {
        if let (Some(m), Ok(y)) = (month_from_name(&c[1]), c[2].parse::<i32>()) {
            let (from, to) = month_range(y, m);
            q.date_from = Some(from);
            q.date_to = Some(to);
            consume(&mut s, c.get(0).unwrap());
        }
    }

    // Years.
    static YEAR: OnceLock<Regex> = OnceLock::new();
    if let Some(m) = re(&YEAR, r"\b(?:19|20)\d{2}\b").find(&s.clone()) {
        q.year = m.as_str().parse().ok();
        consume(&mut s, m);
    }

    // Everything left is words.
    let mut leftovers = Vec::new();
    for word in tokens(&s) {
        let w = word.as_str();
        if q.category.is_none() {
            if let Some(cat) = ALL.iter().find(|c| c.aliases.iter().any(|a| fold(a) == w || fold(a).replace('\'', "") == w)) {
                q.category = Some(cat.id.to_owned());
                continue;
            }
        }
        match w {
            "pdf" | "pdfs" => q.extensions.push("pdf".into()),
            "png" | "jpg" | "jpeg" | "heic" | "docx" | "txt" | "csv" => q.extensions.push(w.into()),
            "word" if q.extensions.is_empty() => q.extensions.extend(["doc".into(), "docx".into()]),
            "code" | "codes" | "verificatiecode" | "otp" => q.needs_code = true,
            "over" | "about" | "omtrent" | "rond" | "erin" | "ermee" | "having" | "containing" | "bevat" | "staat" | "items" | "bestanden" | "files" | "documenten" | "documents" => {}
            _ if is_stopword(w) => {}
            _ => leftovers.push(word),
        }
    }
    for w in &leftovers {
        let terms = CONCEPTS
            .iter()
            .find(|(triggers, _)| triggers.iter().any(|t| fold(t) == *w))
            .map(|(_, terms)| terms.iter().map(|t| fold(t)).collect())
            .unwrap_or_else(|| vec![w.clone()]);
        q.topics.push(Topic { word: w.clone(), terms });
    }
    if !leftovers.is_empty() {
        q.free_text = Some(leftovers.join(" "));
    }
    q
}

/// Shape returned by `slim-helper parse-query`.
#[derive(Debug, Default, Deserialize)]
#[serde(default)]
struct ModelReading {
    category: Option<String>,
    free_text: Option<String>,
}

/// Full parse: rules first, Apple Intelligence second.
///
/// The model may only map a leftover word to a category the rules did not
/// recognise ("bonnetjes" → invoices). It never adds numbers or topics, and
/// never puts files in a sensitive category on its own.
pub fn parse(name: &str, today: NaiveDate, helper: Option<&Helper>) -> ViewQuery {
    let mut q = parse_rules(name, today);
    let Some(helper) = helper else { return q };
    // Only words the rules could not place are worth asking about.
    let unknown: Vec<String> = q.topics.iter().filter(|t| t.terms.len() == 1).map(|t| t.word.clone()).collect();
    if q.category.is_some() || unknown.is_empty() {
        return q;
    }
    let Ok(value) = helper.parse_query(name) else { return q };
    let Ok(m) = serde_json::from_value::<ModelReading>(value) else { return q };
    let Some(cat) = m.category.as_deref().and_then(categories::by_id).filter(|c| !c.sensitive) else { return q };
    // The model must point at one of the unknown words, e.g. by its free text leaving it out.
    let leftover: Vec<String> = m.free_text.as_deref().map(tokens).unwrap_or_default();
    let consumed: Vec<String> = unknown.iter().filter(|w| !leftover.contains(w)).cloned().collect();
    if consumed.is_empty() {
        return q;
    }
    q.category = Some(cat.id.to_owned());
    q.topics.retain(|t| !consumed.contains(&t.word));
    q.free_text = (!q.topics.is_empty()).then(|| q.topics.iter().map(|t| t.word.clone()).collect::<Vec<_>>().join(" "));
    q.parser = "rules+apple-intelligence".into();
    q
}

#[cfg(test)]
mod tests {
    use super::*;

    fn today() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 10, 21).unwrap()
    }

    #[test]
    fn invoices_over_amount() {
        let q = parse_rules("facturen 2026 boven 100 euro", today());
        assert_eq!(q.category.as_deref(), Some("invoices"));
        assert_eq!(q.year, Some(2026));
        assert_eq!(q.amount_min, Some(100.0));
        assert_eq!(q.currency.as_deref(), Some("EUR"));
        assert!(q.topics.is_empty());
    }

    #[test]
    fn english_variant() {
        let q = parse_rules("invoices 2026 over 100 euro", today());
        assert_eq!(q.category.as_deref(), Some("invoices"));
        assert_eq!(q.amount_min, Some(100.0));
    }

    #[test]
    fn contracts_with_notice_period() {
        let q = parse_rules("contracten met opzegtermijn", today());
        assert_eq!(q.category.as_deref(), Some("contracts"));
        assert_eq!(q.topics.len(), 1);
        assert!(q.topics[0].terms.contains(&"notice period".to_string()));
    }

    #[test]
    fn everything_about_my_kot() {
        let q = parse_rules("alles over mijn kot", today());
        assert_eq!(q.category.as_deref(), Some("housing"));
        assert!(q.amount_min.is_none());
        assert!(q.topics.is_empty(), "{:?}", q.topics);
    }

    #[test]
    fn screenshots_with_code() {
        let q = parse_rules("screenshots met een code erin", today());
        assert_eq!(q.category.as_deref(), Some("screenshots"));
        assert!(q.needs_code);
        assert!(q.topics.is_empty());
    }

    #[test]
    fn school_pdfs_this_month() {
        let q = parse_rules("pdf van school deze maand", today());
        assert_eq!(q.extensions, vec!["pdf"]);
        assert_eq!(q.date_from, NaiveDate::from_ymd_opt(2026, 10, 1));
        assert_eq!(q.date_to, NaiveDate::from_ymd_opt(2026, 10, 31));
        assert_eq!(q.topics[0].word, "school");
    }

    #[test]
    fn tax_folder() {
        let q = parse_rules("belastingen 2025", today());
        assert_eq!(q.year, Some(2025));
        assert_eq!(q.topics[0].word, "belastingen");
    }
}
