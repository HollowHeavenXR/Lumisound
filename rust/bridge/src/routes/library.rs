//! Library core (route group 3): playlists, favorites, settings, sync +
//! backups, folder backups, queue, playback state, history, sharing.

use crate::auth::User;
use crate::error::{ApiResult, AppError};
use crate::extract::{J, Q, check_range};
use crate::proxy;
use crate::state::AppState;
use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, put};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{Map, Value, json};
use sqlx::{Postgres, Transaction};

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/user/playlists", get(list_playlists).post(create_playlist))
        .route("/user/playlists/folders", get(playlist_folders))
        .route("/user/playlists/share", post(share_playlist))
        .route("/user/playlists/share/{token}", delete(revoke_share))
        .route("/user/playlists/{id}", get(get_playlist).put(update_playlist).delete(delete_playlist))
        .route("/user/playlists/{id}/tracks", post(add_track))
        .route("/user/playlists/{id}/tracks/{track_id}", delete(remove_track))
        .route("/shared/{token}", get(get_shared))
        .route("/user/favorites", get(list_favorites).post(add_favorite))
        .route("/user/favorites/{song_id}", delete(remove_favorite))
        .route("/user/settings", get(get_settings).put(update_settings))
        .route("/user/settings/expanded", get(get_expanded).put(put_expanded))
        .route("/user/library/inventory", post(upload_inventory))
        .route("/user/library/duplicates", get(library_duplicates))
        .route("/user/history", get(get_history).fallback(proxy::fallback))
        .route("/user/sync", get(sync_pull).post(sync_push))
        .route("/user/backups", get(list_backups).delete(clear_backups))
        .route("/user/backups/{id}/restore", post(restore_backup))
        .route("/user/folder-backups", get(get_folder_backups).put(put_folder_backups))
        .route("/user/queue", get(get_queue).put(replace_queue).delete(clear_queue))
        .route("/user/playback-state", get(get_playback).put(put_playback))
}

async fn ev(st: &AppState, cat: &'static str, name: &'static str, user: &str, detail: Value) {
    let (st, user) = (st.clone(), user.to_string());
    tokio::spawn(async move { crate::db::log_event(&st.db, cat, name, Some(&user), "info", "", Some(detail)).await });
}

// ---- playlists -------------------------------------------------------------------------------

const PL_FIELDS: &str = "'id', p.id, 'name', p.name, 'description', p.description, 'created_at', lumi_iso(p.created_at), \
    'updated_at', lumi_iso(p.updated_at), 'folder', p.folder, 'tags', COALESCE(NULLIF(p.tags_json, '')::json, '[]'::json)";
const TRACKS_SUB: &str = "COALESCE((SELECT json_agg(json_build_object('id', t.id, 'track_url', t.track_url, \
    'local_song_id', t.local_song_id, 'title', t.title, 'artist', t.artist, 'album', t.album, \
    'duration_seconds', t.duration_seconds, 'position', t.position) ORDER BY t.position ASC) \
    FROM ios_playlist_tracks t WHERE t.playlist_id = p.id), '[]'::json)";

async fn list_playlists(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let sql = format!(
        "SELECT COALESCE(json_agg(json_build_object({PL_FIELDS}, 'tracks', {TRACKS_SUB}) ORDER BY p.updated_at DESC), '[]'::json) \
         FROM ios_user_playlists p WHERE p.user_id = $1"
    );
    Ok(Json(sqlx::query_scalar(&sql).bind(&u.id).fetch_one(&st.db).await?))
}

async fn playlist_json(st: &AppState, id: &str, with_tracks: bool) -> ApiResult<Option<Value>> {
    let tracks = if with_tracks { format!(", 'tracks', {TRACKS_SUB}") } else { String::new() };
    let sql = format!("SELECT json_build_object({PL_FIELDS}{tracks}) FROM ios_user_playlists p WHERE p.id = $1");
    Ok(sqlx::query_scalar(&sql).bind(id).fetch_optional(&st.db).await?)
}

#[derive(Deserialize)]
struct CreatePlaylist {
    name: String,
    description: Option<String>,
    folder: Option<String>,
    #[serde(default)]
    tags: Vec<String>,
}

async fn create_playlist(State(st): State<AppState>, u: User, J(b): J<CreatePlaylist>) -> ApiResult<Response> {
    let id = uuid::Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO ios_user_playlists (id, user_id, name, description, folder, tags_json) VALUES ($1, $2, $3, $4, $5, $6)")
        .bind(&id)
        .bind(&u.id)
        .bind(&b.name)
        .bind(&b.description)
        .bind(&b.folder)
        .bind(serde_json::to_string(&b.tags).unwrap())
        .execute(&st.db)
        .await?;
    let mut v = playlist_json(&st, &id, false).await?.unwrap_or(Value::Null);
    v["tracks"] = json!([]);
    ev(&st, "playlist", "playlist_created", &u.id, json!({"playlist_id": id})).await;
    Ok((StatusCode::CREATED, Json(v)).into_response())
}

#[derive(Deserialize)]
struct UpdatePlaylist {
    name: Option<String>,
    description: Option<String>,
    folder: Option<String>,
    tags: Option<Vec<String>>,
}

async fn update_playlist(State(st): State<AppState>, u: User, Path(id): Path<String>, J(b): J<UpdatePlaylist>) -> ApiResult<Json<Value>> {
    let owned: Option<String> =
        sqlx::query_scalar("SELECT id FROM ios_user_playlists WHERE id = $1 AND user_id = $2").bind(&id).bind(&u.id).fetch_optional(&st.db).await?;
    if owned.is_none() {
        return Err(AppError::not_found("Playlist not found"));
    }
    if b.name.is_some() || b.description.is_some() || b.folder.is_some() || b.tags.is_some() {
        sqlx::query(
            "UPDATE ios_user_playlists SET name = COALESCE($1, name), description = COALESCE($2, description), \
             folder = CASE WHEN $3 THEN NULLIF($4, '') ELSE folder END, tags_json = COALESCE($5, tags_json) WHERE id = $6",
        )
        .bind(&b.name)
        .bind(&b.description)
        .bind(b.folder.is_some())
        .bind(&b.folder)
        .bind(b.tags.as_ref().map(|t| serde_json::to_string(t).unwrap()))
        .bind(&id)
        .execute(&st.db)
        .await?;
    }
    let v = playlist_json(&st, &id, false).await?.unwrap_or(Value::Null);
    ev(&st, "playlist", "playlist_updated", &u.id, json!({"playlist_id": id})).await;
    Ok(Json(v))
}

