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

// ---- artist photos ----------------------------------------------------------------------------

const MB_UA: &str = "Lumisound/1.0 (https://github.com/HollowHeavenXR/Lumisound)";

/// The full credit plus the primary artist before the first feat./&/x/vs.
pub fn artist_candidates(artist: &str) -> Vec<String> {
    let full = artist.trim().to_string();
    let lower = full.to_lowercase();
    let cut = [" feat.", " feat ", " ft.", " ft ", " featuring ", " & ", ", ", " x ", " vs.", " vs "].iter().filter_map(|s| lower.find(s)).min();
    let mut out = vec![full.clone()];
    if let Some(c) = cut {
        let primary = full[..c].trim().to_string();
        if !primary.is_empty() && primary.to_lowercase() != lower {
            out.push(primary);
        }
    }
    out
}

async fn bytes(url: &str) -> Option<Vec<u8>> {
    let r = crate::client::http_client().get(url).timeout(Duration::from_secs(15)).send().await.ok()?;
    if r.status().as_u16() != 200 {
        return None;
    }
    let b = r.bytes().await.ok()?.to_vec();
    (b.len() > 200).then_some(b)
}

async fn deezer_artist(name: &str) -> Option<Vec<u8>> {
    let v = get(&format!("https://api.deezer.com/search/artist?q={}&limit=1", urlencoding::encode(name)), None).await?;
    let first = v["data"].as_array()?.first()?.clone();
    for k in ["picture_xl", "picture_big", "picture_medium"] {
        if let Some(u) = first[k].as_str().filter(|u| !u.is_empty() && !u.contains("artist//")) {
            if let Some(b) = bytes(u).await {
                return Some(b);
            }
        }
    }
    None
}

async fn commons_url(resource: &str) -> Option<String> {
    if !resource.contains("commons.wikimedia.org") {
        return None;
    }
    let file = &resource[resource.find("File:")?..];
    let v = get(&format!("https://commons.wikimedia.org/w/api.php?action=query&titles={}&prop=imageinfo&iiprop=url&iiurlwidth=500&format=json", urlencoding::encode(file)), Some(MB_UA)).await?;
    let page = v["query"]["pages"].as_object()?.values().next()?.clone();
    let info = page["imageinfo"].as_array()?.first()?.clone();
    s(&info["thumburl"]).or_else(|| s(&info["url"]))
}

async fn musicbrainz_artist(name: &str) -> Option<Vec<u8>> {
    let v = get(&format!("https://musicbrainz.org/ws/2/artist/?query=artist:{}&fmt=json&limit=1", urlencoding::encode(name)), Some(MB_UA)).await?;
    let mbid = v["artists"].as_array()?.first()?["id"].as_str()?.to_string();
    let rel = get(&format!("https://musicbrainz.org/ws/2/artist/{mbid}?inc=url-rels&fmt=json"), Some(MB_UA)).await?;
    for r in rel["relations"].as_array()?.iter().filter(|r| r["type"] == "image") {
        let Some(res) = r["url"]["resource"].as_str() else { continue };
        let url = commons_url(res).await.unwrap_or_else(|| res.to_string());
        if let Some(b) = bytes(&url).await {
            return Some(b);
        }
    }
    None
}

/// Artist photo bytes from Deezer, falling back to MusicBrainz → Wikimedia
/// Commons; each tried for the full credit, then the primary artist.
#[uniffi::export]
pub async fn artist_image_fetch(artist: String) -> Option<Vec<u8>> {
    let a = artist.trim().to_string();
    if a.is_empty() || a.eq_ignore_ascii_case("unknown artist") {
        return None;
    }
    crate::on_rt(async move {
        let names = artist_candidates(&a);
        for n in &names {
            if let Some(b) = deezer_artist(n).await {
                return Some(b);
            }
        }
        for n in &names {
            if let Some(b) = musicbrainz_artist(n).await {
                return Some(b);
            }
        }
        None
    })
    .await
}
