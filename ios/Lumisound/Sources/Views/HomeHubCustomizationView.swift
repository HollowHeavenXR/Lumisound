import SwiftUI

// MARK: - Home Hub customization
//
// Three device-local personalization knobs for `LibraryHubView`'s dashboard:
// section reordering/visibility, a custom greeting override, and a
// Home-only accent color. All three are plain per-device UI preferences —
// like `tab_transition_style` in `ContentView` — persisted via
// `@AppStorage`/`UserDefaults`, never server-synced. None of this touches
// the profile/social accent system in `Views/Social/ProfileView.swift`;
// it reuses `AccentColorPickerView`/`SocialAccentPalette` purely as UI/color
// components, with entirely separate storage keys.

// MARK: - Zones
//
// The hub grew to ~20 shelves in one flat list, with five single-row teaser
// cards stacked above the first piece of actual music. Zones group those
// shelves by *intent* — what the user came to Home to do — so the default
// order reads as five coherent blocks instead of a feature inventory, and the
// filter chips under the quick actions can narrow Home to one of them.

enum HubZone: String, CaseIterable, Identifiable {
    /// Resume something: recent tracks, pinned collections, a half-heard podcast.
    case jumpBackIn
    /// Picked or generated for the user rather than taken from their own shelves.
    case forYou
    /// Different cuts through the user's own library.
    case library
    /// Things the user liked once and hasn't heard lately.
    case rediscover
    /// Numbers about the user's listening, and other people's.
    case statsAndSocial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jumpBackIn:     return "Jump Back In"
        case .forYou:         return "Made For You"
        case .library:        return "Your Library"
        case .rediscover:     return "Rediscover"
        case .statsAndSocial: return "Stats & Social"
        }
    }

    /// Shorter label for the filter chips.
    var chipTitle: String {
        switch self {
        case .jumpBackIn:     return "Recent"
        case .forYou:         return "For You"
        case .library:        return "Library"
        case .rediscover:     return "Rediscover"
        case .statsAndSocial: return "Social"
        }
    }

    var icon: String {
        switch self {
        case .jumpBackIn:     return "arrow.uturn.backward"
        case .forYou:         return "sparkles"
        case .library:        return "music.note.house"
        case .rediscover:     return "clock.arrow.circlepath"
        case .statsAndSocial: return "person.2"
        }
    }
}

// MARK: - Section identifiers