async fn delete_playlist(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<StatusCode> {
    let r = sqlx::query("DELETE FROM ios_user_playlists WHERE id = $1 AND user_id = $2").bind(&id).bind(&u.id).execute(&st.db).await?;
    if r.rows_affected() == 0 {
        return Err(AppError::not_found("Playlist not found"));
    }
    ev(&st, "playlist", "playlist_deleted", &u.id, json!({"playlist_id": id})).await;
    Ok(StatusCode::NO_CONTENT)
}

/// `_playlist_role`: owner, a collaborator role, or None.
pub async fn playlist_role(st: &AppState, playlist_id: &str, user_id: &str) -> ApiResult<Option<String>> {
    let owner: Option<String> = sqlx::query_scalar("SELECT user_id FROM ios_user_playlists WHERE id = $1").bind(playlist_id).fetch_optional(&st.db).await?;
    let Some(owner) = owner else { return Ok(None) };
    if owner == user_id {
        return Ok(Some("owner".into()));
    }
    Ok(sqlx::query_scalar("SELECT role FROM ios_playlist_collaborators WHERE playlist_id = $1 AND user_id = $2")
        .bind(playlist_id)
        .bind(user_id)
        .fetch_optional(&st.db)
        .await?)
}

async fn get_playlist(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    let role = playlist_role(&st, &id, &u.id).await?.ok_or_else(|| AppError::not_found("Playlist not found"))?;
    let mut v = playlist_json(&st, &id, true).await?.ok_or_else(|| AppError::not_found("Playlist not found"))?;
    let tracks = v["tracks"].take();
    v["role"] = json!(role);
    v["tracks"] = tracks;
    Ok(Json(v))
}

async fn playlist_folders(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('folder', NULLIF(f, ''), 'count', n) ORDER BY f ASC), '[]'::json) \
             FROM (SELECT COALESCE(folder, '') AS f, COUNT(*) AS n FROM ios_user_playlists WHERE user_id = $1 GROUP BY folder) x",
        )
        .bind(&u.id)
        .fetch_one(&st.db)
        .await?,
    ))
}

#[derive(Deserialize)]
struct TrackBody {
    local_song_id: Option<String>,
    track_url: Option<String>,
    title: String,
    artist: Option<String>,
    album: Option<String>,
    duration_seconds: Option<i64>,
    position: Option<i64>,
}

async fn add_track(State(st): State<AppState>, u: User, Path(id): Path<String>, J(b): J<TrackBody>) -> ApiResult<Response> {
    let role = playlist_role(&st, &id, &u.id).await?.ok_or_else(|| AppError::not_found("Playlist not found"))?;
    if role == "viewer" {
        return Err(AppError::forbidden("You only have view access to this playlist"));
    }
    let track_id = uuid::Uuid::new_v4().to_string();
    let pos: i32 = sqlx::query_scalar(
        "INSERT INTO ios_playlist_tracks (id, playlist_id, track_url, local_song_id, title, artist, album, duration_seconds, position) \
         SELECT $1, $2, $3, $4, $5, $6, $7, $8, COALESCE(MAX(position), -1) + 1 FROM ios_playlist_tracks WHERE playlist_id = $2 \
         RETURNING position",
    )
    .bind(&track_id)
    .bind(&id)
    .bind(&b.track_url)
    .bind(&b.local_song_id)
    .bind(&b.title)
    .bind(&b.artist)
    .bind(&b.album)
    .bind(b.duration_seconds.unwrap_or(0) as i32)
    .fetch_one(&st.db)
    .await?;
    sqlx::query("UPDATE ios_user_playlists SET updated_at = NOW() WHERE id = $1").bind(&id).execute(&st.db).await?;
    ev(&st, "playlist", "track_added", &u.id, json!({"playlist_id": id, "track_id": track_id})).await;
    Ok((StatusCode::CREATED, Json(json!({"id": track_id, "position": pos}))).into_response())
}

async fn remove_track(State(st): State<AppState>, u: User, Path((id, track_id)): Path<(String, String)>) -> ApiResult<StatusCode> {
    let role = playlist_role(&st, &id, &u.id).await?.ok_or_else(|| AppError::not_found("Playlist not found"))?;
    if role == "viewer" {
        return Err(AppError::forbidden("You only have view access to this playlist"));
    }
    let r = sqlx::query("DELETE FROM ios_playlist_tracks WHERE id = $1 AND playlist_id = $2").bind(&track_id).bind(&id).execute(&st.db).await?;
    if r.rows_affected() == 0 {
        return Err(AppError::not_found("Track not found in playlist"));
    }
    sqlx::query("UPDATE ios_user_playlists SET updated_at = NOW() WHERE id = $1").bind(&id).execute(&st.db).await?;
    ev(&st, "playlist", "track_removed", &u.id, json!({"playlist_id": id, "track_id": track_id})).await;
    Ok(StatusCode::NO_CONTENT)
}

// ---- sharing ---------------------------------------------------------------------------------

#[derive(Deserialize)]
struct ShareBody {
    #[serde(default)]
    playlist_id: String,
    playlist_name: String,
    tracks: Vec<Value>,
}

async fn share_playlist(State(st): State<AppState>, u: User, J(b): J<ShareBody>) -> ApiResult<Response> {
    use rand::Rng;
    const ALPHA: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";
    let exists: Option<i32> = sqlx::query_scalar("SELECT 1 FROM ios_users WHERE id = $1").bind(&u.id).fetch_optional(&st.db).await?;
    if exists.is_none() {
        return Err(AppError::unauthorized("User not found"));
    }
    let mut token = None;
    for _ in 0..10 {
        let code: String = { let mut r = rand::rng(); (0..8).map(|_| ALPHA[r.random_range(0..ALPHA.len())] as char).collect() };
        let taken: Option<i32> = sqlx::query_scalar("SELECT 1 FROM ios_shared_playlists WHERE share_token = $1").bind(&code).fetch_optional(&st.db).await?;
        if taken.is_none() {
            token = Some(code);
            break;
        }
    }
    let token = token.ok_or_else(|| AppError::internal("Could not generate a unique share code"))?;
    sqlx::query("INSERT INTO ios_shared_playlists (id, playlist_id, owner_user_id, share_token, playlist_data) VALUES ($1, $2, $3, $4, $5)")
        .bind(uuid::Uuid::new_v4().to_string())
        .bind(&b.playlist_id)
        .bind(&u.id)
        .bind(&token)
        .bind(sqlx::types::Json(json!({"name": b.playlist_name, "tracks": b.tracks})))
        .execute(&st.db)
        .await?;
    tracing::info!("share_playlist: user {} shared playlist {} as code {token}", u.id, b.playlist_id);
    Ok((StatusCode::CREATED, Json(json!({"share_token": token, "share_url": format!("lumisound://shared/{token}")}))).into_response())
}

