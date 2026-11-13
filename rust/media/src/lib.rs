//! Media primitives shared by the Lumisound bridge and app core.

pub mod aac;
pub mod alac;
pub mod analysis;
pub mod artwork;
pub mod decode;
pub mod gallery;
pub mod gapless;
pub mod lock;
pub mod opus;
pub mod tags;

/// Audio file extensions the apps and server accept.
pub const AUDIO_EXTS: &[&str] = &["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "opus", "ogg", "caf", "mp4", "m4v", "webm", "mov", "mka", "mp2", "mp1"];
