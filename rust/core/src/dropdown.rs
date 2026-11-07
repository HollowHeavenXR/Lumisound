//! Lumisound's dropdown engine (replaces the system menus/pickers): option
//! state, search with ranked matches, keyboard / type-ahead navigation and
//! the popover layout. SwiftUI only draws what this computes.

use std::sync::Mutex;

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct DropdownOption {
    pub id: String,
    pub label: String,
    /// Secondary text (shown smaller, also searched).
    pub detail: Option<String>,
    pub enabled: bool,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct DropdownRow {
    pub id: String,
    pub label: String,
    pub detail: Option<String>,
    pub enabled: bool,
    pub selected: bool,
    pub highlighted: bool,
    /// Matched character ranges in `label` (char offsets, [start, end)).
    pub matches: Vec<MatchRange>,
}

#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq)]
pub struct MatchRange {
    pub start: u32,
    pub end: u32,
}

#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq)]
pub struct DropRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct DropdownLayout {
    /// The panel's frame in the same coordinate space as the inputs.
    pub frame: DropRect,
    pub opens_up: bool,
    /// Rows shown without scrolling.
    pub visible_rows: u32,
    /// Row index to scroll to so the selection is in view (None = top).
    pub scroll_to: Option<u32>,
    pub show_search: bool,
}

struct State {
    options: Vec<DropdownOption>,
    selected: Option<String>,
    query: String,
    highlighted: Option<String>,
    open: bool,
}

/// One dropdown's state machine.
#[derive(uniffi::Object)]
pub struct DropdownEngine {
    st: Mutex<State>,
}

/// Searching kicks in for lists longer than this.
const SEARCH_THRESHOLD: usize = 8;
const MARGIN: f64 = 8.0;
const GAP: f64 = 6.0;

fn lower(s: &str) -> Vec<char> {
    s.chars().flat_map(|c| c.to_lowercase()).collect()
}

/// Score (higher = better) and the matched range, or None.
fn rank(label: &str, detail: Option<&str>, q: &[char]) -> Option<(u32, Option<MatchRange>)> {
    if q.is_empty() {
        return Some((0, None));
    }
    let l = lower(label);
    let find = |hay: &[char]| -> Option<usize> { (0..=hay.len().checked_sub(q.len())?).find(|&i| hay[i..i + q.len()] == *q) };
    if let Some(i) = find(&l) {
        let r = Some(MatchRange { start: i as u32, end: (i + q.len()) as u32 });
        let word_start = i == 0 || !l[i - 1].is_alphanumeric();
        return Some((if i == 0 { 300 } else if word_start { 200 } else { 100 }, r));
    }
    // Initials ("lm" matches "Liquid Mono").
    let initials: Vec<char> = label.split(|c: char| !c.is_alphanumeric()).filter_map(|w| w.chars().next()).flat_map(|c| c.to_lowercase()).collect();
    if initials.len() >= q.len() && initials.windows(q.len()).any(|w| w == q) {
        return Some((80, None));
    }
    if detail.is_some_and(|d| find(&lower(d)).is_some()) {
        return Some((50, None));
    }
    None
}

impl State {
    fn visible(&self) -> Vec<(usize, u32, Option<MatchRange>)> {
        let q = lower(self.query.trim());
        let mut v: Vec<(usize, u32, Option<MatchRange>)> = self.options.iter().enumerate().filter_map(|(i, o)| rank(&o.label, o.detail.as_deref(), &q).map(|(s, r)| (i, s, r))).collect();
        if !q.is_empty() {
            // Best matches first; ties keep the original order.
            v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        }
        v
    }
}

#[uniffi::export]
impl DropdownEngine {
    #[uniffi::constructor]
    pub fn new() -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self { st: Mutex::new(State { options: vec![], selected: None, query: String::new(), highlighted: None, open: false }) })
    }

    pub fn set_options(&self, options: Vec<DropdownOption>) {
        let mut s = self.st.lock().unwrap();
        s.options = options;
        if s.highlighted.as_ref().is_some_and(|h| !s.options.iter().any(|o| &o.id == h)) {
            s.highlighted = None;
        }
    }

    pub fn set_selected(&self, id: Option<String>) {
        self.st.lock().unwrap().selected = id;
    }

    pub fn selected(&self) -> Option<String> {
        self.st.lock().unwrap().selected.clone()
    }

    /// Label for the closed control (the selected option's).
    pub fn selected_label(&self) -> Option<String> {
        let s = self.st.lock().unwrap();
        let sel = s.selected.as_ref()?;
        s.options.iter().find(|o| &o.id == sel).map(|o| o.label.clone())
    }

    pub fn open(&self) {
        let mut s = self.st.lock().unwrap();
        s.open = true;
        s.query.clear();
        s.highlighted = s.selected.clone();
    }

    pub fn close(&self) {
        let mut s = self.st.lock().unwrap();
        s.open = false;
        s.query.clear();
    }

    pub fn is_open(&self) -> bool {
        self.st.lock().unwrap().open
    }

    pub fn set_query(&self, query: String) {
        let mut s = self.st.lock().unwrap();
        s.query = query;
        let first = s.visible().into_iter().find(|(i, _, _)| s.options[*i].enabled).map(|(i, _, _)| s.options[i].id.clone());
        s.highlighted = first;
    }

    pub fn rows(&self) -> Vec<DropdownRow> {
        let s = self.st.lock().unwrap();
        s.visible()
            .into_iter()
            .map(|(i, _, r)| {
                let o = &s.options[i];
                DropdownRow {
                    id: o.id.clone(),
                    label: o.label.clone(),
                    detail: o.detail.clone(),
                    enabled: o.enabled,
                    selected: s.selected.as_ref() == Some(&o.id),
                    highlighted: s.highlighted.as_ref() == Some(&o.id),
                    matches: r.into_iter().collect(),
                }
            })
            .collect()
    }

    /// Move the highlight by `delta` rows (skipping disabled), wrapping.
    pub fn move_highlight(&self, delta: i32) -> Option<String> {
        let mut s = self.st.lock().unwrap();
        let rows: Vec<usize> = s.visible().into_iter().map(|(i, _, _)| i).filter(|&i| s.options[i].enabled).collect();
        if rows.is_empty() {
            return None;
        }
        let cur = s.highlighted.as_ref().and_then(|h| rows.iter().position(|&i| &s.options[i].id == h));
        let n = rows.len() as i32;
        let next = match cur {
            Some(p) => ((p as i32 + delta) % n + n) % n,
            None => if delta >= 0 { 0 } else { n - 1 },
        };
        let id = s.options[rows[next as usize]].id.clone();
        s.highlighted = Some(id.clone());
        Some(id)
    }

    /// Type-ahead: highlight the next enabled option whose label starts with `prefix`.
    pub fn typeahead(&self, prefix: String) -> Option<String> {
        let mut s = self.st.lock().unwrap();
        let p = lower(&prefix);
        let start = s.highlighted.as_ref().and_then(|h| s.options.iter().position(|o| &o.id == h)).map_or(0, |i| i + 1);
        let n = s.options.len();
        for k in 0..n {
            let o = &s.options[(start + k) % n];
            if o.enabled && lower(&o.label).starts_with(&p) {
                let id = o.id.clone();
                s.highlighted = Some(id.clone());
                return Some(id);
            }
        }
        None
    }

    /// Choose `id` (or the highlighted row when None). Closes. Returns the
    /// new selection when it changed.
    pub fn choose(&self, id: Option<String>) -> Option<String> {
        let mut s = self.st.lock().unwrap();
        let pick = id.or_else(|| s.highlighted.clone())?;
        if !s.options.iter().any(|o| o.id == pick && o.enabled) {
            return None;
        }
        s.open = false;
        s.query.clear();
        let changed = s.selected.as_ref() != Some(&pick);
        s.selected = Some(pick.clone());
        changed.then_some(pick)
    }

    /// Where to draw the panel: below the anchor when it fits, else above
    /// (whichever side has more room), clamped inside `viewport` minus the
    /// safe `insets` (top, bottom), at least as wide as the anchor.
    pub fn layout(&self, anchor: DropRect, viewport: DropRect, inset_top: f64, inset_bottom: f64, row_height: f64, max_rows: u32, min_width: f64) -> DropdownLayout {
        let s = self.st.lock().unwrap();
        let rows = s.visible().len().max(1);
        let show_search = s.options.len() > SEARCH_THRESHOLD;
        let header = if show_search { row_height + 8.0 } else { 0.0 };
        let wanted_rows = rows.min(max_rows.max(1) as usize);
        let top_limit = viewport.y + inset_top + MARGIN;
        let bottom_limit = viewport.y + viewport.height - inset_bottom - MARGIN;
        let below = bottom_limit - (anchor.y + anchor.height + GAP);
        let above = (anchor.y - GAP) - top_limit;
        let need = header + wanted_rows as f64 * row_height + 8.0;
        let opens_up = need > below && above > below;
        let room = if opens_up { above } else { below }.max(row_height + header + 8.0);
        let fit_rows = (((room - header - 8.0) / row_height).floor() as usize).clamp(1, wanted_rows);
        let height = header + fit_rows as f64 * row_height + 8.0;
        let width = anchor.width.max(min_width).min(viewport.width - 2.0 * MARGIN);
        let x = anchor.x.min(viewport.x + viewport.width - MARGIN - width).max(viewport.x + MARGIN);
        let y = if opens_up { (anchor.y - GAP - height).max(top_limit) } else { (anchor.y + anchor.height + GAP).min(bottom_limit - height) };
        let scroll_to = s.selected.as_ref().and_then(|sel| s.visible().iter().position(|(i, _, _)| &s.options[*i].id == sel)).filter(|&p| p >= fit_rows).map(|p| p as u32);
        DropdownLayout { frame: DropRect { x, y, width, height }, opens_up, visible_rows: fit_rows as u32, scroll_to, show_search }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts(labels: &[&str]) -> Vec<DropdownOption> {
        labels.iter().enumerate().map(|(i, l)| DropdownOption { id: i.to_string(), label: l.to_string(), detail: None, enabled: true }).collect()
    }

    #[test]
    fn search_ranks_and_highlights() {
        let e = DropdownEngine::new();
        e.set_options(opts(&["Medium Hall", "Large Hall", "Hall of Fame", "Small Room", "Liquid Mono"]));
        e.set_query("hall".into());
        let r = e.rows();
        assert_eq!(r.iter().map(|x| x.label.as_str()).collect::<Vec<_>>(), vec!["Hall of Fame", "Medium Hall", "Large Hall"]);
        assert_eq!(r[0].matches, vec![MatchRange { start: 0, end: 4 }]);
        assert!(r[0].highlighted);
        e.set_query("lm".into());
        assert_eq!(e.rows()[0].label, "Liquid Mono", "initials match");
    }

    #[test]
    fn keyboard_typeahead_and_choose() {
        let e = DropdownEngine::new();
        let mut o = opts(&["Alpha", "Bravo", "Charlie", "Bravissimo"]);
        o[2].enabled = false;
        e.set_options(o);
        e.set_selected(Some("0".into()));
        e.open();
        assert_eq!(e.move_highlight(1).as_deref(), Some("1"));
        assert_eq!(e.move_highlight(1).as_deref(), Some("3"), "skips disabled");
        assert_eq!(e.move_highlight(1).as_deref(), Some("0"), "wraps");
        assert_eq!(e.typeahead("bra".into()).as_deref(), Some("1"));
        assert_eq!(e.typeahead("bra".into()).as_deref(), Some("3"), "cycles matches");
        assert_eq!(e.choose(None).as_deref(), Some("3"));
        assert!(!e.is_open());
        assert_eq!(e.choose(Some("3".into())), None, "unchanged");
        assert_eq!(e.choose(Some("2".into())), None, "disabled");
        assert_eq!(e.selected_label().as_deref(), Some("Bravissimo"));
    }

    #[test]
    fn layout_flips_and_clamps() {
        let e = DropdownEngine::new();
        e.set_options(opts(&["a", "b", "c", "d", "e", "f"]));
        let vp = DropRect { x: 0.0, y: 0.0, width: 390.0, height: 844.0 };
        let l = e.layout(DropRect { x: 20.0, y: 100.0, width: 150.0, height: 44.0 }, vp, 47.0, 34.0, 44.0, 8, 200.0);
        assert!(!l.opens_up && l.visible_rows == 6 && l.frame.width == 200.0 && l.frame.y > 144.0);
        // Near the bottom: opens upward.
        let l = e.layout(DropRect { x: 300.0, y: 760.0, width: 80.0, height: 44.0 }, vp, 47.0, 34.0, 44.0, 8, 200.0);
        assert!(l.opens_up && l.frame.y + l.frame.height <= 760.0);
        assert!(l.frame.x + l.frame.width <= 390.0 - 8.0, "clamped inside the screen");
        // Long list: capped rows, search shown, selection scrolled into view.
        e.set_options(opts(&["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"]));
        e.set_selected(Some("10".into()));
        let l = e.layout(DropRect { x: 20.0, y: 100.0, width: 150.0, height: 44.0 }, vp, 47.0, 34.0, 44.0, 6, 0.0);
        assert!(l.show_search && l.visible_rows == 6 && l.scroll_to == Some(10));
    }
}