async fn get_shared(State(st): State<AppState>, Path(token): Path<String>) -> ApiResult<Json<Value>> {
    let row: Option<(Option<Value>, Option<String>, Option<bool>, Option<String>, Option<String>)> = sqlx::query_as(
        "SELECT sp.playlist_data::json, lumi_iso(sp.created_at), sp.is_active, u.display_name, u.username \
         FROM ios_shared_playlists sp JOIN ios_users u ON u.id = sp.owner_user_id WHERE sp.share_token = $1",
    )
    .bind(&token)
    .fetch_optional(&st.db)
    .await?;
    let (data, created, active, display, username) = row.ok_or_else(|| AppError::not_found("Shared playlist not found"))?;
    if !active.unwrap_or(false) {
        return Err(AppError::not_found("Shared playlist has been revoked"));
    }
    let data = data.unwrap_or(json!({}));
    let tracks = data.get("tracks").cloned().unwrap_or(json!([]));
    let n = tracks.as_array().map_or(0, Vec::len);
    Ok(Json(json!({
        "share_token": token,
        "name": data.get("name").cloned().unwrap_or(json!("Shared Playlist")),
        "owner": display.filter(|d| !d.is_empty()).or(username),
        "tracks": tracks,
        "track_count": n,
        "created_at": created,
    })))
}

async fn revoke_share(State(st): State<AppState>, u: User, Path(token): Path<String>) -> ApiResult<StatusCode> {
    let row: Option<(String, Option<bool>)> =
        sqlx::query_as("SELECT owner_user_id, is_active FROM ios_shared_playlists WHERE share_token = $1").bind(&token).fetch_optional(&st.db).await?;
    let (owner, _) = row.ok_or_else(|| AppError::not_found("Shared playlist not found"))?;
    if owner != u.id {
        return Err(AppError::forbidden("You are not the owner of this shared playlist"));
    }
    sqlx::query("UPDATE ios_shared_playlists SET is_active = FALSE WHERE share_token = $1 AND owner_user_id = $2").bind(&token).bind(&u.id).execute(&st.db).await?;
    tracing::info!("revoke_shared_playlist: user {} revoked share token {token}", u.id);
    Ok(StatusCode::NO_CONTENT)
}

// ---- favorites -------------------------------------------------------------------------------

async fn list_favorites(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('song_id', song_id, 'title', title, 'artist', artist, 'album', album, \
               'added_at', lumi_iso(added_at)) ORDER BY added_at DESC), '[]'::json) FROM ios_user_favorites WHERE user_id = $1",
        )
        .bind(&u.id)
        .fetch_one(&st.db)
        .await?,
    ))
}

#[derive(Deserialize)]
struct FavBody {
    song_id: String,
    title: Option<String>,
    artist: Option<String>,
    album: Option<String>,
}

async fn add_favorite(State(st): State<AppState>, u: User, J(b): J<FavBody>) -> ApiResult<Response> {
    sqlx::query(
        "INSERT INTO ios_user_favorites (user_id, song_id, title, artist, album) VALUES ($1, $2, $3, $4, $5) \
         ON CONFLICT (user_id, song_id) DO UPDATE SET title = EXCLUDED.title, artist = EXCLUDED.artist, album = EXCLUDED.album",
    )
    .bind(&u.id)
    .bind(&b.song_id)
    .bind(&b.title)
    .bind(&b.artist)
    .bind(&b.album)
    .execute(&st.db)
    .await?;
    ev(&st, "favorites", "favorite_added", &u.id, json!({"song_id": b.song_id})).await;
    Ok((StatusCode::CREATED, Json(json!({"song_id": b.song_id, "status": "added"}))).into_response())
}

async fn remove_favorite(State(st): State<AppState>, u: User, Path(song_id): Path<String>) -> ApiResult<StatusCode> {
    sqlx::query("DELETE FROM ios_user_favorites WHERE user_id = $1 AND song_id = $2").bind(&u.id).bind(&song_id).execute(&st.db).await?;
    ev(&st, "favorites", "favorite_removed", &u.id, json!({"song_id": song_id})).await;
    Ok(StatusCode::NO_CONTENT)
}

// ---- settings --------------------------------------------------------------------------------

const SETTINGS_JSON: &str = "SELECT json_build_object('audio_settings_json', audio_settings_json, \
    'track_audio_settings_json', track_audio_settings_json, 'theme_color', theme_color, 'updated_at', lumi_iso(updated_at), \
    'preferred_audio_format', COALESCE(NULLIF(preferred_audio_format, ''), 'm4a')) FROM ios_user_settings WHERE user_id = $1";

async fn get_settings(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let v: Option<Value> = sqlx::query_scalar(SETTINGS_JSON).bind(&u.id).fetch_optional(&st.db).await?;
    Ok(Json(v.unwrap_or_else(|| {
        json!({"audio_settings_json": null, "track_audio_settings_json": null, "theme_color": "#EC4079", "updated_at": null, "preferred_audio_format": "m4a"})
    })))
}

#[derive(Deserialize)]
struct SettingsBody {
    audio_settings_json: Option<String>,
    track_audio_settings_json: Option<String>,
    theme_color: Option<String>,
    preferred_audio_format: Option<String>,
}