/// Every reorderable/hideable content shelf in `LibraryHubView.hubContent`
/// — everything except the greeting header and quick-actions row, which are
/// pinned identity/action anchors rather than content shelves and stay fixed
/// at the top always.
enum HubSectionKind: String, CaseIterable, Codable, Identifiable {
    case onThisDay
    case speedDial
    case weeklyMix
    case mixes
    case recentlyAdded
    case onRepeat
    case recentlyPlayed
    case genres
    case forgottenFavorites
    case moods
    case friendsActivity
    case similarListeners
    // 2026-07-20 Home Tab expansion — see `LibraryHubView`'s corresponding
    // `sectionContent`/`sectionHasContent` cases and `LibraryManager+HubContent.swift`
    // for each one's data source.
    case achievements
    case weeklyRecap
    case topArtists
    case decades
    case deeperCuts
    // 2026-08 Podcasts — in-progress episodes across every subscription,
    // same "teaser card, not reorderable-carousel" shape as onThisDay.
    case continueListeningPodcasts
    /// One AI-picked track/day with a short reason — see `/user/aria/daily-pick`.
    case ariaDailyPick
    // 2026-09 Home restructure. `stations` was pinned under the quick
    // actions and could be neither moved nor hidden; `jumpBackIn` is a
    // compact grid of the last few tracks, for one-tap resume.
    case jumpBackIn
    case stations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onThisDay:          return "On This Day"
        case .speedDial:          return "Quick Access"
        case .weeklyMix:          return "Weekly Mix"
        case .mixes:              return "Mixes For You"
        case .recentlyAdded:      return "Recently Added"
        case .onRepeat:           return "On Repeat"
        case .recentlyPlayed:     return "Recently Played"
        case .genres:             return "Genres"
        case .forgottenFavorites: return "Forgotten Favorites"
        case .moods:              return "Moods"
        case .friendsActivity:    return "Friends Activity"
        case .similarListeners:   return "Similar Listeners"
        case .achievements:       return "Streaks & Achievements"
        case .weeklyRecap:        return "This Week"
        case .topArtists:         return "Top Artists"
        case .decades:            return "Decades"
        case .deeperCuts:         return "Deeper Cuts"
        case .continueListeningPodcasts: return "Continue Listening"
        case .ariaDailyPick:      return "Aria's Daily Pick"
        case .jumpBackIn:         return "Jump Back In"
        case .stations:           return "Suggestions"
        }
    }

    /// Matches the icon each section already uses in its own header today —
    /// kept in sync by hand since these live as string literals at each
    /// `HubSectionHeader(...)` call site in `LibraryHubView.swift`.
    var icon: String {
        switch self {
        case .onThisDay:          return "clock.arrow.circlepath"
        case .speedDial:          return "square.grid.2x2.fill"
        case .weeklyMix:          return "sparkles.tv"
        case .mixes:              return "wand.and.stars"
        case .recentlyAdded:      return "clock.badge.checkmark"
        case .onRepeat:           return "flame.fill"
        case .recentlyPlayed:     return "clock.arrow.circlepath"
        case .genres:             return "guitars.fill"
        case .forgottenFavorites: return "heart.slash"
        case .moods:              return "theatermasks.fill"
        case .friendsActivity:    return "person.2.wave.2.fill"
        case .similarListeners:   return "person.3.sequence.fill"
        case .achievements:       return "trophy.fill"
        case .weeklyRecap:        return "chart.bar.fill"
        case .topArtists:         return "music.mic"
        case .decades:            return "hourglass"
        case .deeperCuts:         return "waveform.badge.magnifyingglass"
        case .continueListeningPodcasts: return "headphones"
        case .ariaDailyPick:      return "sparkle"
        case .jumpBackIn:         return "arrow.uturn.backward.circle.fill"
        case .stations:           return "sparkles"
        }
    }

    var zone: HubZone {
        switch self {
        case .jumpBackIn, .speedDial, .recentlyPlayed, .continueListeningPodcasts:
            return .jumpBackIn
        case .ariaDailyPick, .stations, .weeklyMix, .mixes, .similarListeners:
            return .forYou
        case .recentlyAdded, .onRepeat, .topArtists, .genres, .decades, .moods:
            return .library
        case .onThisDay, .forgottenFavorites, .deeperCuts:
            return .rediscover
        case .weeklyRecap, .achievements, .friendsActivity:
            return .statsAndSocial
        }
    }

    /// Zone by zone, in `HubZone.allCases` order: resume first (the most
    /// common reason to open Home is to carry on), then new things picked
    /// for the user, then their own library, then rediscovery, with stats
    /// and social last. A user who has saved their own order keeps it — see
    /// `HomeHubLayoutStore.decodeOrder` — and can adopt this one with
    /// "Reset Layout" in the customization sheet.
    ///
    /// Must list every case: `decodeOrder` reconciles saved orders against it.
    static let defaultOrder: [HubSectionKind] = [
        // Jump Back In
        .jumpBackIn, .continueListeningPodcasts, .speedDial, .recentlyPlayed,
        // Made For You
        .ariaDailyPick, .stations, .weeklyMix, .mixes, .similarListeners,
        // Your Library
        .recentlyAdded, .onRepeat, .topArtists, .moods, .genres, .decades,
        // Rediscover
        .onThisDay, .forgottenFavorites, .deeperCuts,
        // Stats & Social
        .weeklyRecap, .achievements, .friendsActivity,
    ]
}

// MARK: - Persistence

