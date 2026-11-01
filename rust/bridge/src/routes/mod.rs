use crate::perf;
use crate::proxy;
use crate::state::AppState;
use axum::Router;
use axum::middleware;
use tower_http::compression::CompressionLayer;
use tower_http::cors::{Any, CorsLayer};

mod account;
pub mod discovery;
mod health;
pub mod integrations;
pub mod library;
mod live;
mod music;
pub mod social;
pub mod media;

pub fn router(state: AppState) -> Router {
    Router::new()
        .merge(health::routes())
        .merge(account::routes())
        .merge(library::routes())
        .merge(discovery::routes())
        .merge(live::routes())
        .merge(music::routes())
        .merge(social::routes())
        .merge(integrations::routes())
        .merge(media::routes())
        .fallback(proxy::fallback)
        .layer(CompressionLayer::new().gzip(true).quality(tower_http::CompressionLevel::Precise(4)).compress_when(perf::Compressible))
        .layer(middleware::from_fn(perf::headers_and_timing))
        .layer(CorsLayer::new().allow_origin(Any).allow_methods(Any).allow_headers(Any))
        .with_state(state)
}
