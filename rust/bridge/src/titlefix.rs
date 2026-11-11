//! One-time repair of cloud titles cut at a dash.
//!
//! Until 2026-11-11 the app's tag fallback split any title that equalled
//! the filename at its first " - " and kept only the right part, even when
//! the artist was known from the tags ("What if AI made a Gogeta Song?
//! (Dragon Ball - 2026)" became "2026)"). Those titles were uploaded into
//! `ios_user_music_metadata`. This puts back each file's own title tag,
//! only for rows that show that exact cut (stored title = the part after
//! the first dash of the filename) and only when the tag is longer.
//!
//!   lumisound-bridge repair-titles          dry run, prints what would change
//!   lumisound-bridge repair-titles apply    writes the fixes

use crate::state::AppState;
use std::path::PathBuf;

pub async fn repair(st: &AppState, apply: bool) -> anyhow::Result<()> {
    let Some(root) = st.cfg.user_music_dir.clone() else {
        anyhow::bail!("USER_MUSIC_DIR is not set");
    };
    let rows: Vec<(String, String, String, Option<String>, Option<String>)> = sqlx::query_as(
        "SELECT id, user_id, coalesce(relative_path, filename), title, original_filename FROM ios_user_music_metadata \
         WHERE original_filename LIKE '% - %' AND title IS NOT NULL",
    )
    .fetch_all(&st.db)
    .await?;
    let (mut checked, mut fixed, mut skipped) = (0, 0, 0);
    for (id, user, rel, title, orig) in rows {
        let (Some(title), Some(orig)) = (title, orig) else { continue };
        let stem = lumisound_media::lock::display_stem(&orig);
        let Some((_, right)) = stem.split_once(" - ") else { continue };
        // Only the cut pattern: stored title is exactly the text after the first dash.
        if right.trim() != title.trim() || stem.trim() == title.trim() {
            continue;
        }
        checked += 1;
        let path = PathBuf::from(&root).join(&user).join(&rel);
        let tag_title = tokio::task::spawn_blocking(move || read_title(&path)).await.ok().flatten();
        match tag_title {
            Some(t) if t.chars().count() > title.chars().count() && t != title => {
                println!("{id:.12} {:?} -> {:?}", title, t);
                if apply {
                    sqlx::query("UPDATE ios_user_music_metadata SET title = $1 WHERE id = $2 AND user_id = $3").bind(&t).bind(&id).bind(&user).execute(&st.db).await?;
                }
                fixed += 1;
            }
            _ => skipped += 1,
        }
    }
    println!("{} rows with the cut pattern, {fixed} {}, {skipped} left (tag missing or not longer)", checked, if apply { "fixed" } else { "would be fixed" });
    Ok(())
}

/// Title tag of a stored file (`.lms` unlocked into a temp copy first).
fn read_title(path: &std::path::Path) -> Option<String> {
    if !path.exists() {
        return None;
    }
    let name = path.file_name()?.to_string_lossy().to_string();
    if lumisound_media::lock::is_locked(path) {
        let ext = lumisound_media::lock::inner_ext(&name).unwrap_or_else(|| "bin".into());
        let tmp = std::env::temp_dir().join(format!("titlefix-{}.{ext}", uuid::Uuid::new_v4().simple()));
        lumisound_media::lock::unlock_file(path, &tmp).ok()?;
        let t = lumisound_media::tags::read_info(&tmp).and_then(|i| i.title);
        let _ = std::fs::remove_file(&tmp);
        t
    } else {
        lumisound_media::tags::read_info(path).and_then(|i| i.title)
    }
}