async fn update_settings(State(st): State<AppState>, u: User, J(b): J<SettingsBody>) -> ApiResult<Json<Value>> {
    let or = |s: &Option<String>, d: &str| s.clone().filter(|s| !s.is_empty()).unwrap_or_else(|| d.to_string());
    sqlx::query(
        "INSERT INTO ios_user_settings (user_id, audio_settings_json, track_audio_settings_json, theme_color, preferred_audio_format) \
         VALUES ($1, $2, $3, $4, $5) ON CONFLICT (user_id) DO UPDATE SET \
           audio_settings_json = COALESCE($2, ios_user_settings.audio_settings_json), \
           track_audio_settings_json = COALESCE($3, ios_user_settings.track_audio_settings_json), \
           theme_color = COALESCE($6, ios_user_settings.theme_color), \
           preferred_audio_format = COALESCE($7, ios_user_settings.preferred_audio_format)",
    )
    .bind(&u.id)
    .bind(&b.audio_settings_json)
    .bind(&b.track_audio_settings_json)
    .bind(or(&b.theme_color, "#EC4079"))
    .bind(or(&b.preferred_audio_format, "m4a"))
    .bind(&b.theme_color)
    .bind(&b.preferred_audio_format)
    .execute(&st.db)
    .await?;
    let v: Value = sqlx::query_scalar(SETTINGS_JSON).bind(&u.id).fetch_one(&st.db).await?;
    Ok(Json(v))
}

const EXPANDED_ALLOWED: &[&str] = &[
    "audio_settings_json", "theme_color", "vinyl_disc_enabled", "show_queue_preview", "songs_per_row", "albums_per_row",
    "bg_animation", "bg_opacity", "preferred_audio_format", "download_path",
];

async fn get_expanded(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let v: Option<Value> = sqlx::query_scalar(
        "SELECT json_build_object('user_id', user_id, 'audio_settings_json', audio_settings_json, 'theme_color', theme_color, \
           'vinyl_disc_enabled', vinyl_disc_enabled, 'show_queue_preview', show_queue_preview, 'songs_per_row', songs_per_row, \
           'albums_per_row', albums_per_row, 'bg_animation', bg_animation, 'bg_opacity', bg_opacity, \
           'preferred_audio_format', preferred_audio_format, 'download_path', download_path, 'updated_at', lumi_iso(updated_at)) \
         FROM ios_user_settings_expanded WHERE user_id = $1",
    )
    .bind(&u.id)
    .fetch_optional(&st.db)
    .await?;
    Ok(Json(v.unwrap_or(json!({}))))
}

async fn put_expanded(State(st): State<AppState>, u: User, body: Bytes) -> ApiResult<Json<Value>> {
    if body.len() > 262_144 {
        return Err(AppError::new(413, "Settings payload too large"));
    }
    let v: Value = serde_json::from_slice(&body).map_err(|_| AppError::bad_request("Invalid JSON body"))?;
    let Value::Object(obj) = v else { return Err(AppError::bad_request("Body must be a JSON object")) };
    let updates: Map<String, Value> = obj.into_iter().filter(|(k, _)| EXPANDED_ALLOWED.contains(&k.as_str())).collect();
    if updates.is_empty() {
        return Ok(Json(json!({"ok": true})));
    }
    // Column list comes from the allowlist; jsonb_populate_record does the typing.
    let cols: Vec<&str> = EXPANDED_ALLOWED.iter().copied().filter(|c| updates.contains_key(*c)).collect();
    let sql = format!(
        "INSERT INTO ios_user_settings_expanded (user_id, {c}) SELECT $1, {r} FROM jsonb_populate_record(NULL::ios_user_settings_expanded, $2) r \
         ON CONFLICT (user_id) DO UPDATE SET {s}",
        c = cols.join(", "),
        r = cols.iter().map(|c| format!("r.{c}")).collect::<Vec<_>>().join(", "),
        s = cols.iter().map(|c| format!("{c} = EXCLUDED.{c}")).collect::<Vec<_>>().join(", "),
    );
    sqlx::query(&sql).bind(&u.id).bind(sqlx::types::Json(Value::Object(updates))).execute(&st.db).await?;
    let mut keys: Vec<&str> = cols.clone();
    keys.sort();
    ev(&st, "settings", "expanded_settings_updated", &u.id, json!({"keys": keys})).await;
    Ok(Json(json!({"ok": true})))
}

// ---- inventory / history / duplicates ---------------------------------------------------------

#[derive(Deserialize)]
struct InventoryBody {
    #[serde(default)]
    source_ids: Vec<Option<String>>,
}

async fn upload_inventory(State(st): State<AppState>, u: User, J(b): J<InventoryBody>) -> ApiResult<Json<Value>> {
    let ids: std::collections::BTreeSet<String> =
        b.source_ids.into_iter().flatten().map(|s| s.trim().to_string()).filter(|s| !s.is_empty() && s.chars().count() <= 255).collect();
    let ids: Vec<String> = ids.into_iter().collect();
    for attempt in 1..=3 {
        let r: Result<(), sqlx::Error> = async {
            let mut tx = st.db.begin().await?;
            sqlx::query("DELETE FROM ios_user_library_inventory WHERE user_id = $1").bind(&u.id).execute(&mut *tx).await?;
            if !ids.is_empty() {
                sqlx::query(
                    "INSERT INTO ios_user_library_inventory (user_id, source_id) SELECT $1, unnest($2::text[]) ON CONFLICT DO NOTHING",
                )
                .bind(&u.id)
                .bind(&ids)
                .execute(&mut *tx)
                .await?;
            }
            tx.commit().await
        }
        .await;
        match r {
            Ok(()) => break,
            Err(sqlx::Error::Database(e)) if matches!(e.code().as_deref(), Some("40P01" | "40001")) && attempt < 3 => {
                tracing::warn!("upload_inventory: attempt {attempt}/3 hit {:?} — retrying", e.code());
                tokio::time::sleep(std::time::Duration::from_millis(50 * attempt)).await;
            }
            Err(e) => return Err(e.into()),
        }
    }
    st.inventory.remove(&u.id);
    Ok(Json(json!({"status": "ok", "count": ids.len()})))
}

#[derive(Deserialize)]
struct LimitQ {
    limit: Option<i64>,
}

async fn get_history(State(st): State<AppState>, u: User, Q(q): Q<LimitQ>) -> ApiResult<Json<Value>> {
    let limit = q.limit.unwrap_or(50);
    check_range("limit", limit, 1, 200)?;
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('id', id, 'track_url', track_url, 'local_song_id', local_song_id, \
               'title', title, 'artist', artist, 'played_at', lumi_iso(played_at), 'listen_seconds', listen_seconds) ORDER BY played_at DESC), '[]'::json) \
             FROM (SELECT * FROM ios_play_history WHERE user_id = $1 ORDER BY played_at DESC LIMIT $2) h",
        )
        .bind(&u.id)
        .bind(limit)
        .fetch_one(&st.db)
        .await?,
    ))
}

