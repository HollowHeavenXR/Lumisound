# rust/media — to do

Shared media primitives (lock format, artwork, decode). History: [`RUST-PORT.md`](../../RUST-PORT.md).

## Done (2026-11-11)
- `artwork::presence_square`: Rich Presence art — trims letterbox bars, keeps wide (≥ 1.2:1) frames whole over a
  blurred, darkened fill; square art centre-cropped. `presence_needs_shaping` header-only check.

## Done (2026-11-13)
- Format coverage: `tests/format_matrix.rs` (every importable format, plain + locked, exact length and tones).
- `alac.rs`: ALAC in CAF (frma/alac atom-wrapped magic cookie unwrapped for symphonia).
- `gapless.rs`: AAC priming/padding from MP4 `iTunSMPB` or edit list; ADPCM WAV `fact` length; used by
  `decode.rs` and the engine deck (seek in music time, exact duration). Ogg Opus end trim in `opus.rs`.
- `aac.rs`: HE-AAC v1/v2, multichannel (folded to stereo by channel label), 960-sample and implicit-SBR AAC
  via `syom`; plain LC stays on symphonia. `tests/aac_profiles.rs`.
- MP1/MP2 and MKA enabled and importable.

## Open
- AC-3 / E-AC-3, WMA and WavPack have no decoder (not importable). Would need custom decoders.
- Raw ADTS `.aac` keeps its priming/padding (the format has no gapless metadata).
