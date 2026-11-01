//! LUMI_TAG_DIR=<dir with t.m4a t.mp3 t.flac t.opus> cargo test -p lumisound-media --test tags_write
#[test]
fn writes_and_reads_tags() {
    let Ok(dir) = std::env::var("LUMI_TAG_DIR") else { return };
    for ext in ["m4a", "mp3", "flac", "opus"] {
        let p = std::path::PathBuf::from(format!("{dir}/t.{ext}"));
        let f = lumisound_media::tags::Fields {
            title: Some("Song Ü".into()), artist: Some("Band".into()), album: Some("LP".into()), genre: Some("Rock".into()),
            year: Some("2024".into()), track: Some(3), source_id: Some("youtube:abc123".into()), thumbnail: Some("https://i.ytimg.com/x.jpg".into()),
        };
        assert!(lumisound_media::tags::can_tag(&p), "{ext}");
        lumisound_media::tags::write(&p, &f).unwrap_or_else(|e| panic!("{ext}: {e}"));
        let (id, th) = lumisound_media::tags::read_lumisound(&p);
        assert_eq!(id.as_deref(), Some("youtube:abc123"), "{ext}");
        assert_eq!(th.as_deref(), Some("https://i.ytimg.com/x.jpg"), "{ext}");
        println!("{ext}: ok");
    }
}
