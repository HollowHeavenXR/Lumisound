//! Email normalization + deliverability (port of _normalize_email, which
//! used the email-validator package with check_deliverability=True).

use crate::error::AppError;
use hickory_resolver::TokioAsyncResolver;
use hickory_resolver::error::ResolveErrorKind;
use std::sync::OnceLock;

const DISPOSABLE: &[&str] = &[
    "mailinator.com", "guerrillamail.com", "guerrillamail.net", "sharklasers.com", "10minutemail.com", "10minutemail.net",
    "tempmail.com", "temp-mail.org", "throwawaymail.com", "yopmail.com", "yopmail.net", "dispostable.com", "trashmail.com",
    "trashmail.net", "getnada.com", "maildrop.cc", "mailnesia.com", "mintemail.com", "spamgourmet.com", "fakeinbox.com",
    "tempinbox.com", "mohmal.com", "emailondeck.com", "burnermail.io", "mailcatch.com", "inboxbear.com", "tempr.email",
    "discard.email", "grr.la", "spam4.me", "moakt.com", "harakirimail.com",
];
const MAX_LEN: usize = 254;

fn resolver() -> &'static TokioAsyncResolver {
    static R: OnceLock<TokioAsyncResolver> = OnceLock::new();
    R.get_or_init(|| {
        TokioAsyncResolver::tokio_from_system_conf().unwrap_or_else(|_| {
            TokioAsyncResolver::tokio(hickory_resolver::config::ResolverConfig::cloudflare(), Default::default())
        })
    })
}

fn local_ok(c: char) -> bool {
    c.is_alphanumeric() || "!#$%&'*+-/=?^_`{|}~.".contains(c) || (c as u32) > 127
}

/// Syntax check + normalization: domain lowercased (IDNA-validated), local part kept.
pub fn syntax(candidate: &str) -> Result<(String, String), String> {
    let Some((local, domain)) = candidate.split_once('@') else {
        return Err("The email address is not valid. It must have exactly one @-sign.".into());
    };
    let bad_domain: std::collections::BTreeSet<char> =
        domain.to_lowercase().chars().filter(|c| c.is_ascii() && !(c.is_ascii_alphanumeric() || *c == '.' || *c == '-')).collect();
    if !bad_domain.is_empty() {
        let list: Vec<String> = bad_domain.iter().map(|c| format!("'{c}'")).collect();
        return Err(format!("The part after the @-sign contains invalid characters: {}.", list.join(", ")));
    }
    if local.is_empty() {
        return Err("There must be something before the @-sign.".into());
    }
    if domain.is_empty() {
        return Err("There must be something after the @-sign.".into());
    }
    let bad: String = local.chars().filter(|c| !local_ok(*c)).collect();
    if !bad.is_empty() {
        return Err(format!("The email address contains invalid characters before the @-sign: {}.", bad));
    }
    if local.starts_with('.') {
        return Err("An email address cannot start with a period.".into());
    }
    if local.ends_with('.') {
        return Err("An email address cannot have a period immediately before the @-sign.".into());
    }
    if local.contains("..") {
        return Err("An email address cannot have two periods in a row.".into());
    }
    if local.len() > 64 {
        return Err(format!("The email address is too long before the @-sign ({} characters too many).", local.len() - 64));
    }
    let lower = domain.to_lowercase();
    if lower.ends_with('.') || lower.starts_with('.') || lower.contains("..") {
        return Err("An email address cannot have a period immediately after the @-sign.".into());
    }
    if !lower.contains('.') {
        return Err("The part after the @-sign is not valid. It should have a period.".into());
    }
    let ascii = idna::domain_to_ascii(&lower).map_err(|_| format!("The part after the @-sign contains invalid characters ({lower})."))?;
    if ascii.split('.').any(|l| l.is_empty() || l.len() > 63 || l.starts_with('-') || l.ends_with('-')) {
        return Err("The part after the @-sign is not valid.".into());
    }
    let tld = ascii.rsplit('.').next().unwrap_or("");
    if tld.chars().all(|c| c.is_ascii_digit()) {
        return Err("The part after the @-sign is not valid. It is not within a valid top-level domain.".into());
    }
    Ok((format!("{local}@{lower}"), ascii))
}

pub enum Deliverable {
    Yes,
    No,
    Unknown,
}

pub async fn deliverable(ascii_domain: &str) -> Deliverable {
    let r = resolver();
    let fqdn = format!("{ascii_domain}.");
    match tokio::time::timeout(std::time::Duration::from_secs(15), r.mx_lookup(fqdn.as_str())).await {
        Err(_) => Deliverable::Unknown,
        Ok(Ok(mx)) => {
            let hosts: Vec<String> = mx.iter().map(|m| m.exchange().to_utf8()).collect();
            if !hosts.is_empty() && hosts.iter().all(|h| h == "." || h.is_empty()) { Deliverable::No } else { Deliverable::Yes }
        }
        Ok(Err(e)) => match e.kind() {
            ResolveErrorKind::NoRecordsFound { response_code, .. } => {
                if *response_code == hickory_resolver::proto::op::ResponseCode::NXDomain {
                    return Deliverable::No;
                }
                // No MX: an A/AAAA record makes the domain itself the mail host.
                match tokio::time::timeout(std::time::Duration::from_secs(15), r.lookup_ip(fqdn.as_str())).await {
                    Ok(Ok(ips)) if ips.iter().next().is_some() => Deliverable::Yes,
                    Ok(Err(e2)) if matches!(e2.kind(), ResolveErrorKind::NoRecordsFound { .. }) => Deliverable::No,
                    Ok(Ok(_)) => Deliverable::No,
                    _ => Deliverable::Unknown,
                }
            }
            _ => Deliverable::Unknown,
        },
    }
}

/// `_normalize_email(raw, field=...)`.
pub async fn normalize(raw: Option<&str>, field: &str) -> Result<String, AppError> {
    let candidate = raw.map(str::trim).filter(|s| !s.is_empty()).ok_or_else(|| AppError::bad_request(format!("{field} is required")))?;
    if candidate.chars().any(char::is_whitespace) {
        return Err(AppError::bad_request(format!("{field} must not contain spaces")));
    }
    if candidate.chars().count() > MAX_LEN {
        return Err(AppError::bad_request(format!("{field} must be at most {MAX_LEN} characters")));
    }
    let (normalized, ascii) = syntax(candidate).map_err(AppError::bad_request)?;
    match deliverable(&ascii).await {
        Deliverable::No => return Err(AppError::bad_request("That email domain can't receive mail. Please check it for typos.")),
        Deliverable::Unknown => tracing::warn!("email validation: deliverability check inconclusive for {candidate:?} — allowing"),
        Deliverable::Yes => {}
    }
    let domain = normalized.rsplit('@').next().unwrap_or("").to_lowercase();
    if DISPOSABLE.contains(&domain.as_str()) {
        return Err(AppError::bad_request("Disposable email addresses aren't accepted. Please use a permanent address."));
    }
    if normalized.chars().count() > MAX_LEN {
        return Err(AppError::bad_request(format!("{field} must be at most {MAX_LEN} characters")));
    }
    Ok(normalized)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn syntax_rules() {
        assert_eq!(syntax("Bob@Example.COM").unwrap().0, "Bob@example.com");
        assert!(syntax("a@b").is_err());
        assert!(syntax("a@@b.com").is_err());
        assert!(syntax(".a@b.com").is_err());
        assert!(syntax("a..b@c.com").is_err());
    }
}