/// JSON-encoded-array-in-`UserDefaults` storage for the hub's order/hidden
/// preferences — the same convention as every other simple per-device list
/// preference in this codebase (see e.g. `BookmarkStore`), just small enough
/// here that a dedicated store type isn't warranted; these are plain static
/// helpers around the two `@AppStorage` string keys used directly by both
/// `LibraryHubView` (to read) and `HomeHubCustomizationView` (to read+write).
enum HomeHubLayoutStore {
    static let orderKey = "home_hub_section_order"
    static let hiddenKey = "home_hub_hidden_sections"

    /// Decodes the persisted order, silently falling back to
    /// `HubSectionKind.defaultOrder` for a first run or corrupted value.
    /// Also reconciles against the current `HubSectionKind` case list both
    /// ways: unknown/stale raw values (e.g. a section removed in a later
    /// update) are dropped, and any *new* case missing from an older saved
    /// order is slotted in right after its nearest default-order predecessor
    /// that the saved order does have. Appending at the end would send a
    /// section that used to be pinned near the top (Suggestions) to the very
    /// bottom for everyone who had ever reordered anything.
    static func decodeOrder(_ json: String) -> [HubSectionKind] {
        var seen = Set<HubSectionKind>()
        var result: [HubSectionKind] = []
        if let data = json.data(using: .utf8),
           let raw = try? JSONDecoder().decode([String].self, from: data) {
            for value in raw {
                guard let kind = HubSectionKind(rawValue: value), seen.insert(kind).inserted else { continue }
                result.append(kind)
            }
        }
        let defaults = HubSectionKind.defaultOrder
        for (index, kind) in defaults.enumerated() where !seen.contains(kind) {
            if let predecessor = defaults[..<index].last(where: { seen.contains($0) }),
               let at = result.firstIndex(of: predecessor) {
                result.insert(kind, at: at + 1)
            } else {
                result.insert(kind, at: 0)
            }
            seen.insert(kind)
        }
        return result
    }

    /// The order Home actually uses: the saved one if the user has ever
    /// reordered, otherwise `defaultOrder(forHour:)`. Only the un-customized
    /// default moves with the clock — a hand-arranged Home never changes
    /// under the user.
    static func resolvedOrder(_ json: String, hour: Int) -> [HubSectionKind] {
        json.isEmpty ? defaultOrder(forHour: hour) : decodeOrder(json)
    }

    /// `HubSectionKind.defaultOrder` nudged for the time of day. Whole zones
    /// move, and sections only move within their zone, so the zone headings
    /// on Home still hold.
    ///   - Morning (5–11): Made For You goes first — start the day with
    ///     something new rather than yesterday's queue.
    ///   - Evening and night (20–4): Moods leads Your Library, where the
    ///     Chill and Sleep buckets are one tap away.
    static func defaultOrder(forHour hour: Int) -> [HubSectionKind] {
        var zones = HubZone.allCases
        var byZone = Dictionary(grouping: HubSectionKind.defaultOrder, by: \.zone)

        switch hour {
        case 5..<12:
            zones.removeAll { $0 == .forYou }
            zones.insert(.forYou, at: 0)
        case 20..<24, 0..<5:
            if var library = byZone[.library], let moods = library.firstIndex(of: .moods) {
                library.insert(library.remove(at: moods), at: 0)
                byZone[.library] = library
            }
        default:
            break
        }
        return zones.flatMap { byZone[$0] ?? [] }
    }

    static func encodeOrder(_ order: [HubSectionKind]) -> String {
        encode(order.map { $0.rawValue })
    }

    static func decodeHidden(_ json: String) -> Set<HubSectionKind> {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(raw.compactMap { HubSectionKind(rawValue: $0) })
    }

    static func encodeHidden(_ hidden: Set<HubSectionKind>) -> String {
        encode(hidden.map { $0.rawValue })
    }

    private static func encode(_ rawValues: [String]) -> String {
        guard let data = try? JSONEncoder().encode(rawValues),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }
}

