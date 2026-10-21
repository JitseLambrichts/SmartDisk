//! Built-in categories: folders that fill themselves.
//!
//! A file only lands in a category when the keyword evidence is strong enough
//! *and* the rules agree (an invoice has an amount and a date). When in doubt
//! a file stays out: a missing file hurts less than a wrong one.

use crate::embed::{cosine, Embedder};
use crate::facts::Facts;
use crate::text::{contains_term, token_string};
use regex::Regex;
use serde::Serialize;
use std::sync::OnceLock;

#[derive(Debug, Clone, Copy, Serialize)]
pub struct Category {
    pub id: &'static str,
    /// Folder name on the drive.
    pub name: &'static str,
    /// SF Symbol shown by the app.
    pub symbol: &'static str,
    /// Hidden until the user explicitly enables sensitive categories.
    pub sensitive: bool,
    pub description: &'static str,
    #[serde(skip)]
    pub keywords: &'static [(&'static str, f32)],
    /// Words in a folder name that refer to this category.
    #[serde(skip)]
    pub aliases: &'static [&'static str],
}

pub const INVOICES: Category = Category {
    id: "invoices",
    name: "Invoices",
    symbol: "doc.text.fill",
    sensitive: false,
    description: "invoice factuur bill rekening amount due total vat btw payment betaling",
    keywords: &[
        ("factuur", 2.5), ("invoice", 2.5), ("rechnung", 2.5), ("facture", 2.5), ("factuurnummer", 1.5),
        ("invoice number", 1.5), ("btw", 1.0), ("vat", 1.0), ("tva", 1.0), ("totaal", 0.8), ("total", 0.8),
        ("te betalen", 1.2), ("amount due", 1.2), ("vervaldatum", 1.0), ("due date", 1.0), ("iban", 0.6),
        ("betaling", 0.6), ("payment", 0.6), ("bestelling", 0.5), ("order", 0.4), ("ontvangstbewijs", 1.5),
        ("receipt", 1.5), ("kassaticket", 1.5), ("creditnota", 1.5), ("subtotaal", 0.8), ("subtotal", 0.8),
    ],
    aliases: &["factuur", "facturen", "invoice", "invoices", "rekening", "rekeningen", "bills", "bill", "receipts", "bonnetjes"],
};

pub const CONTRACTS: Category = Category {
    id: "contracts",
    name: "Contracts",
    symbol: "signature",
    sensitive: false,
    description: "contract overeenkomst agreement parties partijen signed ondertekend terms clause artikel",
    keywords: &[
        ("overeenkomst", 2.5), ("contract", 2.5), ("agreement", 2.5), ("huurovereenkomst", 2.0),
        ("arbeidsovereenkomst", 2.0), ("partijen", 1.2), ("parties", 1.2), ("ondertekend", 1.0), ("signed", 1.0),
        ("handtekening", 1.0), ("signature", 1.0), ("opzegtermijn", 1.5), ("notice period", 1.5), ("artikel", 0.6),
        ("article", 0.5), ("clausule", 1.0), ("clause", 1.0), ("voorwaarden", 0.8), ("terms and conditions", 0.8),
        ("duur", 0.4), ("verhuurder", 0.8), ("huurder", 0.8), ("werkgever", 0.8), ("werknemer", 0.8),
    ],
    aliases: &["contract", "contracten", "contracts", "overeenkomst", "overeenkomsten", "agreements"],
};

pub const ID_DOCUMENTS: Category = Category {
    id: "id_documents",
    name: "ID Documents",
    symbol: "person.text.rectangle.fill",
    sensitive: true,
    description: "identity card identiteitskaart passport paspoort driving licence rijbewijs nationality date of birth",
    keywords: &[
        ("identiteitskaart", 3.0), ("identity card", 3.0), ("carte d'identite", 3.0), ("personalausweis", 3.0),
        ("paspoort", 3.0), ("passport", 3.0), ("rijbewijs", 3.0), ("driving licence", 3.0), ("driver's license", 3.0),
        ("nationaliteit", 1.2), ("nationality", 1.2), ("geboortedatum", 1.0), ("date of birth", 1.0),
        ("geboorteplaats", 1.0), ("place of birth", 1.0), ("rijksregisternummer", 1.5), ("verblijfsvergunning", 2.0),
        ("eid", 1.0), ("id kaart", 2.0),
    ],
    aliases: &["id", "id-documenten", "identiteitskaart", "paspoort", "passport", "identity", "documenten id"],
};

