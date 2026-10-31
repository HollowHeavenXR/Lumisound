//! RFC 6238 TOTP (pyotp-compatible: base32 secret, SHA-1, 6 digits, 30 s).

use hmac::{Hmac, Mac};
use sha1::Sha1;

pub fn random_secret() -> String {
    // pyotp.random_base32(): 32 characters of the RFC 4648 alphabet.
    use rand::Rng;
    const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let mut r = rand::rng();
    (0..32).map(|_| A[r.random_range(0..32)] as char).collect()
}

fn code_at(key: &[u8], counter: u64) -> u32 {
    let mut mac = Hmac::<Sha1>::new_from_slice(key).expect("hmac key");
    mac.update(&counter.to_be_bytes());
    let h = mac.finalize().into_bytes();
    let off = (h[19] & 0x0f) as usize;
    let bin = ((h[off] as u32 & 0x7f) << 24) | ((h[off + 1] as u32) << 16) | ((h[off + 2] as u32) << 8) | h[off + 3] as u32;
    bin % 1_000_000
}

fn decode(secret: &str) -> Option<Vec<u8>> {
    let mut s: String = secret.trim().replace(' ', "").to_uppercase();
    while s.len() % 8 != 0 {
        s.push('=');
    }
    base32::decode(base32::Alphabet::Rfc4648 { padding: true }, &s)
}

/// `pyotp.TOTP(secret).verify(code, valid_window=1)`.
pub fn verify(secret: &str, code: &str) -> bool {
    let Some(key) = decode(secret) else { return false };
    let code = code.trim();
    if code.len() != 6 || !code.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    let want: u32 = code.parse().unwrap_or(u32::MAX);
    let step = chrono::Utc::now().timestamp().max(0) as u64 / 30;
    [step.saturating_sub(1), step, step + 1].iter().any(|c| code_at(&key, *c) == want)
}

pub fn provisioning_uri(secret: &str, name: &str, issuer: &str) -> String {
    let q = |s: &str| urlencoding::encode(s).replace("%2F", "/");
    format!("otpauth://totp/{}:{}?secret={}&issuer={}", q(issuer), q(name), secret, q(issuer))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rfc_vector() {
        // RFC 6238 SHA-1 secret "12345678901234567890", T=59 -> 94287082 (8 digits) -> 287082.
        assert_eq!(code_at(b"12345678901234567890", 59 / 30), 287082);
    }
}
