//! Lumisound Radio: a session-based radio engine.
//!
//! A station starts from a seed (the song that just played, an artist...)
//! and keeps going for as long as the listener wants, steering by what they
//! actually do with it:
//!
//! * Candidates come from four places, each tagged so the session can learn
//!   which ones the listener likes: the seed's YouTube Mix (the platform's
//!   own similarity list), a global "what people play next" graph built from
//!   every account's listening history (plays within 30 minutes after a play
//!   of the seed, counted per distinct listener), the listener's own library
//!   (favorites and history for the seed artist: songs they already love come
//!   back now and then), and plain artist / title searches as a fallback.
//! * Every candidate is scored: source strength and rank, co-listen weight,
//!   artist match, tempo closeness, familiar-vs-new balance for the chosen
//!   mode, minus penalties for songs played in the last two days, songs and
//!   artists the listener skips, duplicates of something already served
//!   ("Official Video" / "Lyrics" / "Remastered" variants are one song), and
//!   non-songs (shorter than a minute, longer than 15 minutes).
//! * Feedback (`/user/radio/next`) moves the station: a skip halves that
//!   artist's weight and dents the source it came from; a completed or liked
//!   track boosts its artist and, once, expands the pool with that track's
//!   own Mix, so the station drifts toward what the listener is enjoying.
//! * Each batch is sequenced so the same artist never plays twice within
//!   three songs and familiar and new songs alternate.
//!
//! Sessions live in `ios_radio_sessions` (pool + learned weights, JSON);
//! they expire after 7 days. `/user/stations/auto` (older app builds) now
//! answers from a fresh session too.

use crate::auth::User;
use crate::error::ApiResult;
use crate::extract::{J, check_range, invalid};
use crate::state::AppState;
use crate::ytdlp::parse_track;
use axum::extract::State;
use axum::routing::post;
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::time::Duration;

pub fn routes() -> Router<AppState> {
    Router::new().route("/user/radio/start", post(start)).route("/user/radio/next", post(next))
}