async fn library_duplicates(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('title', title, 'artist', artist, 'occurrences', occurrences, \
               'playlists', CASE WHEN playlists IS NULL OR playlists = '' THEN '[]'::json ELSE to_json(string_to_array(playlists, ', ')) END) \
               ORDER BY occurrences DESC), '[]'::json) FROM ( \
               SELECT LOWER(TRIM(t.title)) AS norm_title, LOWER(TRIM(COALESCE(t.artist, ''))) AS norm_artist, COUNT(*) AS occurrences, \
                      STRING_AGG(DISTINCT p.name, ', ') AS playlists, MIN(t.title) AS title, MIN(t.artist) AS artist \
               FROM ios_playlist_tracks t JOIN ios_user_playlists p ON p.id = t.playlist_id \
               WHERE p.user_id = $1 AND t.title IS NOT NULL AND t.title != '' \
               GROUP BY norm_title, norm_artist HAVING COUNT(*) > 1 ORDER BY occurrences DESC LIMIT 100) d",
        )
        .bind(&u.id)
        .fetch_one(&st.db)
        .await?,
    ))
}

// ---- sync + backups --------------------------------------------------------------------------

const SETTING_COLS: &[&str] = &[
    "audio_settings_json", "track_audio_settings_json", "theme_color", "vinyl_disc_enabled", "show_queue_preview", "songs_per_row",
    "albums_per_row", "bg_animation", "bg_opacity", "bg_enabled", "bg_blur_radius", "bg_shuffle_interval", "preferred_audio_format",
    "download_path", "car_mode_enabled", "library_artists_columns", "now_playing_artwork_style", "now_playing_seeker_style",
    "earned_badges_json", "extra_settings_json", "play_history_json", "smart_playlists_json", "tracked_playlists_json",
    "bookmarks_json", "bpm_by_source_track_id_json",
];

/// `_build_sync_snapshot`, as one query.
async fn build_snapshot<'e, E: sqlx::PgExecutor<'e>>(db: E, user_id: &str) -> ApiResult<Value> {
    let v: Value = sqlx::query_scalar(
        "SELECT json_build_object( \
           'favorites', COALESCE((SELECT json_agg(json_build_object('song_id', song_id, 'title', title, 'artist', artist, 'album', album)) \
                                  FROM ios_user_favorites WHERE user_id = $1), '[]'::json), \
           'playlists', COALESCE((SELECT json_agg(json_build_object('id', p.id, 'name', p.name, 'description', p.description, \
                                     'folder', p.folder, 'tags', COALESCE(NULLIF(p.tags_json, '')::json, '[]'::json), \
                                     'tracks', COALESCE((SELECT json_agg(json_build_object('track_url', t.track_url, 'local_song_id', t.local_song_id, \
                                         'title', t.title, 'artist', t.artist, 'album', t.album, 'duration_seconds', t.duration_seconds, \
                                         'position', t.position) ORDER BY t.position ASC) FROM ios_playlist_tracks t \
                                         WHERE t.playlist_id = p.id AND (t.track_url IS NOT NULL OR t.title IS NOT NULL)), '[]'::json)) \
                                   ORDER BY p.updated_at DESC) FROM ios_user_playlists p WHERE p.user_id = $1), '[]'::json), \
           'settings', (SELECT row_to_json(s) FROM ios_user_settings s WHERE s.user_id = $1))",
    )
    .bind(user_id)
    .fetch_one(db)
    .await?;
    let s = v["settings"].clone();
    let has = !s.is_null();
    let g = |k: &str| if has { s[k].clone() } else { Value::Null };
    let or = |k: &str, d: Value| { let x = g(k); if x.is_null() { d } else { x } };
    let or_str = |k: &str, d: &str| match g(k) { Value::String(x) if !x.is_empty() => json!(x), _ => json!(d) };
    Ok(json!({
        "favorites": v["favorites"],
        "playlists": v["playlists"],
        "audio_settings_json": g("audio_settings_json"),
        "track_audio_settings_json": g("track_audio_settings_json"),
        "theme_color": if has { g("theme_color") } else { json!("#EC4079") },
        "vinyl_disc_enabled": or("vinyl_disc_enabled", json!(true)),
        "show_queue_preview": or("show_queue_preview", json!(true)),
        "songs_per_row": or("songs_per_row", json!(1)),
        "albums_per_row": or("albums_per_row", json!(2)),
        "bg_animation": or_str("bg_animation", "fade"),
        "bg_opacity": or("bg_opacity", json!(0.35)),
        "bg_enabled": or("bg_enabled", json!(true)),
        "bg_blur_radius": g("bg_blur_radius"),
        "bg_shuffle_interval": g("bg_shuffle_interval"),
        "preferred_audio_format": or_str("preferred_audio_format", "m4a"),
        "download_path": g("download_path"),
        "car_mode_enabled": or("car_mode_enabled", json!(false)),
        "library_artists_columns": or("library_artists_columns", json!(2)),
        "now_playing_artwork_style": g("now_playing_artwork_style"),
        "now_playing_seeker_style": g("now_playing_seeker_style"),
        "earned_badges_json": g("earned_badges_json"),
        "extra_settings_json": g("extra_settings_json"),
        "play_history_json": g("play_history_json"),
        "smart_playlists_json": g("smart_playlists_json"),
        "tracked_playlists_json": g("tracked_playlists_json"),
        "bookmarks_json": g("bookmarks_json"),
        "bpm_by_source_track_id_json": g("bpm_by_source_track_id_json"),
    }))
}

async fn log_sync(tx: &mut Transaction<'_, Postgres>, user_id: &str, action: &str, details: &str) -> ApiResult<()> {
    sqlx::query("INSERT INTO ios_sync_log (user_id, action, details) VALUES ($1, $2, $3)")
        .bind(user_id)
        .bind(crate::db::truncate(action, 20))
        .bind(crate::db::truncate(details, 255))
        .execute(&mut **tx)
        .await?;
    Ok(())
}

