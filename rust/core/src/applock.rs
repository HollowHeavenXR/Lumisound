//! App Lock state: enabled (persisted), locked/unlocked, one authentication
//! in flight at a time. The Face ID / passcode prompt itself is
//! LocalAuthentication in Swift; this decides when it runs and what the
//! result means.

use crate::store;
use std::sync::Mutex;

const DOC: &str = "app_lock";

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct Persisted {
    enabled: bool,
}

#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq, Eq)]
pub struct AppLockState {
    pub enabled: bool,
    pub unlocked: bool,
    pub authenticating: bool,
}

#[derive(uniffi::Object)]
pub struct AppLock {
    st: Mutex<AppLockState>,
}

#[uniffi::export]
impl AppLock {
    /// `legacy_enabled`: the UserDefaults-era flag, used only if the core
    /// has no saved state yet. Starts locked when enabled.
    #[uniffi::constructor]
    pub fn new(legacy_enabled: Option<bool>) -> std::sync::Arc<Self> {
        let enabled = if store::exists(DOC) {
            store::load::<Persisted>(DOC).enabled
        } else {
            let e = legacy_enabled.unwrap_or(false);
            store::save(DOC, &Persisted { enabled: e });
            e
        };
        std::sync::Arc::new(Self { st: Mutex::new(AppLockState { enabled, unlocked: !enabled, authenticating: false }) })
    }

    pub fn state(&self) -> AppLockState {
        *self.st.lock().unwrap()
    }

    /// Turning it on locks on the next `lock()`, not immediately; the
    /// current session stays unlocked only when turning it off.
    pub fn set_enabled(&self, enabled: bool) -> AppLockState {
        let mut s = self.st.lock().unwrap();
        s.enabled = enabled;
        s.unlocked = !enabled;
        store::save(DOC, &Persisted { enabled });
        *s
    }

    /// App went to the background (or the user asked): lock if enabled.
    pub fn lock(&self) -> AppLockState {
        let mut s = self.st.lock().unwrap();
        if s.enabled {
            s.unlocked = false;
        }
        *s
    }

    /// True when the caller should show the prompt now (enabled, locked,
    /// nothing already in flight); marks one as in flight.
    pub fn begin_authentication(&self) -> bool {
        let mut s = self.st.lock().unwrap();
        if !s.enabled || s.unlocked || s.authenticating {
            return false;
        }
        s.authenticating = true;
        true
    }

    /// `policy_available` false = the device has no passcode/biometrics at
    /// all, so the lock can't be enforced and opens.
    pub fn finish_authentication(&self, success: bool, policy_available: bool) -> AppLockState {
        let mut s = self.st.lock().unwrap();
        s.authenticating = false;
        if success || !policy_available {
            s.unlocked = true;
        }
        *s
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn flow() {
        let l = AppLock { st: Mutex::new(AppLockState { enabled: true, unlocked: false, authenticating: false }) };
        assert!(l.begin_authentication());
        assert!(!l.begin_authentication(), "one prompt at a time");
        assert!(!l.finish_authentication(false, true).unlocked);
        assert!(l.begin_authentication());
        assert!(l.finish_authentication(true, true).unlocked);
        assert!(!l.begin_authentication(), "already unlocked");
        assert!(!l.lock().unlocked);
        assert!(l.begin_authentication());
        assert!(l.finish_authentication(false, false).unlocked, "no passcode on device");
    }
}