#[derive(Deserialize, Serialize, Clone, Default, Debug)]
pub struct Seed {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub genre: Option<String>,
    pub bpm: Option<f64>,
    /// YouTube id / "youtube:<id>" / "local:<path>" of the seed song.
    pub source_track_id: Option<String>,
    pub local_hour: Option<i64>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
struct Cand {
    /// YouTube id ("" for library-only songs).
    id: String,
    /// The listener's own library id ("local:..."), when it is their song.
    local: Option<String>,
    title: String,
    artist: String,
    duration: i64,
    thumb: String,
    url: String,
    topic: bool,
    /// Where it came from: mix:<seed id>, colisten, library, search.
    from: String,
    /// Source rank (0 = first) and strength (co-listen count etc.).
    rank: u32,
    strength: f64,
    bpm: Option<f64>,
}

#[derive(Serialize, Deserialize, Default, Debug)]
struct Session {
    seed: Seed,
    mode: String,
    pool: Vec<Cand>,
    /// Song keys (normalized title|artist) already served.
    served: Vec<String>,
    /// Artist keys of the last served songs (spacing).
    recent_artists: Vec<String>,
    artist_w: HashMap<String, f64>,
    source_w: HashMap<String, f64>,
    /// Track ids whose Mix was already added to the pool.
    expanded: Vec<String>,
    /// Served cand by id/local -> (artist key, source), for feedback.
    served_meta: HashMap<String, (String, String)>,
    familiar_served: u32,
    new_served: u32,
}

/// Lowercase, without bracketed tags, "official video", "lyrics", "feat."
/// credits and punctuation: variants of one song share a key.
pub fn song_key(title: &str, artist: &str) -> String {
    let mut t = String::new();
    let mut depth = 0i32;
    for c in title.to_lowercase().chars() {
        match c {
            '(' | '[' | '{' | '【' => depth += 1,
            ')' | ']' | '}' | '】' => depth = (depth - 1).max(0),
            _ if depth == 0 => t.push(c),
            _ => {}
        }
    }
    for junk in ["official music video", "official video", "official audio", "music video", "lyric video", "lyrics", "audio", "hd", "4k", "remastered", "visualizer"] {
        t = t.replace(junk, " ");
    }
    if let Some(i) = t.find(" ft.").or_else(|| t.find(" feat.")).or_else(|| t.find(" ft ")).or_else(|| t.find(" feat ")) {
        t.truncate(i);
    }
    let a = artist_key(artist);
    // "Artist - Title" titles: drop the artist part.
    if let Some((left, right)) = t.split_once(" - ") {
        if artist_key(left) == a || a.is_empty() {
            t = right.to_string();
        }
    }
    let clean: String = t.chars().filter(|c| c.is_alphanumeric() || c.is_whitespace()).collect();
    format!("{}|{a}", clean.split_whitespace().collect::<Vec<_>>().join(" "))
}

pub fn artist_key(a: &str) -> String {
    let a = a.to_lowercase();
    let a = a.trim_end_matches(" - topic").trim_end_matches("vevo").trim_end_matches(" official");
    let first = a.split([',', '&', '×']).next().unwrap_or("");
    let first = first.split(" feat").next().unwrap_or("").split(" ft.").next().unwrap_or("");
    first.chars().filter(|c| c.is_alphanumeric()).collect()
}

fn clean(v: Option<&str>, n: usize) -> String {
    v.map(|s| s.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(n).collect()).unwrap_or_default()
}

fn youtube_id(s: &str) -> Option<String> {
    let s = s.strip_prefix("youtube:").unwrap_or(s);
    let ok = s.len() == 11 && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    ok.then(|| s.to_string())
}

fn cand_from(e: &Value, from: &str, rank: u32) -> Option<Cand> {
    let t = parse_track(e, "youtube");
    let id = t["id"].as_str()?.to_string();
    youtube_id(&id)?;
    Some(Cand {
        id,
        local: None,
        title: t["title"].as_str().unwrap_or("").to_string(),
        artist: t["artist"].as_str().unwrap_or("").to_string(),
        duration: t["duration_seconds"].as_i64().unwrap_or(0),
        thumb: t["thumbnail_url"].as_str().unwrap_or("").to_string(),
        url: t["youtube_url"].as_str().unwrap_or("").to_string(),
        topic: t["is_topic_channel"].as_bool().unwrap_or(false),
        from: from.to_string(),
        rank,
        strength: 1.0,
        bpm: None,
    })
}

async fn ytdlp(st: &AppState, user: &str, target: String, limit: u32) -> Vec<Value> {
    let mut a: Vec<String> = vec![target, "--dump-json".into(), "--flat-playlist".into(), "--playlist-end".into(), limit.to_string(), "--cache-dir".into(), st.cfg.ytdlp_cache_dir.clone()];
    a.extend(st.ytdlp.cookie_args(Some(user), false).await);
    st.ytdlp.run_json(&a, Duration::from_secs(40)).await.unwrap_or_else(|e| {
        tracing::warn!("radio: yt-dlp failed: {e:?}");
        vec![]
    })
}

/// The seed's YouTube Mix (similar songs), cached for 6 h.
async fn mix(st: &AppState, user: &str, vid: &str) -> Vec<Cand> {
    let key = format!("radio_mix:{vid}");
    let entries = if let Some(v) = st.search_cache.get(&key) {
        v.as_array().cloned().unwrap_or_default()
    } else {
        let e = ytdlp(st, user, format!("https://www.youtube.com/watch?v={vid}&list=RD{vid}"), 45).await;
        if !e.is_empty() {
            st.search_cache.set_ttl(key, Value::Array(e.clone()), Duration::from_secs(6 * 3600));
        }
        e
    };
    entries.iter().enumerate().filter_map(|(i, e)| cand_from(e, &format!("mix:{vid}"), i as u32)).filter(|c| c.id != vid).collect()
}

async fn search(st: &AppState, user: &str, q: &str, n: u32, from: &str) -> Vec<Cand> {
    let key = format!("radio_search:{q}:{n}");
    let entries = if let Some(v) = st.search_cache.get(&key) {
        v.as_array().cloned().unwrap_or_default()
    } else {
        let e = ytdlp(st, user, format!("ytsearch{n}:{q}"), n).await;
        if !e.is_empty() {
            st.search_cache.set_ttl(key, Value::Array(e.clone()), Duration::from_secs(6 * 3600));
        }
        e
    };
    entries.iter().enumerate().filter_map(|(i, e)| cand_from(e, from, i as u32)).collect()
}

/// Global co-listen: what listeners played within 30 minutes after a play of
/// the seed (by title + artist, or the same YouTube id), across all accounts.
async fn colisten(st: &AppState, seed_title: &str, seed_artist: &str, seed_vid: Option<&str>) -> Vec<Cand> {
    let rows: Vec<(String, String, Option<String>, i64, i64)> = sqlx::query_as(
        "WITH seeds AS ( \
            SELECT user_id, played_at FROM ios_play_history \
            WHERE (lower(title) = lower($1) AND lower(coalesce(artist,'')) = lower($2)) OR ($3::text IS NOT NULL AND local_song_id = $3) \
         ), nexts AS ( \
            SELECT h.user_id, h.title, coalesce(h.artist,'') AS artist, h.local_song_id, h.track_url \
            FROM seeds s JOIN ios_play_history h ON h.user_id = s.user_id \
             AND h.played_at > s.played_at AND h.played_at < s.played_at + INTERVAL '30 minutes' \
            WHERE NOT (lower(h.title) = lower($1) AND lower(coalesce(h.artist,'')) = lower($2)) \
         ) \
         SELECT title, artist, max(CASE WHEN local_song_id ~ '^[A-Za-z0-9_-]{11}$' THEN local_song_id END), \
                count(DISTINCT user_id)::bigint, count(*)::bigint \
         FROM nexts GROUP BY lower(title), lower(artist), title, artist ORDER BY 4 DESC, 5 DESC LIMIT 40",
    )
    .bind(seed_title)
    .bind(seed_artist)
    .bind(seed_vid)
    .fetch_all(&st.db)
    .await
    .unwrap_or_else(|e| {
        tracing::warn!("radio colisten: {e}");
        vec![]
    });
    rows.into_iter()
        .enumerate()
        .map(|(i, (title, artist, vid, users, plays))| Cand {
            id: vid.clone().unwrap_or_default(),
            local: None,
            title,
            artist,
            duration: 0,
            thumb: vid.as_ref().map(|v| format!("https://i.ytimg.com/vi/{v}/hqdefault.jpg")).unwrap_or_default(),
            url: vid.as_ref().map(|v| format!("https://youtube.com/watch?v={v}")).unwrap_or_default(),
            topic: false,
            from: "colisten".into(),
            rank: i as u32,
            strength: users as f64 * 2.0 + (plays as f64).ln_1p(),
            bpm: None,
        })
        .collect()
}

/// The listener's own songs by the seed artist (favorites first, then
/// history), as library items the app plays from its library.
async fn library(st: &AppState, user: &str, artist: &str) -> Vec<Cand> {
    if artist.is_empty() {
        return vec![];
    }
    let rows: Vec<(String, String, String, f64)> = sqlx::query_as(
        "SELECT song_id, coalesce(title,''), coalesce(artist,''), 2.0::float8 FROM ios_user_favorites \
           WHERE user_id = $1 AND lower(artist) = lower($2) \
         UNION ALL \
         SELECT DISTINCT ON (local_song_id) local_song_id, title, coalesce(artist,''), 1.0::float8 FROM ios_play_history \
           WHERE user_id = $1 AND lower(artist) = lower($2) AND local_song_id IS NOT NULL AND listen_seconds >= 30 \
         LIMIT 60",
    )
    .bind(user)
    .bind(artist)
    .fetch_all(&st.db)
    .await
    .unwrap_or_default();
    let mut seen = HashSet::new();
    rows.into_iter()
        .filter(|r| seen.insert(r.0.clone()) && !r.1.is_empty())
        .enumerate()
        .map(|(i, (sid, title, artist, w))| {
            let vid = youtube_id(&sid);
            Cand {
                id: vid.clone().unwrap_or_default(),
                local: if vid.is_none() { Some(sid) } else { None },
                title,
                artist,
                duration: 0,
                thumb: vid.as_ref().map(|v| format!("https://i.ytimg.com/vi/{v}/hqdefault.jpg")).unwrap_or_default(),
                url: vid.as_ref().map(|v| format!("https://youtube.com/watch?v={v}")).unwrap_or_default(),
                topic: false,
                from: "library".into(),
                rank: i as u32,
                strength: w,
                bpm: None,
            }
        })
        .collect()
}

struct Context {
    played_recent: HashSet<String>,
    skipped: HashMap<String, f64>,
    known: HashSet<String>,
}

async fn context(st: &AppState, user: &str) -> Context {
    let recent: Vec<(String, String)> = sqlx::query_as("SELECT title, coalesce(artist,'') FROM ios_play_history WHERE user_id = $1 AND played_at > NOW() - INTERVAL '2 days'")
        .bind(user)
        .fetch_all(&st.db)
        .await
        .unwrap_or_default();
    let skipped: Vec<(String, i32)> = sqlx::query_as("SELECT song_id, count FROM ios_user_skip_history WHERE user_id = $1 AND count > 0")
        .bind(user)
        .fetch_all(&st.db)
        .await
        .unwrap_or_default();
    let known: Vec<String> = sqlx::query_scalar("SELECT song_id FROM ios_user_favorites WHERE user_id = $1 UNION SELECT source_id FROM ios_user_library_inventory WHERE user_id = $1")
        .bind(user)
        .fetch_all(&st.db)
        .await
        .unwrap_or_default();
    Context {
        played_recent: recent.iter().map(|(t, a)| song_key(t, a)).collect(),
        skipped: skipped.into_iter().map(|(s, c)| (s.strip_prefix("youtube:").unwrap_or(&s).to_string(), c as f64)).collect(),
        known: known.into_iter().map(|s| s.strip_prefix("youtube:").unwrap_or(&s).to_string()).collect(),
    }
}

fn source_base(from: &str) -> &str {
    from.split(':').next().unwrap_or(from)
}

fn score(c: &Cand, s: &Session, ctx: &Context, seed_artist: &str) -> f64 {
    let base = match source_base(&c.from) {
        "mix" => 1.0 / (1.0 + c.rank as f64 / 12.0),
        "colisten" => 0.6 + 0.25 * c.strength.min(6.0),
        "library" => 0.55 + 0.1 * c.strength,
        _ => 0.45 / (1.0 + c.rank as f64 / 6.0),
    };
    let ak = artist_key(&c.artist);
    let mut v = base * s.source_w.get(&c.from).copied().unwrap_or(1.0) * s.source_w.get(source_base(&c.from)).copied().unwrap_or(1.0);
    v *= s.artist_w.get(&ak).copied().unwrap_or(1.0);
    if !seed_artist.is_empty() && ak == seed_artist {
        // Some of the seed artist, not a whole station of them.
        v *= 1.15;
    }
    if let (Some(a), Some(b)) = (s.seed.bpm, c.bpm) {
        let r = (a.max(b) / a.min(b).max(1.0)).log2().abs();
        let r = r.min((r - 1.0).abs());
        v *= 1.0 - (r * 2.0).min(0.3);
    }
    let familiar = c.local.is_some() || ctx.known.contains(&c.id);
    let want_familiar = match s.mode.as_str() {
        "familiar" => 0.55,
        "discover" => 0.1,
        _ => 0.3,
    };
    let served = (s.familiar_served + s.new_served).max(1) as f64;
    let share = s.familiar_served as f64 / served;
    if familiar {
        v *= if share < want_familiar { 1.1 } else { 0.65 };
    } else if share > want_familiar {
        v *= 1.1;
    }
    if ctx.played_recent.contains(&song_key(&c.title, &c.artist)) {
        v *= 0.25;
    }
    let skips = ctx.skipped.get(&c.id).or_else(|| c.local.as_ref().and_then(|l| ctx.skipped.get(l))).copied().unwrap_or(0.0);
    if skips > 0.0 {
        v *= 0.5f64.powf(skips.min(4.0));
    }
    if c.duration > 0 && (c.duration < 60 || c.duration > 900) {
        v *= 0.05;
    }
    let tl = c.title.to_lowercase();
    if ["full album", "playlist", "1 hour", "10 hours", "compilation", "reaction", "tutorial", "interview"].iter().any(|w| tl.contains(w)) {
        v *= 0.05;
    }
    v
}

/// Pick `n` songs from the pool: best score first, the same artist never
/// within 3 songs, no song twice.
fn pick(s: &mut Session, ctx: &Context, n: usize) -> Vec<Cand> {
    let seed_artist = artist_key(s.seed.artist.as_deref().unwrap_or(""));
    let mut served: HashSet<String> = s.served.iter().cloned().collect();
    let mut out = Vec::new();
    for _ in 0..n {
        let mut best: Option<(usize, f64)> = None;
        for (i, c) in s.pool.iter().enumerate() {
            let key = song_key(&c.title, &c.artist);
            if served.contains(&key) {
                continue;
            }
            let ak = artist_key(&c.artist);
            let mut v = score(c, s, ctx, &seed_artist);
            // Graded spacing: the last artist is all but ruled out, two and
            // three songs back weigh less (so a small pool still alternates).
            for (back, a) in s.recent_artists.iter().rev().take(3).enumerate() {
                if *a == ak {
                    v *= [0.01, 0.1, 0.3][back];
                }
            }
            if best.is_none_or(|b| v > b.1) {
                best = Some((i, v));
            }
        }
        let Some((i, v)) = best else { break };
        if v <= 0.0 {
            break;
        }
        let c = s.pool.remove(i);
        let key = song_key(&c.title, &c.artist);
        served.insert(key.clone());
        s.served.push(key);
        let ak = artist_key(&c.artist);
        s.recent_artists.push(ak.clone());
        if s.recent_artists.len() > 12 {
            s.recent_artists.remove(0);
        }
        if c.local.is_some() || ctx.known.contains(&c.id) {
            s.familiar_served += 1;
        } else {
            s.new_served += 1;
        }
        s.served_meta.insert(c.local.clone().unwrap_or_else(|| c.id.clone()), (ak, c.from.clone()));
        out.push(c);
    }
    out
}

fn add_pool(s: &mut Session, cands: Vec<Cand>) {
    let mut have: HashSet<String> = s.pool.iter().map(|c| song_key(&c.title, &c.artist)).collect();
    have.extend(s.served.iter().cloned());
    for c in cands {
        if c.id.is_empty() && c.local.is_none() {
            // Co-listen rows from another listener's local files: resolve by search when picked.
            if c.from != "colisten" {
                continue;
            }
        }
        if have.insert(song_key(&c.title, &c.artist)) {
            s.pool.push(c);
        }
    }
}

fn track_json(c: &Cand) -> Value {
    json!({
        "id": c.id,
        "title": c.title,
        "artist": c.artist,
        "duration_seconds": c.duration,
        "thumbnail_url": c.thumb,
        "source": "youtube",
        "youtube_url": c.url,
        "is_topic_channel": c.topic,
        "local_song_id": c.local,
        "radio_source": source_base(&c.from),
    })
}

/// Co-listen picks that are only another listener's local file: find them on YouTube.
async fn resolve_unplayable(st: &AppState, user: &str, picks: &mut [Cand]) {
    let jobs = picks.iter().enumerate().filter(|(_, c)| c.id.is_empty() && c.local.is_none()).map(|(i, c)| (i, format!("{} {}", c.artist, c.title))).collect::<Vec<_>>();
    let found = futures_util::future::join_all(jobs.iter().map(|(_, q)| search(st, user, q, 1, "colisten"))).await;
    for ((i, _), f) in jobs.iter().zip(found) {
        if let Some(r) = f.into_iter().next() {
            let c = &mut picks[*i];
            c.id = r.id;
            c.url = r.url;
            c.thumb = r.thumb;
            c.duration = r.duration;
            c.topic = r.topic;
        }
    }
}

async fn load(st: &AppState, user: &str, id: &str) -> Option<Session> {
    let v: Option<Value> = sqlx::query_scalar("SELECT state FROM ios_radio_sessions WHERE id = $1 AND user_id = $2").bind(id).bind(user).fetch_optional(&st.db).await.ok().flatten();
    v.and_then(|v| serde_json::from_value(v).ok())
}

async fn save(st: &AppState, user: &str, id: &str, s: &Session) {
    let v = serde_json::to_value(s).unwrap_or(Value::Null);
    let r = sqlx::query(
        "INSERT INTO ios_radio_sessions (id, user_id, seed, state, created_at, updated_at) VALUES ($1, $2, $3, $4, NOW(), NOW()) \
         ON CONFLICT (id) DO UPDATE SET state = EXCLUDED.state, updated_at = NOW()",
    )
    .bind(id)
    .bind(user)
    .bind(serde_json::to_value(&s.seed).unwrap_or(Value::Null))
    .bind(v)
    .execute(&st.db)
    .await;
    if let Err(e) = r {
        tracing::warn!("radio session save: {e}");
    }
}

#[derive(Deserialize)]
struct StartReq {
    #[serde(flatten)]
    seed: Seed,
    mode: Option<String>,
    count: Option<i64>,
}

/// Build a session from a seed: gather all sources in parallel.
pub async fn start_session(st: &AppState, user: &str, seed: Seed, mode: &str, count: usize) -> (String, Value) {
    let title = clean(seed.title.as_deref(), 150);
    let artist = clean(seed.artist.as_deref(), 100);
    let mut seed = seed;
    seed.title = (!title.is_empty()).then(|| title.clone());
    seed.artist = (!artist.is_empty()).then(|| artist.clone());
    let src = seed.source_track_id.clone().unwrap_or_default();
    let mut vid = youtube_id(&src);
    let local_seed = src.starts_with("local:").then(|| src.clone());
    let q = format!("{artist} {title}").trim().to_string();
    if vid.is_none() && !q.is_empty() {
        vid = search(st, user, &q, 1, "search").await.into_iter().next().map(|c| c.id);
    }
    let (m, co, lib, more) = tokio::join!(
        async {
            match &vid {
                Some(v) => mix(st, user, v).await,
                None => vec![],
            }
        },
        colisten(st, &title, &artist, vid.as_deref().or(local_seed.as_deref())),
        library(st, user, &artist),
        async {
            if artist.is_empty() {
                vec![]
            } else {
                search(st, user, &format!("{artist} radio similar artists"), 10, "search").await
            }
        },
    );
    let mut s = Session { seed: seed.clone(), mode: mode.to_string(), ..Default::default() };
    if let Some(v) = &vid {
        s.expanded.push(v.clone());
        // The seed itself is never served back.
        s.served.push(song_key(&title, &artist));
    }
    let sources = json!({"mix": m.len(), "colisten": co.len(), "library": lib.len(), "search": more.len()});
    add_pool(&mut s, m);
    add_pool(&mut s, co);
    add_pool(&mut s, lib);
    add_pool(&mut s, more);
    let ctx = context(st, user).await;
    let mut picks = pick(&mut s, &ctx, count);
    resolve_unplayable(st, user, &mut picks).await;
    let id = uuid::Uuid::new_v4().to_string();
    save(st, user, &id, &s).await;
    let shown = if !title.is_empty() { title.clone() } else { artist.clone() };
    let resp = json!({
        "session_id": id,
        "id": "radio",
        "title": if shown.is_empty() { "Lumisound Radio".to_string() } else { format!("{shown} Radio") },
        "subtitle": if artist.is_empty() { Value::Null } else { json!(format!("Songs like {shown}, tuned as you listen")) },
        "icon": "dot.radiowaves.left.and.right",
        "mode": mode,
        "sources": sources,
        "tracks": picks.iter().filter(|c| !c.id.is_empty() || c.local.is_some()).map(track_json).collect::<Vec<_>>(),
    });
    (id, resp)
}

async fn start(State(st): State<AppState>, u: User, J(b): J<StartReq>) -> ApiResult<Json<Value>> {
    let count = b.count.unwrap_or(8);
    check_range("count", count, 1, 25)?;
    let mode = b.mode.as_deref().unwrap_or("balanced");
    if !["balanced", "familiar", "discover"].contains(&mode) {
        return Err(invalid("mode", "Input should be 'balanced', 'familiar' or 'discover'"));
    }
    let _ = sqlx::query("DELETE FROM ios_radio_sessions WHERE updated_at < NOW() - INTERVAL '7 days'").execute(&st.db).await;
    let (_, resp) = start_session(&st, &u.id, b.seed, mode, count as usize).await;
    Ok(Json(resp))
}

#[derive(Deserialize, Clone)]
struct Feedback {
    /// YouTube id or local id of a served track.
    track_id: String,
    /// played | completed | skipped | liked | disliked
    event: String,
    /// Seconds listened (skips under 30 s weigh most).
    #[serde(default)]
    listened: Option<f64>,
}

#[derive(Deserialize)]
struct NextReq {
    session_id: String,
    #[serde(default)]
    feedback: Vec<Feedback>,
    count: Option<i64>,
}

async fn next(State(st): State<AppState>, u: User, J(b): J<NextReq>) -> ApiResult<Json<Value>> {
    let count = b.count.unwrap_or(5);
    check_range("count", count, 1, 25)?;
    let Some(mut s) = load(&st, &u.id, &b.session_id).await else {
        return Err(invalid("session_id", "Unknown or expired radio session"));
    };
    let mut expand: Vec<String> = Vec::new();
    for f in &b.feedback {
        let Some((ak, from)) = s.served_meta.get(&f.track_id).cloned() else { continue };
        let early = f.listened.is_some_and(|l| l < 30.0);
        let (aw, sw) = match f.event.as_str() {
            "skipped" if early => (0.5, 0.85),
            "skipped" => (0.75, 0.93),
            "disliked" => (0.2, 0.7),
            "completed" => (1.15, 1.05),
            "liked" => (1.4, 1.12),
            _ => (1.0, 1.0),
        };
        *s.artist_w.entry(ak).or_insert(1.0) *= aw;
        *s.source_w.entry(from.clone()).or_insert(1.0) *= sw;
        for v in s.artist_w.values_mut() {
            *v = v.clamp(0.05, 3.0);
        }
        if matches!(f.event.as_str(), "completed" | "liked") {
            if let Some(v) = youtube_id(&f.track_id).filter(|v| !s.expanded.contains(v)) {
                expand.push(v);
            }
        }
    }
    // Follow up to two liked/completed songs into their own Mix (the drift).
    let user = u.id.clone();
    let extra = futures_util::future::join_all(expand.iter().take(2).map(|v| mix(&st, &user, v))).await;
    for (v, cands) in expand.iter().take(2).zip(extra) {
        s.expanded.push(v.clone());
        add_pool(&mut s, cands.into_iter().map(|mut c| {
            // Second-hand similarity counts a bit less than the seed's own.
            c.rank += 6;
            c
        }).collect());
    }
    // Running low: widen with the strongest artists heard so far.
    if s.pool.len() < (count as usize) * 3 {
        let mut top: Vec<(&String, &f64)> = s.artist_w.iter().filter(|(_, w)| **w >= 1.0).collect();
        top.sort_by(|a, b| b.1.total_cmp(a.1));
        let q = top.first().map(|(a, _)| a.to_string()).or(s.seed.artist.clone()).unwrap_or_default();
        if !q.is_empty() {
            let more = search(&st, &user, &format!("{q} mix"), 12, "search").await;
            add_pool(&mut s, more);
        }
    }
    let ctx = context(&st, &u.id).await;
    let mut picks = pick(&mut s, &ctx, count as usize);
    resolve_unplayable(&st, &u.id, &mut picks).await;
    save(&st, &u.id, &b.session_id, &s).await;
    Ok(Json(json!({
        "session_id": b.session_id,
        "tracks": picks.iter().filter(|c| !c.id.is_empty() || c.local.is_some()).map(track_json).collect::<Vec<_>>(),
        "pool_left": s.pool.len(),
    })))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn song_keys_merge_variants() {
        let a = song_key("Lana Del Rey - Margaret (Official Audio) ft. Bleachers", "Lana Del Rey");
        let b = song_key("Margaret", "Lana Del Rey - Topic");
        let c = song_key("Margaret [Lyrics]", "LanaDelReyVEVO");
        assert_eq!(a, b);
        assert_eq!(b, c);
        assert_ne!(song_key("Margaret", "Lana Del Rey"), song_key("Margaret", "Someone Else"));
    }

    fn cand(id: &str, title: &str, artist: &str, from: &str, rank: u32) -> Cand {
        Cand { id: id.into(), local: None, title: title.into(), artist: artist.into(), duration: 200, thumb: String::new(), url: String::new(), topic: false, from: from.into(), rank, strength: 1.0, bpm: None }
    }

    fn ctx() -> Context {
        Context { played_recent: HashSet::new(), skipped: HashMap::new(), known: HashSet::new() }
    }

    #[test]
    fn spacing_and_no_repeats() {
        let mut s = Session { mode: "balanced".into(), ..Default::default() };
        let mut v = vec![];
        for i in 0..6 {
            v.push(cand(&format!("aaaaaaaaaa{i}"), &format!("A song {i}"), "Artist A", "mix:x", i));
        }
        for i in 0..6 {
            v.push(cand(&format!("bbbbbbbbbb{i}"), &format!("B song {i}"), "Artist B", "mix:x", 20 + i));
        }
        v.push(cand("aaaaaaaaaa0", "A song 0 (Official Video)", "Artist A", "search", 0));
        add_pool(&mut s, v);
        let picks = pick(&mut s, &ctx(), 8);
        let artists: Vec<String> = picks.iter().map(|c| c.artist.clone()).collect();
        for w in artists.windows(2) {
            assert_ne!(w[0], w[1], "same artist back to back: {artists:?}");
        }
        let keys: HashSet<String> = picks.iter().map(|c| song_key(&c.title, &c.artist)).collect();
        assert_eq!(keys.len(), picks.len());
    }

    #[test]
    fn skips_steer_away_from_an_artist() {
        let mut s = Session { mode: "balanced".into(), ..Default::default() };
        let mut v = vec![];
        for i in 0..10 {
            v.push(cand(&format!("aaaaaaaaaa{i}"), &format!("A {i}"), "Artist A", "mix:x", i));
            v.push(cand(&format!("cccccccccc{i}"), &format!("C {i}"), "Artist C", "mix:x", i + 1));
            v.push(cand(&format!("dddddddddd{i}"), &format!("D {i}"), "Artist D", "mix:x", i + 2));
            v.push(cand(&format!("ffffffffff{i}"), &format!("F {i}"), "Artist F", "mix:x", i + 3));
        }
        add_pool(&mut s, v);
        s.artist_w.insert(artist_key("Artist A"), 0.1);
        let picks = pick(&mut s, &ctx(), 4);
        let a = picks.iter().filter(|c| c.artist == "Artist A").count();
        assert_eq!(a, 0, "skipped artist still picked {a}x");
    }

    #[test]
    fn non_songs_sink() {
        let mut s = Session { mode: "balanced".into(), ..Default::default() };
        let mut long = cand("dddddddddd1", "Best of 10 hours", "X", "mix:x", 0);
        long.duration = 36000;
        add_pool(&mut s, vec![long, cand("eeeeeeeeee1", "Real song", "Y", "mix:x", 5)]);
        let p = pick(&mut s, &ctx(), 1);
        assert_eq!(p[0].title, "Real song");
    }
}
