# rust/rpc — to do

Discord Rich Presence daemon (`lumisound-discord-rpc`). History: [`RUST-PORT.md`](../../RUST-PORT.md).

## Done (2026-11-11)
- Third card line (`large_text`) shows engine/format/BPM instead of repeating the title.
- YouTube art goes through the bridge's `/api/rp-art/yt/` copy so 16:9 frames aren't cropped to the middle.
- Start + end timestamps (ms): Discord draws the progress bar for the Listening card.
- Re-sends immediately on any text/art change or a seek (> 1.5 s jump); refresh every ~13.5 s otherwise.

## Open
- Done 2026-11-11: `rpc/v2.1.0` released (Linux, macOS, Windows binaries).
- Optional: Discord `status_display_type` / `details_url` once older clients stop rejecting unknown fields.
