//! Errors surfaced to Swift.

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    /// Non-2xx from the bridge: status + FastAPI `detail` (or a generic message).
    #[error("{message}")]
    Http { status: u16, message: String },
    /// 401: the session is gone; the app signs out.
    #[error("Session expired. Please sign in again.")]
    Unauthorized,
    /// Transport failure (offline, DNS, TLS, timeout).
    #[error("{message}")]
    Network { message: String, timed_out: bool, cancelled: bool },
    #[error("{message}")]
    Invalid { message: String },
    #[error("{message}")]
    Io { message: String },
}

impl CoreError {
    pub fn invalid(m: impl Into<String>) -> Self {
        CoreError::Invalid { message: m.into() }
    }

    pub fn status(&self) -> u16 {
        match self {
            CoreError::Http { status, .. } => *status,
            CoreError::Unauthorized => 401,
            _ => 0,
        }
    }
}

impl From<reqwest::Error> for CoreError {
    fn from(e: reqwest::Error) -> Self {
        CoreError::Network { message: e.to_string(), timed_out: e.is_timeout(), cancelled: false }
    }
}

impl From<std::io::Error> for CoreError {
    fn from(e: std::io::Error) -> Self {
        CoreError::Io { message: e.to_string() }
    }
}

pub type CoreResult<T> = Result<T, CoreError>;