async fn create_backup(tx: &mut Transaction<'_, Postgres>, user_id: &str, reason: &str) -> ApiResult<()> {
    let snap = build_snapshot(&mut **tx, user_id).await?;
    sqlx::query("INSERT INTO ios_user_backups (id, user_id, reason, snapshot_json) VALUES ($1, $2, $3, $4)")
        .bind(uuid::Uuid::new_v4().to_string())
        .bind(user_id)
        .bind(crate::db::truncate(reason, 30))
        .bind(snap.to_string())
        .execute(&mut **tx)
        .await?;
    sqlx::query(
        "DELETE FROM ios_user_backups WHERE user_id = $1 AND id NOT IN \
         (SELECT id FROM ios_user_backups WHERE user_id = $1 ORDER BY created_at DESC LIMIT 20)",
    )
    .bind(user_id)
    .execute(&mut **tx)
    .await?;
    Ok(())
}

/// Replace favorites + playlists (+ tracks) from snapshot-shaped JSON.
async fn replace_library(tx: &mut Transaction<'_, Postgres>, user_id: &str, favorites: &[Value], playlists: &[Value], with_folder_tags: bool) -> ApiResult<()> {
    sqlx::query("DELETE FROM ios_user_favorites WHERE user_id = $1").bind(user_id).execute(&mut **tx).await?;
    if !favorites.is_empty() {
        sqlx::query(
            "INSERT INTO ios_user_favorites (user_id, song_id, title, artist, album) \
             SELECT $1, f->>'song_id', f->>'title', f->>'artist', f->>'album' FROM jsonb_array_elements($2) f \
             ON CONFLICT (user_id, song_id) DO UPDATE SET title = EXCLUDED.title, artist = EXCLUDED.artist, album = EXCLUDED.album",
        )
        .bind(user_id)
        .bind(sqlx::types::Json(favorites))
        .execute(&mut **tx)
        .await?;
    }
    sqlx::query("DELETE FROM ios_user_playlists WHERE user_id = $1").bind(user_id).execute(&mut **tx).await?;
    if playlists.is_empty() {
        return Ok(());
    }
    let mut pls: Vec<Value> = Vec::with_capacity(playlists.len());
    let mut tracks: Vec<Value> = Vec::new();
    for p in playlists {
        let id = p["id"].as_str().filter(|s| !s.is_empty()).map(str::to_string).unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        let tags = if with_folder_tags {
            Some(match p.get("tags") { Some(t @ Value::Array(_)) => serde_json::to_string(t).unwrap(), _ => "[]".to_string() })
        } else {
            None
        };
        pls.push(json!({"id": id, "name": p["name"], "description": p["description"],
            "folder": if with_folder_tags { p["folder"].clone() } else { Value::Null }, "tags_json": tags}));
        for (idx, t) in p["tracks"].as_array().into_iter().flatten().enumerate() {
            let dur = t["duration_seconds"].as_f64().filter(|d| *d != 0.0).map(|d| d as i64).unwrap_or(0);
            let pos = if t["position"].is_null() { idx as i64 } else { t["position"].as_f64().map(|p| p as i64).unwrap_or(idx as i64) };
            tracks.push(json!({"id": uuid::Uuid::new_v4().to_string(), "playlist_id": id, "track_url": t["track_url"],
                "local_song_id": t["local_song_id"], "title": t["title"], "artist": t["artist"], "album": t["album"],
                "duration_seconds": dur, "position": pos}));
        }
    }
    sqlx::query(
        "INSERT INTO ios_user_playlists (id, user_id, name, description, folder, tags_json) \
         SELECT p->>'id', $1, p->>'name', p->>'description', p->>'folder', p->>'tags_json' FROM jsonb_array_elements($2) p \
         ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, description = EXCLUDED.description, \
           folder = EXCLUDED.folder, tags_json = EXCLUDED.tags_json",
    )
    .bind(user_id)
    .bind(sqlx::types::Json(&pls))
    .execute(&mut **tx)
    .await?;
    if !tracks.is_empty() {
        sqlx::query(
            "INSERT INTO ios_playlist_tracks (id, playlist_id, track_url, local_song_id, title, artist, album, duration_seconds, position) \
             SELECT t->>'id', t->>'playlist_id', t->>'track_url', t->>'local_song_id', t->>'title', t->>'artist', t->>'album', \
                    (t->>'duration_seconds')::int, (t->>'position')::int FROM jsonb_array_elements($1) t",
        )
        .bind(sqlx::types::Json(&tracks))
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}

async fn sync_pull(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let mut tx = st.db.begin().await?;
    let snap = build_snapshot(&mut *tx, &u.id).await?;
    log_sync(&mut tx, &u.id, "pull", "").await?;
    tx.commit().await?;
    Ok(Json(snap))
}

async fn sync_push(State(st): State<AppState>, u: User, J(b): J<Map<String, Value>>) -> ApiResult<Json<Value>> {
    let favorites: Vec<Value> = b.get("favorites").and_then(Value::as_array).cloned().unwrap_or_default();
    let playlists: Vec<Value> = b.get("playlists").and_then(Value::as_array).cloned().unwrap_or_default();
    for (i, f) in favorites.iter().enumerate() {
        if !f["song_id"].is_string() {
            return Err(AppError::with_value(422, json!([{"type": "missing", "loc": ["body", "favorites", i, "song_id"], "msg": "Field required"}])));
        }
    }
    for (i, p) in playlists.iter().enumerate() {
        for k in ["id", "name"] {
            if !p[k].is_string() {
                return Err(AppError::with_value(422, json!([{"type": "missing", "loc": ["body", "playlists", i, k], "msg": "Field required"}])));
            }
        }
    }
    let mut tx = st.db.begin().await?;
    create_backup(&mut tx, &u.id, "pre_push").await?;
    log_sync(&mut tx, &u.id, "push", &format!("{} favorites, {} playlists", favorites.len(), playlists.len())).await?;
    replace_library(&mut tx, &u.id, &favorites, &playlists, true).await?;
    // Settings: the body's value wins, a missing/null one keeps the stored value.
    let mut settings = Map::new();
    for c in SETTING_COLS {
        if let Some(v) = b.get(*c).filter(|v| !v.is_null()) {
            settings.insert(c.to_string(), v.clone());
        }
    }
    let insert_theme = b.get("theme_color").and_then(Value::as_str).filter(|s| !s.is_empty()).unwrap_or("#EC4079").to_string();
    let cols = SETTING_COLS.join(", ");
    let sel = SETTING_COLS.iter().map(|c| if *c == "theme_color" { "$3".to_string() } else { format!("r.{c}") }).collect::<Vec<_>>().join(", ");
    let set = SETTING_COLS
        .iter()
        .map(|c| {
            let val = if *c == "theme_color" { "$2->>'theme_color'".to_string() } else { format!("EXCLUDED.{c}") };
            format!("{c} = CASE WHEN $2 ? '{c}' THEN {val} ELSE ios_user_settings.{c} END")
        })
        .collect::<Vec<_>>()
        .join(", ");
    let sql = format!(
        "INSERT INTO ios_user_settings (user_id, {cols}) SELECT $1, {sel} FROM jsonb_populate_record(NULL::ios_user_settings, $2) r \
         ON CONFLICT (user_id) DO UPDATE SET {set}"
    );
    sqlx::query(&sql).bind(&u.id).bind(sqlx::types::Json(Value::Object(settings))).bind(&insert_theme).execute(&mut *tx).await?;
    tx.commit().await?;
    st.push_live(&u.id, json!({"type": "sync_changed"}));
    Ok(Json(json!({"status": "synced"})))
}

async fn list_backups(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('id', id, 'reason', reason, 'created_at', lumi_iso(created_at), \
           'favorite_count', COALESCE(jsonb_array_length((snapshot_json::jsonb) -> 'favorites'), 0), \
           'playlist_count', COALESCE(jsonb_array_length((snapshot_json::jsonb) -> 'playlists'), 0)) ORDER BY created_at DESC), '[]'::json) \
         FROM ios_user_backups WHERE user_id = $1",
    )
    .bind(&u.id)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"backups": v})))
}