// MARK: - Customization sheet

/// The hub's "Edit" sheet — reorder/show/hide sections, set a custom
/// greeting, and pick a Home-only accent color. A plain `List` forced into
/// edit mode with `.onMove` rather than hand-rolled drag gestures, since
/// this machine has no local Swift toolchain to compile-test a custom
/// implementation against — `.onMove`/`.environment(\.editMode:)` is a
/// standard, well-trodden SwiftUI pattern that doesn't need that safety net.
struct HomeHubCustomizationView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(HomeHubLayoutStore.orderKey) private var orderRaw: String = ""
    @AppStorage(HomeHubLayoutStore.hiddenKey) private var hiddenRaw: String = ""
    @AppStorage("home_hub_custom_greeting") private var customGreeting: String = ""
    @AppStorage("home_hub_accent_hex") private var accentHex: String?

    @State private var order: [HubSectionKind] = []
    private var currentHour: Int { Calendar.current.component(.hour, from: Date()) }
    @State private var hidden: Set<HubSectionKind> = []

    private var accentColor: Color {
        SocialAccentPalette.color(for: accentHex) ?? AppTheme.dynamicAccent
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("e.g. \"Welcome back\"", text: $customGreeting, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Custom Greeting")
                } footer: {
                    Text("Replaces the automatic \"Good morning/afternoon/evening\" greeting on Home. Clear it to restore the automatic greeting.")
                }

                Section {
                    AccentColorPickerView(title: "Home Accent", selectedHex: $accentHex)
                        .padding(.vertical, 6)
                    if accentHex != nil {
                        Button(role: .destructive) {
                            withAnimation(LumiMotion.snap) {
                                accentHex = nil
                            }
                        } label: {
                            Text("Reset to Default")
                        }
                    }
                } header: {
                    Text("Home Accent Color")
                } footer: {
                    Text("Tints this Home screen's section headers and greeting. Separate from your profile's accent colors and only visible to you.")
                }

                Section {
                    ForEach(order) { kind in
                        HStack(spacing: 12) {
                            Image(systemName: kind.icon)
                                .foregroundStyle(hidden.contains(kind) ? AppTheme.textSecondary : accentColor)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.title)
                                    .foregroundStyle(AppTheme.textPrimary)
                                Text(kind.zone.title)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            .opacity(hidden.contains(kind) ? 0.5 : 1)
                            Spacer()
                            Toggle("Show \(kind.title)", isOn: showBinding(for: kind))
                                .labelsHidden()
                                .tint(accentColor)
                        }
                    }
                    .onMove(perform: move)
                } header: {
                    Text("Sections")
                } footer: {
                    Text("Drag to reorder. Toggle a section off to hide it — it still only ever appears when it actually has content. Group headings show on Home while each group's sections stay together. Until you reorder, Home adjusts the order to the time of day.")
                }

                Section {
                    Button("Reset Layout") {
                        withAnimation(LumiMotion.snap) {
                            order = HomeHubLayoutStore.defaultOrder(forHour: currentHour)
                            hidden = []
                        }
                        orderRaw = ""
                        hiddenRaw = ""
                    }
                    .disabled(orderRaw.isEmpty && hiddenRaw.isEmpty)
                } footer: {
                    Text("Restores the default section order and shows every section again. Your greeting and accent color are kept.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize Home")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(accentColor)
                }
            }
        }
        .onAppear {
            order = HomeHubLayoutStore.resolvedOrder(orderRaw, hour: currentHour)
            hidden = HomeHubLayoutStore.decodeHidden(hiddenRaw)
        }
    }

    private func showBinding(for kind: HubSectionKind) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(kind) },
            set: { isOn in
                if isOn { hidden.remove(kind) } else { hidden.insert(kind) }
                hiddenRaw = HomeHubLayoutStore.encodeHidden(hidden)
            }
        )
    }

    private func move(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
        orderRaw = HomeHubLayoutStore.encodeOrder(order)
    }
}
