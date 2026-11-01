//! Lumisound bridge: the server behind the iOS/tvOS/watchOS apps.
//!
//! Routes that are not ported yet fall through to the legacy Python bridge
//! (`LEGACY_URL`) via `proxy`, so the Rust server can take over port 8002 while
//! the port is still in progress. See RUST-PORT.md at the repo root.

#![allow(dead_code)] // helpers land ahead of the routes that use them during the port

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod analysis;
mod auth;
mod background;
mod cache;
mod config;
mod db;
mod email;
mod error;
mod gemini;
mod extract;
mod files;
mod lock;
mod notify;
mod perf;
mod probe;
mod proxy;
mod push;
mod routes;
mod state;
mod storage;
mod taste;
mod totp;
mod youtube;
mod ytdlp;

use std::net::SocketAddr;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .with_target(false)
        .init();

    let cfg = config::Config::from_env();
    let state = state::AppState::new(cfg).await?;
    tokio::task::spawn_blocking(background::cleanup_orphan_temp_dirs);
    state.spawn_background();

    let app = routes::router(state.clone());
    let addr: SocketAddr = format!("{}:{}", state.cfg.host, state.cfg.port).parse()?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("lumisound-bridge listening on {addr} (legacy: {:?})", state.cfg.legacy_url);
    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

async fn shutdown_signal() {
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("SIGTERM handler");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {},
        _ = term.recv() => {},
    }
}