pub const SCREENSHOTS: Category = Category {
    id: "screenshots",
    name: "Screenshots",
    symbol: "camera.viewfinder",
    sensitive: false,
    description: "screenshot schermafbeelding screen capture",
    keywords: &[],
    aliases: &["screenshot", "screenshots", "schermafbeelding", "schermafbeeldingen", "schermopname", "schermopnames"],
};

pub const PHOTOS: Category = Category {
    id: "photos",
    name: "Photos",
    symbol: "photo.fill",
    sensitive: false,
    description: "photo foto picture camera image",
    keywords: &[],
    aliases: &["foto", "fotos", "foto's", "photo", "photos", "pictures", "afbeeldingen"],
};

pub const HOUSING: Category = Category {
    id: "housing",
    name: "Housing",
    symbol: "house.fill",
    sensitive: false,
    description: "huur rent kot studentenkamer appartement verhuurder landlord tenant waarborg deposit lease",
    keywords: &[
        ("huur", 1.5), ("huurprijs", 2.0), ("huurovereenkomst", 2.5), ("verhuurder", 2.0), ("huurder", 2.0),
        ("kot", 2.0), ("studentenkamer", 2.5), ("studentenhuis", 2.0), ("kamer", 0.6), ("appartement", 1.2),
        ("waarborg", 2.0), ("huurwaarborg", 2.5), ("plaatsbeschrijving", 2.5), ("rent", 1.5), ("landlord", 2.0),
        ("tenant", 2.0), ("lease", 1.5), ("security deposit", 2.0), ("syndic", 1.5), ("eigenaar", 0.6),
        ("energie", 0.5), ("water", 0.3), ("domicilie", 1.0),
    ],
    aliases: &["wonen", "housing", "kot", "huis", "home", "appartement", "huur"],
};

pub const ALL: &[Category] = &[INVOICES, CONTRACTS, ID_DOCUMENTS, SCREENSHOTS, PHOTOS, HOUSING];

pub fn by_id(id: &str) -> Option<&'static Category> {
    ALL.iter().find(|c| c.id == id)
}

pub fn by_name(name: &str) -> Option<&'static Category> {
    ALL.iter().find(|c| c.name.eq_ignore_ascii_case(name))
}

/// Categories visible with the current privacy setting.
pub fn visible(sensitive_enabled: bool) -> impl Iterator<Item = &'static Category> {
    ALL.iter().filter(move |c| sensitive_enabled || !c.sensitive)
}

/// What the classifier needs to know about a file.
pub struct Doc<'a> {
    pub file_name: &'a str,
    pub extension: &'a str,
    pub kind: &'a str,
    pub text: &'a str,
    pub facts: &'a Facts,
    pub embedding: &'a [f32],
}

#[derive(Debug, Clone, Serialize)]
pub struct Classification {
    pub category: &'static str,
    pub score: f32,
    pub included: bool,
    pub reasons: Vec<String>,
}

/// Saturating keyword score in [0, 1) plus the keywords that matched.
fn keyword_score(cat: &Category, tokens: &str) -> (f32, Vec<&'static str>) {
    let mut sum = 0.0;
    let mut hits = Vec::new();
    for (kw, w) in cat.keywords {
        if contains_term(tokens, kw) {
            sum += w;
            hits.push(*kw);
        }
    }
    (1.0 - (-sum / 3.0f32).exp(), hits)
}

pub fn is_screenshot_name(name: &str) -> bool {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)^(screenshot|screen shot|schermafbeelding|scherm­afbeelding|schermopname|cleanshot|capture d.écran|bildschirmfoto)")
            .unwrap()
    })
    .is_match(name)
}

const PHOTO_EXT: &[&str] = &["jpg", "jpeg", "heic", "heif", "dng", "raw", "cr2", "nef", "arw"];

