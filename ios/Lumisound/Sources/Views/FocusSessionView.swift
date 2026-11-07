import SwiftUI

/// Control screen for `FocusSessionService` — set up a work/break session
/// or watch/cancel one already running. Opened as a sheet from Now
/// Playing's overflow menu, same pattern as `SleepTimerSheet`/
/// `PracticeModeView`.
struct FocusSessionView: View {
    @EnvironmentObject private var library: LibraryManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = FocusSessionService.shared

    @State private var workMinutes = 25
    @State private var breakMinutes = 5
    @State private var rounds = 4
    @State private var source: SongSource = .continueCurrent
    @State private var selectedPlaylistID: UUID?

    private enum SongSource: String, CaseIterable, Identifiable {
        case continueCurrent = "Keep Playing"
        case favorites = "Favorites"
        case playlist = "A Playlist"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            Group {
                if session.isActive {
                    activeSessionView
                } else {
                    setupView
                }
            }
            .navigationTitle("Focus Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Setup

    private var setupView: some View {
        Form {
            Section("Timing") {
                Stepper("Work: \(workMinutes) min", value: $workMinutes, in: 5...90, step: 5)
                Stepper("Break: \(breakMinutes) min", value: $breakMinutes, in: 1...30)
                Stepper("Rounds: \(rounds)", value: $rounds, in: 1...12)
            }

            Section {
                Picker("Source", selection: $source) {
                    ForEach(SongSource.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if source == .playlist {
                    if library.playlists.isEmpty {
                        Text("You don't have any playlists yet.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    } else {
                        LumiPicker("Playlist", selection: $selectedPlaylistID) {
                            Text("Choose one").lumiOptionLabel("Choose one").tag(UUID?.none)
                            ForEach(library.playlists) { playlist in
                                Text(playlist.name).lumiOptionLabel(String(describing: playlist.name)).tag(Optional(playlist.id))
                            }
                        }
                    }
                }
            } header: {
                Text("Soundtrack")
            } footer: {
                Text(source == .continueCurrent
                     ? "Whatever's already playing keeps going through work blocks; breaks still pause."
                     : "Restarts from the top of this source at the beginning of each work block.")
            }

            if session.completedSessions > 0 {
                Section {
                    Label("\(session.completedSessions) session\(session.completedSessions == 1 ? "" : "s") completed", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            Section {
                Button {
                    start()
                } label: {
                    Label("Start Focus Session", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.dynamicAccent)
                .disabled(source == .playlist && selectedPlaylistID == nil)
            }
        }
    }

    private func start() {
        let songs: [Song]
        switch source {
        case .continueCurrent:
            songs = []
        case .favorites:
            songs = library.favoriteSongs
        case .playlist:
            guard let selectedPlaylistID, let playlist = library.playlists.first(where: { $0.id == selectedPlaylistID }) else {
                songs = []
                break
            }
            songs = library.songs(for: playlist)
        }
        session.start(workMinutes: workMinutes, breakMinutes: breakMinutes, rounds: rounds, songs: songs)
    }

    // MARK: - Active

    private var activeSessionView: some View {
        VStack(spacing: 24) {
            Spacer()

            Text(phaseLabel)
                .font(.title2.weight(.bold))
                .foregroundStyle(phaseColor)

            if let phaseEndsAt = session.phaseEndsAt {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(remainingText(until: phaseEndsAt, at: timeline.date))
                        .font(.system(size: 48, weight: .heavy, design: .rounded))
                        .foregroundStyle(AppTheme.textPrimary)
                        .monospacedDigit()
                }
            }

            Text(roundLabel)
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)

            Spacer()

            Button(role: .destructive) {
                session.cancel()
            } label: {
                Label("End Session", systemImage: "xmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }

    private var phaseLabel: String {
        switch session.phase {
        case .working: return "Focus"
        case .onBreak: return "Break"
        case .idle, .finished: return ""
        }
    }

    private var phaseColor: Color {
        switch session.phase {
        case .working: return AppTheme.dynamicAccent
        case .onBreak: return .green
        case .idle, .finished: return AppTheme.textSecondary
        }
    }

    private var roundLabel: String {
        switch session.phase {
        case .working(let round), .onBreak(let round):
            return "Round \(round) of \(session.totalRounds)"
        case .idle, .finished:
            return ""
        }
    }

    private func remainingText(until end: Date, at now: Date) -> String {
        let remaining = max(0, Int(end.timeIntervalSince(now).rounded()))
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }
}
