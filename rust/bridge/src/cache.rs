//! Small in-process TTL caches.

use dashmap::DashMap;
use std::hash::Hash;
use std::time::{Duration, Instant};

pub struct TtlCache<K, V> {
    map: DashMap<K, (Instant, V)>,
    ttl: Duration,
    max: usize,
}

impl<K: Eq + Hash + Clone, V: Clone> TtlCache<K, V> {
    pub fn new(ttl: Duration, max: usize) -> Self {
        Self { map: DashMap::new(), ttl, max }
    }

    pub fn get(&self, k: &K) -> Option<V> {
        let hit = self.map.get(k).map(|e| (e.0, e.1.clone()));
        match hit {
            Some((expires, v)) if Instant::now() < expires => Some(v),
            Some(_) => {
                self.map.remove(k);
                None
            }
            None => None,
        }
    }

    pub fn set(&self, k: K, v: V) {
        self.set_ttl(k, v, self.ttl);
    }

    pub fn set_ttl(&self, k: K, v: V, ttl: Duration) {
        if self.map.len() >= self.max && !self.map.contains_key(&k) {
            self.evict();
        }
        self.map.insert(k, (Instant::now() + ttl, v));
    }

    pub fn remove(&self, k: &K) {
        self.map.remove(k);
    }

    /// Drop expired entries, then the oldest quarter if still full.
    fn evict(&self) {
        let now = Instant::now();
        self.map.retain(|_, (exp, _)| *exp > now);
        if self.map.len() >= self.max {
            let mut by_age: Vec<(K, Instant)> = self.map.iter().map(|e| (e.key().clone(), e.value().0)).collect();
            by_age.sort_by_key(|(_, t)| *t);
            for (k, _) in by_age.into_iter().take(self.max / 4 + 1) {
                self.map.remove(&k);
            }
        }
    }

    pub fn sweep(&self) {
        let now = Instant::now();
        self.map.retain(|_, (exp, _)| *exp > now);
    }
}