pub fn classify(doc: &Doc, embedder: &dyn Embedder) -> Vec<Classification> {
    let tokens = token_string(&format!("{} {}", crate::text::file_name_words(doc.file_name), doc.text));
    let f = doc.facts;
    let mut out = Vec::new();

    for cat in ALL {
        let mut reasons = Vec::new();
        let (kw, hits) = keyword_score(cat, &tokens);
        if !hits.is_empty() {
            reasons.push(format!("keywords: {}", hits.join(", ")));
        }
        let sim = if doc.embedding.is_empty() { 0.0 } else { cosine(doc.embedding, &embedder.embed(cat.description)) };

        let (score, rule_ok) = match cat.id {
            "invoices" => {
                let amount = f.main_amount();
                if let Some(a) = amount {
                    reasons.push(format!("amount {:.2} {}{}", a.value, a.currency, if a.is_total { " (total)" } else { "" }));
                }
                if let Some(d) = f.doc_date {
                    reasons.push(format!("date {d}"));
                }
                let ids = !f.vat_numbers.is_empty() || !f.ibans.is_empty();
                if let Some(v) = f.vat_numbers.first() {
                    reasons.push(format!("VAT number {v}"));
                }
                let score = 0.6 * kw + 0.2 * sim.max(0.0) + if ids { 0.15 } else { 0.0 } + if amount.map_or(false, |a| a.is_total) { 0.1 } else { 0.0 };
                (score, amount.is_some() && f.doc_date.is_some() && !hits.is_empty())
            }
            "contracts" => (0.8 * kw + 0.2 * sim.max(0.0), doc.text.len() >= 300 && hits.len() >= 2),
            "id_documents" => {
                if f.mrz {
                    reasons.push("machine-readable zone (MRZ) found".into());
                }
                let strong = hits.iter().any(|h| cat.keywords.iter().any(|(k, w)| k == h && *w >= 3.0));
                let score = if f.mrz { 0.95 } else { 0.85 * kw + 0.15 * sim.max(0.0) };
                (score, f.mrz || (strong && hits.len() >= 2))
            }
            "screenshots" => {
                let yes = doc.kind == "image" && is_screenshot_name(doc.file_name);
                if yes {
                    reasons.push("file name says it is a screenshot".into());
                }
                (if yes { 1.0 } else { 0.0 }, yes)
            }
            "photos" => {
                let yes = PHOTO_EXT.contains(&doc.extension) && !is_screenshot_name(doc.file_name);
                if yes {
                    reasons.push(format!("camera image (.{})", doc.extension));
                }
                let little_text = doc.text.trim().chars().count() < 120;
                (if yes && little_text { 0.85 } else if yes { 0.5 } else { 0.0 }, yes)
            }
            "housing" => (0.85 * kw + 0.15 * sim.max(0.0), hits.len() >= 2),
            _ => (0.0, false),
        };
        if score < 0.15 {
            continue;
        }
        if sim > 0.05 {
            reasons.push(format!("similarity {sim:.2}"));
        }
        let threshold = match cat.id {
            "invoices" => 0.45,
            "contracts" => 0.5,
            "id_documents" => 0.6,
            "housing" => 0.55,
            _ => 0.5,
        };
        let included = rule_ok && score >= threshold;
        if !rule_ok && score >= threshold {
            reasons.push("rules not satisfied, kept out".into());
        }
        out.push(Classification { category: cat.id, score: score.min(1.0), included, reasons });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::embed::HashEmbedder;
    use chrono::NaiveDate;

    fn run(name: &str, ext: &str, kind: &str, text: &str) -> Vec<&'static str> {
        let e = HashEmbedder::default();
        let facts = crate::facts::extract(text, NaiveDate::from_ymd_opt(2026, 10, 21).unwrap());
        let emb = e.embed(text);
        let doc = Doc { file_name: name, extension: ext, kind, text, facts: &facts, embedding: &emb };
        classify(&doc, &e).into_iter().filter(|c| c.included).map(|c| c.category).collect()
    }

    #[test]
    fn rent_invoice_lands_in_invoices_and_housing() {
        let cats = run(
            "factuur-0423.pdf",
            "pdf",
            "pdf",
            "FACTUUR 0423\nFactuurdatum: 04/03/2026\nVerhuurder: Kotbaas BV\nHuur studentenkamer maart € 450,00\nTotaal te betalen: € 475,00\nBTW BE 0123.456.789\nIBAN BE68 5390 0754 7034",
        );
        assert!(cats.contains(&"invoices"), "{cats:?}");
        assert!(cats.contains(&"housing"), "{cats:?}");
        assert!(!cats.contains(&"id_documents"));
    }

    #[test]
    fn screenshots_by_name() {
        assert_eq!(run("Screenshot 2026-10-01 at 10.00.00.png", "png", "image", ""), vec!["screenshots"]);
    }

    #[test]
    fn plain_note_goes_nowhere() {
        assert!(run("boodschappen.txt", "txt", "text", "melk, brood, kaas en appels").is_empty());
    }
}
