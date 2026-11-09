//! Lumisound bridge: the server behind the iOS/tvOS/watchOS apps.
//!
//! Every route, background loop and engine the Python bridge had now lives
//! here; external tools (yt-dlp, ffmpeg, fpcalc, Demucs) run as child
//! processes. See RUST-PORT.md at the repo root.

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
mod lyricsgen;
mod probe;
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
    // Operator tools (run inside the container: `lumisound-bridge <tool> ...`).
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("radio-probe") {
        // radio-probe <user_id> <artist> <title> [source_track_id] [mode]
        let g = |i: usize| args.get(i).cloned().filter(|s| !s.is_empty());
        let seed = routes::radio::Seed { title: g(4), artist: g(3), source_track_id: g(5), ..Default::default() };
        let t = std::time::Instant::now();
        let (_, v) = routes::radio::start_session(&state, &g(2).unwrap_or_default(), seed, &g(6).unwrap_or_else(|| "balanced".into()), 10).await;
        println!("{}", serde_json::to_string_pretty(&v)?);
        eprintln!("radio-probe: {:.1}s", t.elapsed().as_secs_f64());
        return Ok(());
    }
    if args.get(1).map(String::as_str) == Some("lyrics-probe") {
        // lyrics-probe <audio> <title> <artist> [truth.lrc] [aligned|asr]
        // Runs Aria Lyrics; with a truth LRC prints timing error / coverage / WER.
        let g = |i: usize| args.get(i).cloned().unwrap_or_default();
        let truth = std::fs::read_to_string(g(5)).ok().map(|t| lyricsgen::parse_lrc(&t));
        let reference = (g(6) == "aligned").then(|| truth.as_ref().map(|t| t.iter().map(|l| l.text.clone()).collect::<Vec<_>>().join("\n"))).flatten();
        let t = std::time::Instant::now();
        let o = lyricsgen::generate(&state, std::path::Path::new(&g(2)), &g(3), &g(4), reference.as_deref(), |s| eprintln!("stage: {s}")).await.map_err(|e| anyhow::anyhow!(e))?;
        let secs = t.elapsed().as_secs_f64();
        for l in &o.lines {
            println!("[{:02}:{:05.2}] {}", (l.time / 60.0) as i64, l.time % 60.0, l.text);
        }
        let (med, cover, wer) = truth.as_ref().map(|t| lyricsgen::score(&o.lines, t)).unwrap_or((f64::NAN, f64::NAN, f64::NAN));
        println!("RESULT {}", serde_json::json!({"secs": secs, "lines": o.lines.len(), "instrumental": o.instrumental, "language": o.language, "aligned": o.aligned, "confidence": o.confidence, "mean_p": o.mean_p, "median_err": med, "coverage": cover, "wer": wer, "stages": o.stages}));
        return Ok(());
    }
    tokio::task::spawn_blocking(background::cleanup_orphan_temp_dirs);
    state.spawn_background();

    let app = routes::router(state.clone());
    let addr: SocketAddr = format!("{}:{}", state.cfg.host, state.cfg.port).parse()?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!("lumisound-bridge listening on {addr}");
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
