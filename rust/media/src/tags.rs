//! Tag writing/reading with lofty: standard fields plus Lumisound's own
//! source id and thumbnail, in every container the app keeps (MP4/M4A,
//! MP3, FLAC, Ogg Opus/Vorbis, WAV/AIFF via ID3).

use lofty::config::WriteOptions;
use lofty::file::{AudioFile, FileType, TaggedFileExt};
#[allow(unused_imports)]
use lofty::tag::TagExt as _;
use lofty::prelude::{Accessor, ItemKey};
use lofty::tag::{ItemValue, Tag, TagItem, TagType};
use std::path::Path;

pub const ID_KEY: &str = "LUMISOUND_ID";
pub const THUMB_KEY: &str = "LUMISOUND_THUMBNAIL";

#[derive(Default, Clone, Debug)]
pub struct Fields {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub genre: Option<String>,
    pub year: Option<String>,
    pub track: Option<u32>,
    pub source_id: Option<String>,
    pub thumbnail: Option<String>,
}

/// Container-specific key for a custom field.
fn custom_key(tt: TagType, name: &str) -> ItemKey {
    match tt {
        TagType::Mp4Ilst => ItemKey::Unknown(format!("----:com.apple.iTunes:{name}")),
        _ => ItemKey::Unknown(name.to_string()),
    }
}

fn nonempty(s: &Option<String>) -> Option<&str> {
    s.as_deref().map(str::trim).filter(|s| !s.is_empty())
}

pub fn write(path: &Path, f: &Fields) -> Result<(), String> {
    use lofty::tag::TagExt;
    let file = lofty::read_from_path(path).map_err(|e| e.to_string())?;
    let tt = file.primary_tag_type();
    let mut tag = file.tag(tt).cloned().unwrap_or_else(|| Tag::new(tt));
    if let Some(v) = nonempty(&f.title) {
        tag.set_title(v.to_string());
    }
    if let Some(v) = nonempty(&f.artist) {
        tag.set_artist(v.to_string());
    }
    if let Some(v) = nonempty(&f.album) {
        tag.set_album(v.to_string());
    }
    if let Some(v) = nonempty(&f.genre) {
        tag.set_genre(v.to_string());
    }
    if let Some(v) = nonempty(&f.year) {
        tag.insert_text(ItemKey::RecordingDate, v.to_string());
    }
    if let Some(n) = f.track.filter(|n| *n > 0) {
        tag.set_track(n);
    }
    let customs: Vec<(&str, &str)> = [(ID_KEY, nonempty(&f.source_id)), (THUMB_KEY, nonempty(&f.thumbnail))].into_iter().filter_map(|(k, v)| v.map(|v| (k, v))).collect();
    let opts = WriteOptions::default();
    match tt {
        TagType::Mp4Ilst => {
            use lofty::mp4::{Atom, AtomData, AtomIdent, Ilst};
            let mut ilst: Ilst = tag.into();
            for (k, v) in customs {
                ilst.replace_atom(Atom::new(AtomIdent::Freeform { mean: "com.apple.iTunes".into(), name: k.to_string().into() }, AtomData::UTF8(v.to_string())));
            }
            ilst.save_to_path(path, opts).map_err(|e| e.to_string())
        }
        TagType::Id3v2 => {
            use lofty::id3::v2::{ExtendedTextFrame, Frame, Id3v2Tag};
            let mut id3: Id3v2Tag = tag.into();
            for (k, v) in customs {
                id3.insert(Frame::UserText(ExtendedTextFrame::new(lofty::TextEncoding::UTF8, k.to_string(), v.to_string())));
            }
            id3.save_to_path(path, opts).map_err(|e| e.to_string())
        }
        TagType::VorbisComments => {
            use lofty::ogg::VorbisComments;
            let mut vc: VorbisComments = tag.into();
            for (k, v) in customs {
                vc.insert(k.to_string(), v.to_string());
            }
            vc.save_to_path(path, opts).map_err(|e| e.to_string())
        }
        _ => {
            for (k, v) in customs {
                let key = custom_key(tt, k);
                tag.remove_key(&key);
                tag.push(TagItem::new(key, ItemValue::Text(v.to_string())));
            }
            tag.save_to_path(path, opts).map_err(|e| e.to_string())
        }
    }
}

/// (source id, thumbnail URL) written by Lumisound, if present.
pub fn read_lumisound(path: &Path) -> (Option<String>, Option<String>) {
    let Ok(file) = lofty::read_from_path(path) else { return (None, None) };
    let mut out = (None, None);
    for tag in file.tags() {
        let tt = tag.tag_type();
        let get = |name: &str| {
            tag.get_string(&custom_key(tt, name)).map(str::to_string).or_else(|| {
                tag.items().find(|i| matches!(i.key(), ItemKey::Unknown(k) if k.eq_ignore_ascii_case(name) || k.to_uppercase().ends_with(&format!(":{name}")))).and_then(|i| i.value().text()).map(str::to_string)
            })
        };
        out.0 = out.0.or_else(|| get(ID_KEY));
        out.1 = out.1.or_else(|| get(THUMB_KEY));
    }
    out
}

pub fn can_tag(path: &Path) -> bool {
    matches!(lofty::probe::Probe::open(path).ok().and_then(|p| p.guess_file_type().ok()).and_then(|p| p.file_type()), Some(FileType::Mpeg | FileType::Mp4 | FileType::Flac | FileType::Opus | FileType::Vorbis | FileType::Wav | FileType::Aiff))
}

#[allow(dead_code)]
fn _assert_audiofile<T: AudioFile>() {}
