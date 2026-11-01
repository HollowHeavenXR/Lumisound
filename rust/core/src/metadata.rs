//! Online metadata lookup for untagged/partly tagged tracks: iTunes Search,
//! then MusicBrainz, then Deezer — first source with results wins, an exact
//! (case-insensitive) title match is preferred over the first hit. Results
//! (including misses) are cached for the process lifetime.

use serde_json::Value;
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

#[derive(uniffi::Record, Clone, Debug)]
pub struct MetaCandidate {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub genre: Option<String>,
    pub year: Option<String>,
    pub artwork_url: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct MetaLookup {
    /// "itunes" | "musicbrainz" | "deezer"
    pub source: String,
    pub candidates: Vec<MetaCandidate>,
    pub best_index: u32,
}

static CACHE: LazyLock<Mutex<HashMap<String, Option<MetaLookup>>>> = LazyLock::new(|| Mutex::new(HashMap::new()));

fn s(v: &Value) -> Option<String> {
    v.as_str().map(str::to_string).filter(|x| !x.is_empty())
}

fn year(v: &Value) -> Option<String> {
    v.as_str().map(|d| d.chars().take(4).collect()).filter(|y: &String| !y.is_empty())
}

fn best(cands: &[MetaCandidate], title: &str) -> u32 {
    cands.iter().position(|c| c.title.as_deref().is_some_and(|t| t.to_lowercase() == title.to_lowercase())).unwrap_or(0) as u32
}

async fn get(url: &str, ua: Option<&str>) -> Option<Value> {
    let mut rq = crate::client::http_client().get(url).timeout(Duration::from_secs(10));
    if let Some(ua) = ua {
        rq = rq.header("User-Agent", ua);
    }
    let r = rq.send().await.ok()?;
    if r.status().as_u16() != 200 {
        return None;
    }
    r.json().await.ok()
}

async fn itunes(q: &str) -> Option<Vec<MetaCandidate>> {
    let url = format!("https://itunes.apple.com/search?term={}&entity=song&limit=3&country=US", urlencoding::encode(q));
    let v = get(&url, None).await?;
    let r = v["results"].as_array()?;
    let c: Vec<MetaCandidate> = r
        .iter()
        .map(|x| {
            let a100 = x["artworkUrl100"].as_str().unwrap_or("");
            let a600 = s(&x["artworkUrl600"]).unwrap_or_else(|| a100.replace("100x100bb", "600x600bb"));
            MetaCandidate { title: s(&x["trackName"]), artist: s(&x["artistName"]), album: s(&x["collectionName"]), genre: s(&x["primaryGenreName"]), year: year(&x["releaseDate"]), artwork_url: (!a600.is_empty()).then_some(a600) }
        })
        .collect();
    (!c.is_empty()).then_some(c)
}

async fn musicbrainz(title: &str, artist: &str) -> Option<Vec<MetaCandidate>> {
    let q = if artist.is_empty() { format!("recording:\"{title}\"") } else { format!("recording:\"{title}\" AND artist:\"{artist}\"") };
    let url = format!("https://musicbrainz.org/ws/2/recording?query={}&limit=3&fmt=json", urlencoding::encode(&q));
    let v = get(&url, Some("Lumisound/1.0 (https://github.com/HollowHeavenXR/Lumisound)")).await?;
    let r = v["recordings"].as_array()?;
    let c: Vec<MetaCandidate> = r
        .iter()
        .map(|x| MetaCandidate {
            title: s(&x["title"]),
            artist: x["artist-credit"].as_array().and_then(|a| a.first()).and_then(|a| s(&a["name"])),
            album: x["releases"].as_array().and_then(|a| a.first()).and_then(|a| s(&a["title"])),
            genre: None,
            year: x["releases"].as_array().and_then(|a| a.first()).and_then(|a| year(&a["date"])),
            artwork_url: None,
        })
        .collect();
    (!c.is_empty()).then_some(c)
}

async fn deezer(q: &str) -> Option<Vec<MetaCandidate>> {
    let url = format!("https://api.deezer.com/search?q={}&limit=3", urlencoding::encode(q));
    let v = get(&url, None).await?;
    let r = v["data"].as_array()?;
    let c: Vec<MetaCandidate> = r
        .iter()
        .map(|x| MetaCandidate {
            title: s(&x["title"]),
            artist: s(&x["artist"]["name"]),
            album: s(&x["album"]["title"]),
            genre: None,
            year: None,
            artwork_url: s(&x["album"]["cover_big"]).or_else(|| s(&x["album"]["cover"])),
        })
        .collect();
    (!c.is_empty()).then_some(c)
}

/// Look a track up online (cached, misses included).
#[uniffi::export]
pub async fn metadata_lookup(title: String, artist: String) -> Option<MetaLookup> {
    let (t, a) = (title.trim().to_string(), artist.trim().to_string());
    if t.is_empty() {
        return None;
    }
    let key = format!("{t}|{a}");
    if let Some(hit) = CACHE.lock().unwrap().get(&key) {
        return hit.clone();
    }
    let res = crate::on_rt(async move {
        let q = [t.as_str(), a.as_str()].iter().filter(|x| !x.is_empty()).copied().collect::<Vec<_>>().join(" ");
        if let Some(c) = itunes(&q).await {
            return Some(MetaLookup { source: "itunes".into(), best_index: best(&c, &t), candidates: c });
        }
        if let Some(c) = musicbrainz(&t, &a).await {
            return Some(MetaLookup { source: "musicbrainz".into(), best_index: best(&c, &t), candidates: c });
        }
        deezer(&q).await.map(|c| MetaLookup { source: "deezer".into(), best_index: best(&c, &t), candidates: c })
    })
    .await;
    CACHE.lock().unwrap().insert(key, res.clone());
    res
}
