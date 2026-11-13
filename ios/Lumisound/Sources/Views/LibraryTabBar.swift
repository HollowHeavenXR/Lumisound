import SwiftUI
import MediaPlayer

// MARK: - Library header

/// The top of the Library: what's in it at a glance (songs, artists,
/// albums, hours) over a soft accent glow, and the two things people do
/// most from here — shuffle everything, add music.
struct LibraryHeader: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager
    let onAddMusic: () -> Void

    @State private var hours: Int = 0

    private var accent: Color { AppTheme.dynamicAccent }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Library")
                    .font(AppTheme.headlineFont(size: 30))
                    .foregroundStyle(AppTheme.textPrimary)
                HStack(spacing: 10) {
                    stat(library.allSongs.count, "songs")
                    dot
                    stat(library.songsByArtist.count, "artists")
                    dot
                    stat(library.songsByAlbum.count, "albums")
                    if hours > 0 {
                        dot
                        stat(hours, "h")
                    }
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            Button(action: onAddMusic) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 42, height: 42)
                    .adaptiveGlass(in: Circle(), fallback: AppTheme.surface.opacity(0.7))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Add music")
            Button(action: shuffleAll) {
                Image(systemName: "shuffle")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(LinearGradient(colors: [accent, AppTheme.accentSoft], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                    .shadow(color: accent.opacity(0.45), radius: 8, y: 4)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(library.allSongs.isEmpty)
            .accessibilityLabel("Shuffle all songs")
        }
        .background(alignment: .topLeading) {
            // A soft glow behind the title, in the current accent.
            Circle()
                .fill(accent.opacity(0.22))
                .frame(width: 180, height: 180)
                .blur(radius: 60)
                .offset(x: -50, y: -70)
                .allowsHitTesting(false)
        }
        .task(id: library.allSongs.count) {
            let songs = library.allSongs
            hours = await Task.detached(priority: .utility) {
                Int((songs.reduce(0.0) { $0 + ($1.duration.isFinite ? $1.duration : 0) } / 3600).rounded())
            }.value
        }
    }

    private var dot: some View {
        Circle().fill(AppTheme.textSecondary.opacity(0.5)).frame(width: 3, height: 3)
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(n.formatted()).foregroundStyle(AppTheme.textPrimary).monospacedDigit()
            Text(label)
        }
    }

    private func shuffleAll() {
        let songs = library.allSongs.shuffled()
        guard let first = songs.first else { return }
        player.play(song: first, in: songs, uiSource: "library_shuffle_all")
    }
}

// MARK: - Library navigator

/// Every library section in one strip: sections sit as icons, the chosen
/// one opens up to show its name, and the highlight glides between them.
/// Eleven sections fit in about a screen's width instead of three swipes.
struct LibraryTabBar: View {
    @Binding var selectedTab: LibraryTab
    @Namespace private var pillNamespace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LibraryTab.allCases, id: \.self) { tab in
                        let selected = selectedTab == tab
                        Button {
                            withAnimation(LumiMotion.settle) { selectedTab = tab }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: selected ? tab.icon.filledVariant : tab.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                if selected {
                                    Text(tab.rawValue)
                                        .font(.subheadline.weight(.semibold))
                                        .fixedSize()
                                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                                }
                            }
                            .padding(.horizontal, selected ? 16 : 12)
                            .frame(height: 40)
                            .foregroundStyle(selected ? .white : AppTheme.textSecondary)
                            .background {
                                if selected {
                                    Capsule(style: .continuous)
                                        .fill(LinearGradient(colors: [AppTheme.dynamicAccent, AppTheme.accentSoft],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .shadow(color: AppTheme.dynamicAccent.opacity(0.4), radius: 6, x: 0, y: 3)
                                        .matchedGeometryEffect(id: "libraryTabPill", in: pillNamespace)
                                } else {
                                    Capsule(style: .continuous)
                                        .fill(AppTheme.surface.opacity(0.55))
                                        .overlay(Capsule().stroke(AppTheme.textPrimary.opacity(0.06), lineWidth: 1))
                                }
                            }
                            .contentShape(Capsule())
                        }
                        .buttonStyle(PressableButtonStyle())
                        .id(tab)
                        .accessibilityLabel(tab.rawValue)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .accessibilityIdentifier("libraryTab.\(tab.rawValue)")
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: selectedTab) { tab in
                withAnimation(LumiMotion.settle) { proxy.scrollTo(tab, anchor: .center) }
            }
        }
    }
}

private extension String {
    /// "heart" → "heart.fill" for SF Symbols that have a filled form.
    var filledVariant: String {
        if hasSuffix(".fill") { return self }
        switch self {
        case "music.note", "music.mic", "guitars", "music.note.list": return self
        default: return self + ".fill"
        }
    }
}
