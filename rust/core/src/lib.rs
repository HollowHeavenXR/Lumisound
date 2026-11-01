//! Lumisound app core, shared by the iOS, tvOS and watchOS apps and the
//! widget. Exposed to Swift through UniFFI (module `LumisoundCore`): every
//! functional system lives here; Swift keeps SwiftUI views, the app shell and
//! the handful of Apple APIs only Swift can reach.

uniffi::setup_scaffolding!();

pub mod aidj;
pub mod analysis;
pub mod appearance;
pub mod client;
pub mod downloads;
pub mod duplicates;
pub mod engine;
pub mod library;
pub mod live;
pub mod lock;
pub mod lua;
pub mod metadata;
pub mod mood;
pub mod error;
pub mod retry;
pub mod smart;
pub mod store;
pub mod stores;

use std::future::Future;
use std::sync::LazyLock;

/// One runtime for networking and background work. Calls from Swift spawn
/// their future here and await the JoinHandle, so they work whichever
/// executor polls them.
pub(crate) static RT: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread().worker_threads(2).thread_name("lumisound-core").enable_all().build().expect("tokio runtime")
});

pub(crate) async fn on_rt<F, T>(f: F) -> T
where
    F: Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    RT.spawn(f).await.expect("core task panicked")
}

/// Core library version (Settings / diagnostics).
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}
