import SwiftUI

// MARK: - MoodPlaylistsView

struct MoodPlaylistsView: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var moodService: MoodPlaylistService

    // Grid layout: 2 columns
    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header row with Re-analyze button
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mood Playlists")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("Songs sorted by vibe")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                    Button {
                        moodService.libraryManager = library
                        moodService.reanalyze()
                    } label: {
                        HStack(spacing: 6) {
                            if moodService.isAnalyzing {
                                ProgressView()
                                    .tint(AppTheme.dynamicAccent)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(moodService.isAnalyzing ? "Analyzing…" : "Re-analyze")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(AppTheme.dynamicAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(AppTheme.surface, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(moodService.isAnalyzing)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                // Analysis progress indicator
                if moodService.isAnalyzing {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(AppTheme.accentSoft)
                        Text("Analyzing your library…")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AppTheme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .transition(.opacity)
                }

                // Empty state
                if !moodService.isAnalyzing && allBucketsEmpty {
                    emptyStateView
                        .padding(.top, 40)
                } else if !moodService.isAnalyzing {
                    // 2x2 grid of mood cards
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(visibleMoods, id: \.bucket) { info in
                            MoodCard(
                                mood: info,
                                onPlay: {
                                    player.setQueue(info.songs, startIndex: 0, autoplay: true)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .animation(LumiMotion.fade(0.3), value: visibleMoods.map { $0.songs.count })
                }

                Spacer(minLength: 190) // space for mini player bar (80pt) + tab bar (~83pt) + margin
            }
        }
        .background(Color.clear.ignoresSafeArea())
        .onAppear {
            // Trigger analysis on first appearance if no results yet.
            if allBucketsEmpty && !moodService.isAnalyzing {
                moodService.libraryManager = library
                moodService.reanalyze()
            }
        }
    }

    // MARK: - Helpers

    private var allBucketsEmpty: Bool {
        moodService.energeticSongs.isEmpty
        && moodService.chillSongs.isEmpty
        && moodService.focusSongs.isEmpty
        && moodService.sleepSongs.isEmpty
    }

    fileprivate struct MoodInfo: Identifiable {
        let bucket: MoodBucket
        let songs: [Song]

        var id: MoodBucket { bucket }

        var icon: String {
            switch bucket {
            case .energetic: return "bolt.fill"
            case .chill:     return "water.waves"
            case .focus:     return "target"
            case .sleep:     return "moon.fill"
            }
        }

        var gradient: LinearGradient {
            switch bucket {
            case .energetic:
                return LinearGradient(
                    colors: [Color(red: 1.0, green: 0.45, blue: 0.0), Color(red: 0.95, green: 0.15, blue: 0.15)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            case .chill:
                return LinearGradient(
                    colors: [Color(red: 0.0, green: 0.65, blue: 0.9), Color(red: 0.1, green: 0.75, blue: 0.65)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            case .focus:
                return LinearGradient(
                    colors: [Color(red: 0.55, green: 0.2, blue: 0.9), Color(red: 0.8, green: 0.3, blue: 0.8)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            case .sleep:
                return LinearGradient(
                    colors: [Color(red: 0.05, green: 0.1, blue: 0.35), Color(red: 0.1, green: 0.2, blue: 0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
        }
    }

    /// Only returns moods that have at least 1 song.
    private var visibleMoods: [MoodInfo] {
        [
            MoodInfo(bucket: .energetic, songs: moodService.energeticSongs),
            MoodInfo(bucket: .chill,     songs: moodService.chillSongs),
            MoodInfo(bucket: .focus,     songs: moodService.focusSongs),
            MoodInfo(bucket: .sleep,     songs: moodService.sleepSongs)
        ].filter { !$0.songs.isEmpty }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(AppTheme.dynamicAccent)
            Text("No Moods Yet")
                .font(.title3.weight(.bold))
                .foregroundStyle(AppTheme.textPrimary)
            Text("Add music to your library and tap Re-analyze to generate mood playlists.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

// MARK: - MoodCard

private struct MoodCard: View {
    let mood: MoodPlaylistsView.MoodInfo
    let onPlay: () -> Void

    // Expose the nested type through a typealias trick so this private struct can use it.
    typealias MoodInfo = MoodPlaylistsView.MoodInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top: icon + name
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: mood.icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

                Text(mood.bucket.rawValue)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)

                Text("\(mood.songs.count) \(mood.songs.count == 1 ? "song" : "songs")")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)

            Spacer()

            // Bottom: Play button
            Button(action: onPlay) {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("Play")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.white.opacity(0.2), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(mood.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
    }
}

// MARK: - MoodPlaylistsView+MoodInfo exposed for MoodCard
// (MoodInfo is a private struct inside MoodPlaylistsView; expose it via extension for the card)

extension MoodPlaylistsView {
    // Re-export MoodInfo so MoodCard can reference it without duplication.
    // (Done via the typealias inside MoodCard.)
}
