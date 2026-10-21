//! Embeddings behind a small trait, so the model can be swapped without
//! touching the rest of the core.
//!
//! The default [`HashEmbedder`] needs no download and runs everywhere: it
//! hashes words, crude stems and character trigrams into a fixed-size vector.
//! It captures spelling and morphology, not meaning; a neural model such as
//! EmbeddingGemma (via ONNX) can implement [`Embedder`] for real semantics.

use crate::text::{is_stopword, stem, tokens};

pub trait Embedder: Send + Sync {
    /// Stable identifier, stored in the index; changing it triggers a re-index.
    fn id(&self) -> &str;
    fn dim(&self) -> usize;
    /// Returns an L2-normalised vector.
    fn embed(&self, text: &str) -> Vec<f32>;
}

pub struct HashEmbedder {
    dim: usize,
}

impl Default for HashEmbedder {
    fn default() -> Self {
        HashEmbedder { dim: 512 }
    }
}

fn fnv1a(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

impl HashEmbedder {
    fn add(&self, v: &mut [f32], feature: &str, weight: f32) {
        let h = fnv1a(feature.as_bytes());
        let idx = (h % self.dim as u64) as usize;
        let sign = if (h >> 63) == 0 { 1.0 } else { -1.0 };
        v[idx] += sign * weight;
    }
}

impl Embedder for HashEmbedder {
    fn id(&self) -> &str {
        "hash-512-v1"
    }

    fn dim(&self) -> usize {
        self.dim
    }

    fn embed(&self, text: &str) -> Vec<f32> {
        let mut v = vec![0.0f32; self.dim];
        for word in tokens(text).iter().filter(|w| !is_stopword(w)) {
            // Pure numbers say little about what a document is about.
            if word.chars().all(|c| c.is_ascii_digit()) {
                continue;
            }
            self.add(&mut v, &format!("w:{word}"), 1.0);
            if let Some(s) = stem(word) {
                self.add(&mut v, &format!("s:{s}"), 0.8);
            }
            let padded: Vec<char> = format!("#{word}#").chars().collect();
            for tri in padded.windows(3) {
                let t: String = tri.iter().collect();
                self.add(&mut v, &format!("t:{t}"), 0.25);
            }
        }
        normalize(&mut v);
        v
    }
}

pub fn normalize(v: &mut [f32]) {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 {
        v.iter_mut().for_each(|x| *x /= norm);
    }
}

/// Cosine similarity of two normalised vectors.
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return 0.0;
    }
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

pub fn to_blob(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|x| x.to_le_bytes()).collect()
}

pub fn from_blob(b: &[u8]) -> Vec<f32> {
    b.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect()
}

/// The embedder used by this build.
pub fn default_embedder() -> Box<dyn Embedder> {
    Box::new(HashEmbedder::default())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn related_words_are_closer_than_unrelated_ones() {
        let e = HashEmbedder::default();
        let a = e.embed("facturen");
        let b = e.embed("factuur nummer 12");
        let c = e.embed("strandvakantie zon");
        assert!(cosine(&a, &b) > cosine(&a, &c));
    }
}
