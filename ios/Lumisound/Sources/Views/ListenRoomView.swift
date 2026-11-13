import SwiftUI

/// The shared-listening room screen: who's here, what the host is playing, the
/// group chat, and the voted queue.
///
/// Followers do not get transport controls. The host's playback is the room's
/// playback, so a follower's play/pause would either desync them silently or
/// fight the next state push — neither is a behaviour worth shipping. What a
/// follower gets instead is an explicit "catch up" action, because drifting is
/// normal (a paused follower, a network stall) and the fix should be one tap
/// rather than leaving.
struct ListenRoomView: View {

    @EnvironmentObject var rooms: ListenRoomService
    @EnvironmentObject var player: AudioPlayerManager
    @Environment(\.dismiss) private var dismiss

    @State private var draftMessage = ""
    @State private var showLeaveConfirm = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.clear.ignoresSafeArea()
                if rooms.isInRoom {
                    content
                } else {
                    ContentUnavailableView(
                        rooms.closedByHost ? "Room Closed" : "Not in a Room",
                        systemImage: rooms.closedByHost ? "door.left.hand.closed" : "person.2.slash",
                        description: Text(rooms.closedByHost
                            ? "The host ended this listening session."
                            : "Start a room or join one with a code.")
                    )
                }
            }
            .navigationTitle(rooms.roomCode.map { "Room \($0)" } ?? "Listening Room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if rooms.isInRoom {
                    ToolbarItem(placement: .primaryAction) {
                        Button(rooms.isHost ? "End" : "Leave", role: .destructive) {
                            showLeaveConfirm = true
                        }
                        .foregroundStyle(AppTheme.warning)
                    }
                }
            }
            .confirmationDialog(
                rooms.isHost ? "End this room for everyone?" : "Leave this room?",
                isPresented: $showLeaveConfirm, titleVisibility: .visible
            ) {
                Button(rooms.isHost ? "End Room" : "Leave", role: .destructive) {
                    Task {
                        await rooms.leave(close: rooms.isHost)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var content: some View {
        List {
            nowPlayingSection
            participantsSection
            queueSection
            chatSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) { chatComposer }
    }

    // MARK: Now playing

    private var nowPlayingSection: some View {
        Section("Now Playing") {
            VStack(alignment: .leading, spacing: 4) {
                Text(rooms.state?.title ?? "Nothing yet")
                    .font(AppTheme.bodyFont(size: 15).weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                if let artist = rooms.state?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(AppTheme.bodyFont(size: 13))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: (rooms.state?.isPlaying ?? false) ? "play.fill" : "pause.fill")
                        .font(.system(size: 10))
                    Text(positionLabel)
                        .font(AppTheme.monoFont(size: 12))
                }
                .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.vertical, 2)

            if !rooms.isHost {
                Toggle(isOn: $rooms.followHost) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Follow the host")
                            .font(AppTheme.bodyFont(size: 14))
                        Text(syncLabel)
                            .font(AppTheme.bodyFont(size: 11))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .tint(AppTheme.dynamicAccent)
                ListenTogetherReactionBar()
                    .listRowBackground(Color.clear)
            } else {
                Text("You're hosting — everyone follows your playback, seeks and pauses included.")
                    .font(AppTheme.bodyFont(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
                ListenTogetherReactionBar()
                    .listRowBackground(Color.clear)
            }
        }
    }

    /// "In step" / "Catching up · 0.3 s behind" from the sync engine.
    private var syncLabel: String {
        guard rooms.followHost else { return "Off — you're playing your own music." }
        guard let d = rooms.syncDrift else { return "Starting the host's track…" }
        if abs(d) < 0.08 { return "In step with the host" }
        return String(format: "Catching up · %.1f s %@", abs(d), d > 0 ? "ahead" : "behind")
    }

    /// The host's position, advanced for however long ago they reported it — the
    /// same computation a follower seeks to. Recomputed on each render rather than
    /// stored, so it does not need its own ticking timer to stay honest.
    private var positionLabel: String {
        guard let seconds = rooms.state?.resolvedPosition() else { return "--:--" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Participants

    private var participantsSection: some View {
        Section("Listening (\(rooms.participants.count))") {
            if rooms.participants.isEmpty {
                Text("Just you for now.")
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            ForEach(rooms.participants) { person in
                HStack(spacing: 8) {
                    Image(systemName: person.isHost ? "crown.fill" : "person.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(person.isHost ? AppTheme.dynamicAccent : AppTheme.textSecondary)
                        .frame(width: 18)
                    Text(person.label)
                        .font(AppTheme.bodyFont(size: 14))
                        .foregroundStyle(AppTheme.textPrimary)
                    if person.isHost {
                        Text("host")
                            .font(AppTheme.bodyFont(size: 10))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: Queue

    private var queueSection: some View {
        Section("Up Next — Voted") {
            if rooms.queue.isEmpty {
                Text("No suggestions yet. Add one from a track's menu.")
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            ForEach(rooms.queue) { item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(AppTheme.bodyFont(size: 14))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        if let artist = item.artist, !artist.isEmpty {
                            Text(artist)
                                .font(AppTheme.bodyFont(size: 12))
                                .foregroundStyle(AppTheme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button {
                        Task { await rooms.toggleVote(itemID: item.id) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrowshape.up.fill").font(.system(size: 11))
                            Text("\(item.votes)").font(AppTheme.monoFont(size: 12))
                        }
                        .foregroundStyle(AppTheme.dynamicAccent)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(AppTheme.dynamicAccent.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Chat

    private var chatSection: some View {
        Section("Room") {
            ForEach(rooms.events) { event in
                if event.isChat {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.author)
                            .font(AppTheme.bodyFont(size: 11).weight(.semibold))
                            .foregroundStyle(AppTheme.dynamicAccent)
                        Text(event.message ?? "")
                            .font(AppTheme.bodyFont(size: 14))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                } else {
                    // Joins, leaves and track changes read as narration rather than
                    // as messages, so a busy room's chat stays readable.
                    Text(systemLine(for: event))
                        .font(AppTheme.bodyFont(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
        }
    }

    private func systemLine(for event: RoomEvent) -> String {
        switch event.eventType {
        case "track_change":
            let track = [event.title, event.artist].compactMap { $0 }.filter { !$0.isEmpty }
            return "now playing — \(track.joined(separator: " · "))"
        case "join": return "\(event.author) joined"
        case "leave": return "\(event.author) left"
        default: return event.message ?? event.eventType
        }
    }

    private var chatComposer: some View {
        HStack(spacing: 8) {
            TextField("Message the room", text: $draftMessage, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .font(AppTheme.bodyFont(size: 14))
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(AppTheme.surface, in: Capsule())
                .submitLabel(.send)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(AppTheme.dynamicAccent)
            }
            .disabled(draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
        .opacity(rooms.isInRoom ? 1 : 0)
    }

    private func send() {
        let message = draftMessage
        draftMessage = ""
        Task { await rooms.sendChat(message) }
    }
}

/// Entry point: start a room around what's playing, or join one by code.
struct ListenRoomEntryView: View {

    @EnvironmentObject var rooms: ListenRoomService
    @EnvironmentObject var player: AudioPlayerManager
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var isWorking = false
    @State private var showRoom = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task {
                            isWorking = true
                            defer { isWorking = false }
                            if await rooms.createRoom(player: player) != nil { showRoom = true }
                        }
                    } label: {
                        Label("Start a room", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(isWorking)
                } footer: {
                    Text("Others join with your six-character code and follow whatever you play.")
                }

                Section("Join a room") {
                    TextField("Code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(AppTheme.monoFont(size: 18))
                        .onChange(of: code) { _, new in
                            // Six characters, uppercase, alphanumeric — enforced as
                            // it's typed so a paste with stray whitespace or a
                            // lowercase code still works instead of 404ing.
                            let cleaned = new.uppercased().filter { $0.isLetter || $0.isNumber }
                            if cleaned != new { code = String(cleaned.prefix(6)) }
                            else if new.count > 6 { code = String(new.prefix(6)) }
                        }
                    Button {
                        Task {
                            isWorking = true
                            defer { isWorking = false }
                            await rooms.join(code: code, player: player)
                            if rooms.isInRoom { showRoom = true }
                        }
                    } label: {
                        if isWorking { ProgressView() } else { Text("Join") }
                    }
                    .disabled(code.count != 6 || isWorking)
                }

                if let error = rooms.errorMessage {
                    Section { Text(error).foregroundStyle(AppTheme.warning) }
                }
            }
            .navigationTitle("Listen Together")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .sheet(isPresented: $showRoom) {
                ListenRoomView()
                    .environmentObject(rooms)
                    .environmentObject(player)
            }
        }
    }
}

/// The room when in one, otherwise start / join.
struct ListenTogetherSheet: View {
    @EnvironmentObject var rooms: ListenRoomService

    var body: some View {
        if rooms.isInRoom { ListenRoomView() } else { ListenRoomEntryView() }
    }
}