async fn clear_backups(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let mut tx = st.db.begin().await?;
    let n = sqlx::query("DELETE FROM ios_user_backups WHERE user_id = $1").bind(&u.id).execute(&mut *tx).await?.rows_affected();
    log_sync(&mut tx, &u.id, "clear_backups", &format!("deleted {n} backups")).await?;
    tx.commit().await?;
    Ok(Json(json!({"status": "cleared", "deleted": n})))
}

async fn restore_backup(State(st): State<AppState>, u: User, Path(id): Path<String>) -> ApiResult<Json<Value>> {
    let mut tx = st.db.begin().await?;
    let row: Option<(String, Option<String>)> = sqlx::query_as("SELECT snapshot_json, lumi_iso(created_at) FROM ios_user_backups WHERE id = $1 AND user_id = $2")
        .bind(&id)
        .bind(&u.id)
        .fetch_optional(&mut *tx)
        .await?;
    let (raw, created) = row.ok_or_else(|| AppError::not_found("Backup not found"))?;
    let snap: Value = serde_json::from_str(&raw).map_err(|e| AppError::internal(e.to_string()))?;
    create_backup(&mut tx, &u.id, "pre_restore").await?;
    let favs = snap["favorites"].as_array().cloned().unwrap_or_default();
    let pls = snap["playlists"].as_array().cloned().unwrap_or_default();
    replace_library(&mut tx, &u.id, &favs, &pls, false).await?;
    // Restore writes every setting (snapshot.get(k, default)).
    let defaults: &[(&str, Value)] = &[
        ("vinyl_disc_enabled", json!(true)), ("show_queue_preview", json!(true)), ("songs_per_row", json!(1)),
        ("albums_per_row", json!(2)), ("bg_opacity", json!(0.35)), ("bg_enabled", json!(true)),
        ("car_mode_enabled", json!(false)), ("library_artists_columns", json!(2)),
    ];
    let mut s = Map::new();
    for c in SETTING_COLS {
        let v = match snap.get(*c) {
            Some(v) => v.clone(),
            None => defaults.iter().find(|(k, _)| k == c).map(|(_, d)| d.clone()).unwrap_or(Value::Null),
        };
        s.insert(c.to_string(), v);
    }
    for (k, d) in [("theme_color", "#EC4079"), ("bg_animation", "fade"), ("preferred_audio_format", "m4a")] {
        if !s[k].as_str().is_some_and(|x| !x.is_empty()) {
            s.insert(k.into(), json!(d));
        }
    }
    let cols = SETTING_COLS.join(", ");
    let sel = SETTING_COLS.iter().map(|c| format!("r.{c}")).collect::<Vec<_>>().join(", ");
    let set = SETTING_COLS.iter().map(|c| format!("{c} = EXCLUDED.{c}")).collect::<Vec<_>>().join(", ");
    sqlx::query(&format!(
        "INSERT INTO ios_user_settings (user_id, {cols}) SELECT $1, {sel} FROM jsonb_populate_record(NULL::ios_user_settings, $2) r \
         ON CONFLICT (user_id) DO UPDATE SET {set}"
    ))
    .bind(&u.id)
    .bind(sqlx::types::Json(Value::Object(s)))
    .execute(&mut *tx)
    .await?;
    log_sync(&mut tx, &u.id, "restore", &format!("restored backup from {}", created.unwrap_or(id))).await?;
    let snap = build_snapshot(&mut *tx, &u.id).await?;
    log_sync(&mut tx, &u.id, "pull", "").await?;
    tx.commit().await?;
    Ok(Json(snap))
}

#[derive(Deserialize)]
struct FolderBackupBody {
    #[serde(default)]
    folders: Vec<FolderEntry>,
}

#[derive(Deserialize)]
struct FolderEntry {
    folder_path: String,
    #[serde(default)]
    tracks: Vec<Map<String, Value>>,
}

async fn put_folder_backups(State(st): State<AppState>, u: User, J(b): J<FolderBackupBody>) -> ApiResult<Json<Value>> {
    let mut tx = st.db.begin().await?;
    sqlx::query("DELETE FROM ios_user_folder_backups WHERE user_id = $1").bind(&u.id).execute(&mut *tx).await?;
    for f in &b.folders {
        let mut tracks: Vec<Value> = Vec::with_capacity(f.tracks.len());
        for (i, t) in f.tracks.iter().enumerate() {
            let Some(name) = t.get("filename").and_then(Value::as_str) else {
                return Err(AppError::with_value(422, json!([{"type": "missing", "loc": ["body", "folders", "tracks", i, "filename"], "msg": "Field required"}])));
            };
            let s = |k: &str| t.get(k).filter(|v| v.is_string()).cloned().unwrap_or(Value::Null);
            // pydantic: an omitted duration stays the int default 0, a sent one becomes a float.
            let dur = match t.get("duration_seconds") {
                None => json!(0),
                Some(Value::Number(n)) => json!(n.as_f64().unwrap_or(0.0)),
                Some(_) => Value::Null,
            };
            tracks.push(json!({"filename": name, "title": s("title"), "artist": s("artist"), "duration_seconds": dur, "source_track_id": s("source_track_id")}));
        }
        sqlx::query("INSERT INTO ios_user_folder_backups (id, user_id, folder_path, track_filenames_json) VALUES ($1, $2, $3, $4)")
            .bind(uuid::Uuid::new_v4().to_string())
            .bind(&u.id)
            .bind(&f.folder_path)
            .bind(serde_json::to_string(&tracks).unwrap())
            .execute(&mut *tx)
            .await?;
    }
    log_sync(&mut tx, &u.id, "folder_backup_push", &format!("{} folder(s)", b.folders.len())).await?;
    tx.commit().await?;
    Ok(Json(json!({"status": "synced", "folders": b.folders.len()})))
}

