// SPDX-License-Identifier: Apache-2.0
//! The vector format of ADR 0003: half-precision blobs scored in process, and the sign bits
//! kept for the optional prefilter.

use half::f16;

/// 2 bytes per dimension, little-endian. A vector with a component beyond the half-precision
/// range is scaled down to fit first: the component would be stored as infinity and every
/// cosine with the row would come out NaN, and cosine does not depend on a vector's length.
pub fn to_half(v: &[f32]) -> Vec<u8> {
    let largest = v.iter().filter(|x| x.is_finite()).fold(0f32, |m, x| m.max(x.abs()));
    let scale = if largest > f16::MAX.to_f32() { 1.0 / largest } else { 1.0 };
    v.iter().flat_map(|x| f16::from_f32(*x * scale).to_le_bytes()).collect()
}

pub fn from_half(b: &[u8]) -> Vec<f32> {
    b.chunks_exact(2).map(|c| f16::from_le_bytes([c[0], c[1]]).to_f32()).collect()
}

/// One bit per dimension (set when the value is positive), in 64-bit little-endian words.
pub fn to_bits(v: &[f32]) -> Vec<u8> {
    let mut words = vec![0u64; v.len().div_ceil(64)];
    for (i, x) in v.iter().enumerate() {
        if *x > 0.0 {
            words[i / 64] |= 1 << (i % 64);
        }
    }
    words.iter().flat_map(|w| w.to_le_bytes()).collect()
}

/// Full-precision vectors of the embedding cache: what the embedder returned, unchanged.
pub fn to_f32_blob(v: &[f32]) -> Vec<u8> {
    v.iter().flat_map(|x| x.to_le_bytes()).collect()
}

pub fn from_f32_blob(b: &[u8]) -> Vec<f32> {
    b.chunks_exact(4).map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect()
}

/// A query vector prepared once for a scan.
pub struct Probe {
    unit: Vec<f32>,
    bits: Vec<u8>,
}

impl Probe {
    pub fn new(q: &[f32]) -> Probe {
        let norm = q.iter().map(|x| x * x).sum::<f32>().sqrt();
        // A zero vector is similar to nothing: every cosine comes out 0.
        let unit = if norm > 0.0 { q.iter().map(|x| x / norm).collect() } else { vec![0.0; q.len()] };
        Probe { unit, bits: to_bits(q) }
    }

    /// Cosine similarity with a stored half-precision vector, straight from its bytes.
    pub fn cosine(&self, blob: &[u8]) -> anyhow::Result<f32> {
        anyhow::ensure!(blob.len() == self.unit.len() * 2, "a stored vector has {} dimensions, the query {}", blob.len() / 2, self.unit.len());
        let (mut dot, mut norm) = (0f32, 0f32);
        for (x, c) in self.unit.iter().zip(blob.chunks_exact(2)) {
            let y = f16::from_le_bytes([c[0], c[1]]).to_f32();
            dot += x * y;
            norm += y * y;
        }
        Ok(if norm > 0.0 { dot / norm.sqrt() } else { 0.0 })
    }

    /// Hamming distance to stored sign bits (the prefilter's measure).
    pub fn hamming(&self, bits: &[u8]) -> u32 {
        if bits.len() != self.bits.len() {
            return u32::MAX;
        }
        self.bits.iter().zip(bits).map(|(a, b)| (a ^ b).count_ones()).sum()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn half_round_trip_and_cosine() {
        let v = vec![0.6f32, -0.8, 0.0, 0.0];
        let blob = to_half(&v);
        assert_eq!(blob.len(), 8);
        assert!(from_half(&blob).iter().zip(&v).all(|(a, b)| (a - b).abs() < 1e-3));
        let p = Probe::new(&[3.0, -4.0, 0.0, 0.0]);
        assert!((p.cosine(&blob).unwrap() - 1.0).abs() < 1e-3);
        assert!(p.cosine(&blob[..6]).is_err());
        assert_eq!(Probe::new(&[0.0; 4]).cosine(&blob).unwrap(), 0.0);
        // Components beyond the half-precision range: scaled to fit, the direction kept.
        let big = to_half(&[300_000.0, -400_000.0, 0.0, 0.0]);
        assert!(from_half(&big).iter().all(|x| x.is_finite()));
        assert!((p.cosine(&big).unwrap() - 1.0).abs() < 1e-3);
    }

    #[test]
    fn bits_are_signs() {
        let v: Vec<f32> = (0..70).map(|i| if i % 3 == 0 { 1.0 } else { -1.0 }).collect();
        let bits = to_bits(&v);
        assert_eq!(bits.len(), 16);
        assert_eq!(Probe::new(&v).hamming(&bits), 0);
        let flipped: Vec<f32> = v.iter().map(|x| -x).collect();
        assert_eq!(Probe::new(&flipped).hamming(&bits), 70);
    }
}
