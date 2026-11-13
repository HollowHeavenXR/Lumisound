import SwiftUI

/// Screen for the "Needle Drop" mini-game — see `NeedleDropService`'s doc
/// comment for the rules. Owns its own `NeedleDropService` instance rather
/// than being one more app-wide `@StateObject` in `LumisoundApp`, since a
/// game session only exists while this screen is on screen; `.onDisappear`
/// always restores whatever was playing before the game started.
struct NeedleDropView: View {
    @EnvironmentObject private var player: AudioPlayerManager
    @EnvironmentObject private var library: LibraryManager
    @StateObject private var game = NeedleDropService()

    var body: some View {
        ZStack {
            GalleryBackgroundView().ignoresSafeArea()
            content
        }
        .navigationTitle("Needle Drop")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { game.player = player }
        .onDisappear { game.endSession() }
    }

    @ViewBuilder
    private var content: some View {
        switch game.state {
        case .idle:
            introCard
        case .playing, .revealed:
            roundCard
        }
    }

    // MARK: - Idle / intro

    private var introCard: some View {
        VStack(spacing: 20) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(AppTheme.dynamicAccent)

            Text("Needle Drop")
                .font(.title2.bold())
                .foregroundStyle(AppTheme.textPrimary)

            Text("A short clip from a random track in your library plays — guess the song before it fades out. Build a streak; miss one and it resets.")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            HStack(spacing: 28) {
                statTile(value: "\(game.bestStreak)", label: "Best Streak")
                statTile(value: "\(game.totalCorrect)/\(game.totalRounds)", label: "Lifetime")
            }
            .padding(.top, 4)

            Button {
                game.startSession(library: library)
            } label: {
                Label(
                    library.allSongs.count < 4 ? "Needs More Songs" : "Start Playing",
                    systemImage: "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.dynamicAccent)
            .disabled(library.allSongs.count < 4)
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
        .padding(.vertical, 40)
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(AppTheme.textPrimary)
            Text(label.uppercased())
                .font(.caption2)
                .kerning(0.5)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    // MARK: - Playing / revealed

    private var roundCard: some View {
        VStack(spacing: 20) {
            HStack {
                Label("\(game.currentStreak)", systemImage: "flame.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(game.currentStreak > 0 ? .orange : AppTheme.textSecondary)
                Spacer()
                Button("End") { game.endSession() }
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 20)

            mysteryArt

            if case .playing = game.state {
                Button {
                    game.replayClip()
                } label: {
                    Label("Replay Clip", systemImage: "gobackward")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.dynamicAccent)
            } else if case .revealed(let correct) = game.state, let mystery = game.mysterySong {
                revealBanner(correct: correct, mystery: mystery)
            }

            VStack(spacing: 10) {
                ForEach(game.options) { option in
                    answerButton(option)
                }
            }
            .padding(.horizontal, 20)

            if case .revealed = game.state {
                Button {
                    game.nextRound(library: library)
                } label: {
                    Label("Next Round", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.dynamicAccent)
                .padding(.horizontal, 20)
            }
        }
        .padding(.vertical, 24)
        .animation(LumiMotion.fade(0.25), value: game.state)
    }

    private var mysteryArt: some View {
        ZStack {
            Circle()
                .fill(AppTheme.elevatedSurface)
                .frame(width: 140, height: 140)
            Image(systemName: revealedAnswer == nil ? "music.note" : (isCorrectReveal ? "checkmark" : "xmark"))
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(
                    revealedAnswer == nil ? AppTheme.textSecondary
                        : (isCorrectReveal ? .green : .red)
                )
        }
    }

    private var revealedAnswer: Bool? {
        if case .revealed(let correct) = game.state { return correct }
        return nil
    }

    private var isCorrectReveal: Bool { revealedAnswer == true }

    private func revealBanner(correct: Bool, mystery: Song) -> some View {
        VStack(spacing: 4) {
            Text(correct ? "Correct!" : "Not quite")
                .font(.headline)
                .foregroundStyle(correct ? .green : .red)
            Text("\(mystery.title) — \(mystery.artist)")
                .font(.subheadline)
                .foregroundStyle(AppTheme.textSecondary)
        }
    }

    private func answerButton(_ song: Song) -> some View {
        let revealed = revealedAnswer != nil
        let isMystery = song.id == game.mysterySong?.id
        return Button {
            game.submitGuess(song)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.caption)
                        .lineLimit(1)
                }
                Spacer()
                if revealed && isMystery {
                    Image(systemName: "checkmark.circle.fill")
                }
            }
            .foregroundStyle(revealed && isMystery ? .green : AppTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(revealed && isMystery ? Color.green.opacity(0.15) : AppTheme.surface)
            )
        }
        .buttonStyle(.plain)
        .disabled(revealed)
    }
}