async fn get_folder_backups(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let v: Value = sqlx::query_scalar(
        "SELECT COALESCE(json_agg(json_build_object('folder_path', folder_path, \
           'tracks', COALESCE(NULLIF(track_filenames_json, '')::json, '[]'::json), 'updated_at', lumi_iso(updated_at)) ORDER BY folder_path ASC), '[]'::json) \
         FROM ios_user_folder_backups WHERE user_id = $1",
    )
    .bind(&u.id)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(json!({"folders": v})))
}

// ---- queue / playback state ------------------------------------------------------------------

async fn get_queue(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    Ok(Json(
        sqlx::query_scalar(
            "SELECT COALESCE(json_agg(json_build_object('id', id, 'local_song_id', local_song_id, 'track_url', track_url, 'title', title, \
               'artist', artist, 'album', album, 'duration_seconds', duration_seconds, 'position', position) ORDER BY position ASC), '[]'::json) \
             FROM ios_user_queue WHERE user_id = $1",
        )
        .bind(&u.id)
        .fetch_one(&st.db)
        .await?,
    ))
}

#[derive(Deserialize)]
struct QueueBody {
    #[serde(default)]
    tracks: Vec<TrackBody>,
}

async fn replace_queue(State(st): State<AppState>, u: User, J(b): J<QueueBody>) -> ApiResult<Json<Value>> {
    let rows: Vec<Value> = b
        .tracks
        .iter()
        .enumerate()
        .map(|(i, t)| {
            json!({"id": uuid::Uuid::new_v4().to_string(), "position": i, "local_song_id": t.local_song_id, "track_url": t.track_url,
                   "title": t.title, "artist": t.artist, "album": t.album, "duration_seconds": t.duration_seconds.filter(|d| *d != 0).unwrap_or(0)})
        })
        .collect();
    let mut tx = st.db.begin().await?;
    sqlx::query("DELETE FROM ios_user_queue WHERE user_id = $1").bind(&u.id).execute(&mut *tx).await?;
    if !rows.is_empty() {
        sqlx::query(
            "INSERT INTO ios_user_queue (id, user_id, position, local_song_id, track_url, title, artist, album, duration_seconds) \
             SELECT q->>'id', $1, (q->>'position')::int, q->>'local_song_id', q->>'track_url', q->>'title', q->>'artist', q->>'album', \
                    (q->>'duration_seconds')::int FROM jsonb_array_elements($2) q",
        )
        .bind(&u.id)
        .bind(sqlx::types::Json(&rows))
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(Json(json!({"status": "ok", "count": rows.len()})))
}

async fn clear_queue(State(st): State<AppState>, u: User) -> ApiResult<StatusCode> {
    sqlx::query("DELETE FROM ios_user_queue WHERE user_id = $1").bind(&u.id).execute(&st.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn get_playback(State(st): State<AppState>, u: User) -> ApiResult<Json<Value>> {
    let v: Option<Value> = sqlx::query_scalar(
        "SELECT json_build_object('song_id', song_id, 'title', title, 'artist', artist, 'track_url', track_url, 'source', source, \
           'position_seconds', position_seconds, 'duration_seconds', duration_seconds, \
           'updated_at', CASE WHEN updated_at IS NULL THEN NULL ELSE lumi_iso(updated_at) || '+00:00' END, \
           'is_playing', COALESCE(is_playing, false), 'bpm', bpm, 'artwork_url', artwork_url) FROM ios_playback_state WHERE user_id = $1",
    )
    .bind(&u.id)
    .fetch_optional(&st.db)
    .await?;
    Ok(Json(v.unwrap_or(Value::Null)))
}

#[derive(Deserialize)]
struct PlaybackBody {
    song_id: Option<String>,
    title: Option<String>,
    artist: Option<String>,
    track_url: Option<String>,
    source: Option<String>,
    #[serde(default)]
    position_seconds: f64,
    #[serde(default)]
    duration_seconds: f64,
    #[serde(default = "yes")]
    is_playing: bool,
    bpm: Option<f64>,
    artwork_url: Option<String>,
}

fn yes() -> bool {
    true
}



async fn put_playback(State(st): State<AppState>, u: User, J(b): J<PlaybackBody>) -> ApiResult<StatusCode> {
    sqlx::query(
        "INSERT INTO ios_playback_state (user_id, song_id, title, artist, track_url, source, position_seconds, duration_seconds, is_playing, bpm, artwork_url, updated_at) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, CURRENT_TIMESTAMP) ON CONFLICT (user_id) DO UPDATE SET \
           song_id = EXCLUDED.song_id, title = EXCLUDED.title, artist = EXCLUDED.artist, track_url = EXCLUDED.track_url, source = EXCLUDED.source, \
           position_seconds = EXCLUDED.position_seconds, duration_seconds = EXCLUDED.duration_seconds, is_playing = EXCLUDED.is_playing, \
           bpm = EXCLUDED.bpm, artwork_url = EXCLUDED.artwork_url, updated_at = EXCLUDED.updated_at",
    )
    .bind(&u.id)
    .bind(&b.song_id)
    .bind(&b.title)
    .bind(&b.artist)
    .bind(&b.track_url)
    .bind(&b.source)
    .bind(b.position_seconds)
    .bind(b.duration_seconds)
    .bind(b.is_playing)
    .bind(b.bpm)
    .bind(&b.artwork_url)
    .execute(&st.db)
    .await?;
    Ok(StatusCode::NO_CONTENT)
}
