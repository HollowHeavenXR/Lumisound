#![allow(dead_code)]

//! Minimal CELT FFT primitives for decoder path.
//!
//! This module intentionally implements only the inverse transform behavior
//! needed by the decoder. It follows the libopus scaling convention where the
//! inverse FFT is unscaled and the forward path applies `1/N`.


/// Complex number used by CELT FFT/MDCT primitives.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Complex32 {
    /// Real component.
    pub re: f32,
    /// Imaginary component.
    pub im: f32,
}

impl Complex32 {
    /// Create a complex value from real and imaginary parts.
    ///
    /// Params: `re` is the real component, `im` is the imaginary component.
    /// Returns: a new `Complex32`.
    pub const fn new(re: f32, im: f32) -> Self {
        Self { re, im }
    }
}

/// FFT plan for the CELT decoder (unscaled inverse/forward, libopus
/// convention). Lumisound patch: the upstream crate computed these as naive
/// O(N^2) DFTs, which made Opus decoding barely faster than real time; this
/// uses rustfft's O(N log N) plans with identical results.
#[derive(Clone)]
pub(crate) struct KissFft {
    nfft: usize,
    inv: std::sync::Arc<dyn rustfft::Fft<f32>>,
    fwd: std::sync::Arc<dyn rustfft::Fft<f32>>,
}

impl core::fmt::Debug for KissFft {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("KissFft").field("nfft", &self.nfft).finish()
    }
}

fn planner() -> std::sync::MutexGuard<'static, rustfft::FftPlanner<f32>> {
    static P: std::sync::OnceLock<std::sync::Mutex<rustfft::FftPlanner<f32>>> = std::sync::OnceLock::new();
    P.get_or_init(|| std::sync::Mutex::new(rustfft::FftPlanner::new())).lock().unwrap()
}

fn run(plan: &dyn rustfft::Fft<f32>, input: &[Complex32], output: &mut [Complex32]) {
    let mut buf: Vec<rustfft::num_complex::Complex32> = input.iter().map(|c| rustfft::num_complex::Complex32::new(c.re, c.im)).collect();
    plan.process(&mut buf);
    for (o, b) in output.iter_mut().zip(&buf) {
        *o = Complex32::new(b.re, b.im);
    }
}

impl KissFft {
    /// Build a plan for `nfft` points.
    pub fn new(nfft: usize) -> Self {
        let mut p = planner();
        let inv = p.plan_fft_inverse(nfft);
        let fwd = p.plan_fft_forward(nfft);
        Self { nfft, inv, fwd }
    }

    /// Return FFT size configured in this plan.
    pub fn len(&self) -> usize {
        self.nfft
    }

    /// Unscaled inverse FFT: out[n] = sum_k in[k] e^{+2 pi i k n / N}.
    pub fn ifft(&self, input: &[Complex32], output: &mut [Complex32]) -> Result<(), &'static str> {
        if input.len() != self.nfft || output.len() != self.nfft {
            return Err("kiss_fft length mismatch");
        }
        run(&*self.inv, input, output);
        Ok(())
    }

    /// Unscaled forward FFT: out[k] = sum_n in[n] e^{-2 pi i k n / N}.
    pub fn fft(&self, input: &[Complex32], output: &mut [Complex32]) -> Result<(), &'static str> {
        if input.len() != self.nfft || output.len() != self.nfft {
            return Err("kiss_fft length mismatch");
        }
        run(&*self.fwd, input, output);
        Ok(())
    }
}

/// Forward DFT on flat interleaved complex buffers (`[re0, im0, re1, ...]`).
pub(crate) fn flat_fft_forward(input: &[f32], output: &mut [f32], n: usize) {
    assert!(input.len() >= 2 * n && output.len() >= 2 * n);
    let plan = planner().plan_fft_forward(n);
    let mut buf: Vec<rustfft::num_complex::Complex32> = (0..n).map(|j| rustfft::num_complex::Complex32::new(input[2 * j], input[2 * j + 1])).collect();
    plan.process(&mut buf);
    for (k, b) in buf.iter().enumerate() {
        output[2 * k] = b.re;
        output[2 * k + 1] = b.im;
    }
}

#[cfg(test)]
mod tests {
    use super::{Complex32, KissFft};
    use core::f32::consts::PI;

    /// Compute libopus-style forward DFT with `1/N` scaling for tests.
    ///
    /// Params: `input` is time-domain complex vector.
    /// Returns: scaled frequency-domain vector.
    fn forward_scaled(input: &[Complex32]) -> Vec<Complex32> {
        let n = input.len();
        let mut out = vec![Complex32::new(0.0, 0.0); n];
        for (k, yk) in out.iter_mut().enumerate() {
            let mut acc_re = 0.0f32;
            let mut acc_im = 0.0f32;
            for (n_idx, xn) in input.iter().enumerate() {
                let phase = -2.0 * PI * (k as f32) * (n_idx as f32) / (n as f32);
                let c = phase.cos();
                let s = phase.sin();
                acc_re += xn.re * c - xn.im * s;
                acc_im += xn.re * s + xn.im * c;
            }
            *yk = Complex32::new(acc_re / (n as f32), acc_im / (n as f32));
        }
        out
    }

    #[test]
    fn ifft_roundtrip_matches_input() {
        let n = 60usize;
        let fft = KissFft::new(n);
        let mut input = Vec::with_capacity(n);
        for i in 0..n {
            let t = i as f32 / n as f32;
            input.push(Complex32::new(
                (2.0 * PI * 3.0 * t).sin(),
                (2.0 * PI * 5.0 * t).cos(),
            ));
        }
        let freq = forward_scaled(&input);
        let mut recon = vec![Complex32::new(0.0, 0.0); n];
        fft.ifft(&freq, &mut recon).expect("ifft must succeed");
        for (a, b) in input.iter().zip(recon.iter()) {
            assert!(
                (a.re - b.re).abs() < 2e-5,
                "re mismatch: {} vs {}",
                a.re,
                b.re
            );
            assert!(
                (a.im - b.im).abs() < 2e-5,
                "im mismatch: {} vs {}",
                a.im,
                b.im
            );
        }
    }
}
