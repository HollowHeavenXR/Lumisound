//! Media primitives shared by the Lumisound bridge and app core.

pub mod analysis;
pub mod decode;
pub mod lock;

/// Audio file extensions the apps and server accept.
pub const AUDIO_EXTS: &[&str] = &["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "opus", "ogg", "caf", "mp4", "m4v", "webm", "mov"];
