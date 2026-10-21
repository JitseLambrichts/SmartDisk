//! Hard facts — dates, amounts, VAT numbers — come from code, never from a model.
//! "The model explains, the code counts."

use crate::text::fold;
use chrono::{Datelike, NaiveDate};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Amount {
    pub value: f64,
    pub currency: String,
    /// True when the amount sits next to a word like "total" or "te betalen".
    pub is_total: bool,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Facts {
    pub amounts: Vec<Amount>,
    pub dates: Vec<NaiveDate>,
    /// The date that best describes the document (invoice date, signing date…).
    pub doc_date: Option<NaiveDate>,
    pub vat_numbers: Vec<String>,
    pub ibans: Vec<String>,
    pub emails: Vec<String>,
    /// Machine-readable zone of a passport or identity card.
    pub mrz: bool,
    /// A verification code or source code appears in the text.
    pub has_code: bool,
}

impl Facts {
    /// The amount a person would call "the amount" of this document.
    pub fn main_amount(&self) -> Option<&Amount> {
        self.amounts
            .iter()
            .filter(|a| a.is_total)
            .max_by(|a, b| a.value.total_cmp(&b.value))
            .or_else(|| self.amounts.iter().max_by(|a, b| a.value.total_cmp(&b.value)))
    }
}

fn re(cell: &'static OnceLock<Regex>, pattern: &str) -> &'static Regex {
    cell.get_or_init(|| Regex::new(pattern).expect("valid regex"))
}

const NUMBER: &str = r"(\d{1,3}(?:[.  ]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)";
const MONTHS: &str = r"(jan(?:uari|uary)?|feb(?:ruari|ruary)?|maart|mrt|mar(?:ch)?|apr(?:il)?|mei|may|jun[ie]?|jul[iy]?|aug(?:ustus|ust)?|sep(?:t(?:ember)?)?|okt(?:ober)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)";

pub fn extract(text: &str, today: NaiveDate) -> Facts {
    let mut f = Facts {
        amounts: amounts(text),
        ..Default::default()
    };
    let (dates, doc_date) = dates(text, today);
    f.dates = dates;
    f.doc_date = doc_date;

    static VAT: OnceLock<Regex> = OnceLock::new();
    let vat = re(&VAT, r"\b(BE\s?0?\d{3}[.\s]?\d{3}[.\s]?\d{3}|NL\d{9}B\d{2}|DE\d{9}|FR[A-Z0-9]{2}\d{9}|LU\d{8})\b");
    f.vat_numbers = dedup(vat.find_iter(text).map(|m| m.as_str().replace([' ', '.'], "")));

    static IBAN: OnceLock<Regex> = OnceLock::new();
    let iban = re(&IBAN, r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?\b");
    f.ibans = dedup(iban.find_iter(text).map(|m| m.as_str().replace(' ', "")));

    static EMAIL: OnceLock<Regex> = OnceLock::new();
    let email = re(&EMAIL, r"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b");
    f.emails = dedup(email.find_iter(text).map(|m| m.as_str().to_lowercase()));

    static MRZ: OnceLock<Regex> = OnceLock::new();
    f.mrz = re(&MRZ, r"[A-Z0-9<]{5,}<<[A-Z0-9<]{8,}").is_match(text);

    static VCODE: OnceLock<Regex> = OnceLock::new();
    let vcode = re(&VCODE, r"(?i)(code|otp|verificatie|verification|pin|token|wachtwoord)\D{0,25}\b\d{4,8}\b");
    f.has_code = vcode.is_match(text) || looks_like_source_code(text);
    f
}

fn dedup(it: impl Iterator<Item = String>) -> Vec<String> {
    let mut v: Vec<String> = Vec::new();
    for s in it {
        if !v.contains(&s) {
            v.push(s);
        }
    }
    v
}

fn looks_like_source_code(text: &str) -> bool {
    if text.len() < 40 {
        return false;
    }
    let symbols = text.chars().filter(|c| "{}();=<>[]".contains(*c)).count();
    let keywords = ["fn ", "def ", "let ", "const ", "import ", "class ", "return ", "function", "=>", "#include", "public "]
        .iter()
        .filter(|k| text.contains(*k))
        .count();
    keywords >= 2 && symbols * 100 / text.chars().count().max(1) >= 2
}

/// Parses "1.234,56", "1,234.56", "1 234,56", "120" and "99,5" into a number.
pub fn parse_number(raw: &str) -> Option<f64> {
    let s: String = raw.chars().filter(|c| !c.is_whitespace() && *c != ' ').collect();
    let last_dot = s.rfind('.');
    let last_comma = s.rfind(',');
    let normalised = match (last_dot, last_comma) {
        (Some(d), Some(c)) if c > d => s.replace('.', "").replace(',', "."),
        (Some(_), Some(_)) => s.replace(',', ""),
        (None, Some(c)) => {
            if s.len() - c - 1 <= 2 {
                s.replace(',', ".")
            } else {
                s.replace(',', "")
            }
        }
        (Some(d), None) => {
            // European documents: "1.234" means one thousand two hundred thirty-four.
            if s.len() - d - 1 == 3 {
                s.replace('.', "")
            } else {
                s
            }
        }
        (None, None) => s,
    };
    normalised.parse().ok()
}

fn currency_code(sym: &str) -> String {
    match fold(sym).trim() {
        "€" | "eur" | "euro" | "euros" => "EUR",
        "$" | "usd" => "USD",
        "£" | "gbp" => "GBP",
        _ => "EUR",
    }
    .to_owned()
}

const TOTAL_WORDS: &[&str] = &[
    "totaal", "total", "te betalen", "amount due", "balance due", "a payer", "gesamt", "bedrag", "som", "subtotal",
];

pub fn amounts(text: &str) -> Vec<Amount> {
    static PRE: OnceLock<Regex> = OnceLock::new();
    static POST: OnceLock<Regex> = OnceLock::new();
    let pre = re(&PRE, &format!(r"(?i)(€|\beur\b|\beuro\b|\$|\busd\b|£|\bgbp\b)\s?{NUMBER}"));
    let post = re(&POST, &format!(r"(?i){NUMBER}\s?(€|eur\b|euros?\b|usd\b|\$|£)"));

    let mut out: Vec<(usize, Amount)> = Vec::new();
    let mut push = |start: usize, num: &str, cur: &str| {
        let Some(value) = parse_number(num) else { return };
        if value <= 0.0 || value > 10_000_000.0 || out.iter().any(|(s, _)| s.abs_diff(start) < 3) {
            return;
        }
        let before_start = text[..start].char_indices().rev().nth(48).map(|(i, _)| i).unwrap_or(0);
        let context = fold(&text[before_start..start]);
        let is_total = TOTAL_WORDS.iter().any(|w| context.contains(w));
        out.push((start, Amount { value, currency: currency_code(cur), is_total }));
    };
    for c in pre.captures_iter(text) {
        push(c.get(0).unwrap().start(), &c[2], &c[1]);
    }
    for c in post.captures_iter(text) {
        push(c.get(0).unwrap().start(), &c[1], &c[2]);
    }
    out.sort_by_key(|(s, _)| *s);
    out.into_iter().map(|(_, a)| a).collect()
}

pub fn month_from_name(name: &str) -> Option<u32> {
    let n = fold(name);
    let n = n.trim_end_matches('.');
    let m = match n.get(..3)? {
        "jan" => 1,
        "feb" => 2,
        "maa" | "mrt" | "mar" => 3,
        "apr" => 4,
        "mei" | "may" => 5,
        "jun" => 6,
        "jul" => 7,
        "aug" => 8,
        "sep" => 9,
        "okt" | "oct" => 10,
        "nov" => 11,
        "dec" => 12,
        _ => return None,
    };
    Some(m)
}

const DATE_WORDS: &[&str] = &["factuurdatum", "invoice date", "datum", "date", "dated", "gedateerd", "ondertekend", "signed"];

/// All plausible dates in the text, plus the one that best describes the document.
pub fn dates(text: &str, today: NaiveDate) -> (Vec<NaiveDate>, Option<NaiveDate>) {
    static NUMERIC: OnceLock<Regex> = OnceLock::new();
    static ISO: OnceLock<Regex> = OnceLock::new();
    static DMY: OnceLock<Regex> = OnceLock::new();
    static MDY: OnceLock<Regex> = OnceLock::new();
    let numeric = re(&NUMERIC, r"\b(\d{1,2})[./-](\d{1,2})[./-](\d{4})\b");
    let iso = re(&ISO, r"\b(\d{4})-(\d{2})-(\d{2})\b");
    let dmy = re(&DMY, &format!(r"(?i)\b(\d{{1,2}})\s+{MONTHS}\.?\s+(\d{{4}})\b"));
    let mdy = re(&MDY, &format!(r"(?i)\b{MONTHS}\.?\s+(\d{{1,2}}),?\s+(\d{{4}})\b"));

    let max_year = today.year() + 3;
    let plausible = |d: NaiveDate| (1990..=max_year).contains(&d.year());
    let mut found: Vec<(usize, NaiveDate)> = Vec::new();
    let mut add = |pos: usize, y: i32, m: u32, d: u32| {
        if let Some(date) = NaiveDate::from_ymd_opt(y, m, d).filter(|d| plausible(*d)) {
            found.push((pos, date));
        }
    };
    for c in numeric.captures_iter(text) {
        let (d, m, y) = (c[1].parse().unwrap_or(0), c[2].parse().unwrap_or(0), c[3].parse().unwrap_or(0));
        add(c.get(0).unwrap().start(), y, m, d);
    }
    for c in iso.captures_iter(text) {
        add(c.get(0).unwrap().start(), c[1].parse().unwrap_or(0), c[2].parse().unwrap_or(0), c[3].parse().unwrap_or(0));
    }
    for c in dmy.captures_iter(text) {
        if let Some(m) = month_from_name(&c[2]) {
            add(c.get(0).unwrap().start(), c[3].parse().unwrap_or(0), m, c[1].parse().unwrap_or(0));
        }
    }
    for c in mdy.captures_iter(text) {
        if let Some(m) = month_from_name(&c[1]) {
            add(c.get(0).unwrap().start(), c[3].parse().unwrap_or(0), m, c[2].parse().unwrap_or(0));
        }
    }
    found.sort_by_key(|(p, _)| *p);

    let labelled = found.iter().find(|(pos, _)| {
        let start = text[..*pos].char_indices().rev().nth(30).map(|(i, _)| i).unwrap_or(0);
        let ctx = fold(&text[start..*pos]);
        DATE_WORDS.iter().any(|w| ctx.contains(w))
    });
    let doc_date = labelled.or(found.first()).map(|(_, d)| *d);

    let mut all: Vec<NaiveDate> = found.into_iter().map(|(_, d)| d).collect();
    all.sort();
    all.dedup();
    (all, doc_date)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn today() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 10, 21).unwrap()
    }

    #[test]
    fn parses_european_and_us_numbers() {
        assert_eq!(parse_number("1.234,56"), Some(1234.56));
        assert_eq!(parse_number("1,234.56"), Some(1234.56));
        assert_eq!(parse_number("99,5"), Some(99.5));
        assert_eq!(parse_number("1.250"), Some(1250.0));
        assert_eq!(parse_number("120"), Some(120.0));
    }

    #[test]
    fn finds_total_amount_and_invoice_date() {
        let t = "Factuur 0423\nFactuurdatum: 04/03/2026\nHuur maart € 450,00\nKosten 25,00 EUR\nTotaal te betalen: € 475,00\nBTW BE 0123.456.789";
        let f = extract(t, today());
        assert_eq!(f.main_amount().unwrap().value, 475.0);
        assert_eq!(f.doc_date, NaiveDate::from_ymd_opt(2026, 3, 4));
        assert_eq!(f.vat_numbers, vec!["BE0123456789"]);
    }

    #[test]
    fn finds_textual_dates_and_codes() {
        let f = extract("Signed on 12 maart 2025. Your verification code is 482913.", today());
        assert_eq!(f.doc_date, NaiveDate::from_ymd_opt(2025, 3, 12));
        assert!(f.has_code);
    }

    #[test]
    fn detects_mrz() {
        let f = extract("IDBEL5912345674<<<<<<<<<<<<<<<\n8501012M3001017BEL<<<<<<<<<<<0", today());
        assert!(f.mrz);
    }
}
