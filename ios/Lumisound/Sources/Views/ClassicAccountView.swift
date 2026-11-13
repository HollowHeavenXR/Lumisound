import PhotosUI
import SwiftUI

// MARK: - ClassicAccountView
//
// The Classic interface's Account screen: a "listener pass" instead of a
// settings list. The top is a ticket-style card (who you are, your vitals,
// your ID), sync sits on one status strip, and everything else lives on four
// decks — Profile, Listening, Connections, Security — so each visit shows one
// short, focused page rather than ten stacked sections. Lumen and Strata
// keep their own account screens (`AccountView` routes here for Classic only).

struct ClassicAccountView: View {
    @EnvironmentObject var account: AccountService
    @EnvironmentObject var library: LibraryManager
    @EnvironmentObject var aiDJ: AIDJService
    @EnvironmentObject var discordVerification: DiscordVerificationService
    @EnvironmentObject var listenRooms: ListenRoomService
    @Environment(\.dismiss) private var dismiss

    enum Deck: String, CaseIterable, Identifiable {
        case profile = "Profile"
        case listening = "Listening"
        case connections = "Connections"
        case security = "Security"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .profile: return "person.text.rectangle"
            case .listening: return "waveform"
            case .connections: return "point.3.connected.trianglepath.dotted"
            case .security: return "lock.shield"
            }
        }
    }

    @AppStorage("classicAccount.deck") private var deckRaw = Deck.profile.rawValue
    private var deck: Deck { Deck(rawValue: deckRaw) ?? .profile }

    private let discordPresentationContext = DiscordAuthPresentationContext()

    @State private var showLogoutConfirm = false
    @State private var showDiscordUnlinkConfirm = false
    @State private var editingName = false
    @State private var draftName = ""
    @State private var savingName = false
    @State private var bio = ""
    @State private var editingBio = false
    @State private var draftBio = ""
    @State private var savingBio = false
    @State private var photosPickerItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var uploadingAvatar = false
    @State private var showGifPicker = false
    @State private var pickingDOB = false
    @State private var draftDOB = Calendar.current.date(byAdding: .year, value: -18, to: Date()) ?? Date()
    @State private var savingDOB = false
    @State private var addingEmail = false
    @State private var draftEmail = ""
    @State private var savingEmail = false
    @State private var copiedID = false
    @State private var showListenRoom = false

    private static let discordBlurple = Color(red: 0.345, green: 0.396, blue: 0.949)

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                pass
                syncStrip
                deckPicker
                Group {
                    switch deck {
                    case .profile: profileDeck
                    case .listening: listeningDeck
                    case .connections: connectionsDeck
                    case .security: securityDeck
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .animation(LumiMotion.settle, value: deckRaw)
        }
        .background(GalleryBackgroundView().ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await account.fetchStats()
            await account.refreshUnreadNotificationCount()
        }
        .task { bio = await account.fetchBio() }
        .task { await account.refreshTOTPStatus() }
        .onChange(of: account.isLoggedIn) { loggedIn in
            if loggedIn {
                Task { await account.pullSync(library: library) }
            } else {
                dismiss()
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photosPickerItem, matching: .images, photoLibrary: .shared())
        .onChange(of: photosPickerItem) { item in
            guard let item else { return }
            uploadingAvatar = true
            Task {
                defer { uploadingAvatar = false }
                // Raw bytes, so an animated GIF keeps its animation.
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await account.uploadAvatarData(data)
                }
                photosPickerItem = nil
            }
        }
        .sheet(isPresented: $showGifPicker) {
            GifPickerSheet { data in Task { await account.uploadAvatarData(data) } }
        }
        .sheet(isPresented: $showListenRoom) {
            if listenRooms.isInRoom { ListenRoomView() } else { ListenRoomEntryView() }
        }
        .confirmationDialog("Log Out", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) {
                Task {
                    await account.logout()
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will be signed out on this device. Your data stays on the server.")
        }
        .confirmationDialog("Unlink Discord", isPresented: $showDiscordUnlinkConfirm, titleVisibility: .visible) {
            Button("Unlink", role: .destructive) { Task { await discordVerification.unlink() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Discord Verified badge will be removed. You can link it again later.")
        }
    }

    // MARK: - Listener pass

    private var pass: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                avatarMenu
                VStack(alignment: .leading, spacing: 3) {
                    if editingName {
                        HStack(spacing: 6) {
                            TextField("Display name", text: $draftName)
                                .textContentType(.name)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .onSubmit(saveName)
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                            if savingName {
                                ProgressView().tint(.white)
                            } else {
                                Button(action: saveName) { Image(systemName: "checkmark.circle.fill") }
                                Button { editingName = false } label: { Image(systemName: "xmark.circle") }
                            }
                        }
                        .foregroundStyle(.white)
                        .font(.system(size: 20))
                    } else {
                        Button {
                            draftName = account.currentUser?.displayName ?? ""
                            editingName = true
                        } label: {
                            HStack(spacing: 6) {
                                Text(displayName)
                                    .font(.title3.bold())
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Image(systemName: "pencil")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Text("@\(account.currentUser?.username ?? "")")
                        .font(AppTheme.monoFont(size: 13))
                        .foregroundStyle(.white.opacity(0.8))
                    if discordVerification.isVerified {
                        Label("Discord Verified", systemImage: "checkmark.seal.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Self.discordBlurple.opacity(0.85), in: Capsule())
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)

            Perforation()
                .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(height: 1)
                .padding(.horizontal, 12)

            HStack(spacing: 0) {
                vital(account.stats.map { "\($0.totalPlays)" } ?? "—", "plays")
                Divider().frame(height: 26).overlay(.white.opacity(0.3))
                vital(account.stats.map { listenTime($0.totalListenSeconds) } ?? "—", "listened")
                Divider().frame(height: 26).overlay(.white.opacity(0.3))
                vital("\(library.favoriteSongIDs.count)", "favorites")
            }
            .padding(.vertical, 12)

            if let id = account.currentUser?.id {
                Button {
                    UIPasteboard.general.string = id
                    withAnimation(LumiMotion.glide) { copiedID = true }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        withAnimation(LumiMotion.glide) { copiedID = false }
                    }
                } label: {
                    HStack(spacing: 8) {
                        PassCode(seed: id)
                            .fill(.white.opacity(0.85))
                            .frame(width: 70, height: 16)
                        Text(id)
                            .font(AppTheme.monoFont(size: 10))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Image(systemName: copiedID ? "checkmark" : "doc.on.doc")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.18))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copiedID ? "User ID copied" : "Copy user ID")
            }
        }
        .background(
            LinearGradient(colors: [AppTheme.dynamicAccent, AppTheme.dynamicAccent.opacity(0.55), AppTheme.accentSoft.opacity(0.7)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: AppTheme.dynamicAccent.opacity(0.35), radius: 16, x: 0, y: 8)
    }

    private var avatarMenu: some View {
        Menu {
            Button { showPhotoPicker = true } label: { Label(account.avatarImage == nil ? "Choose Photo" : "Change Photo", systemImage: "photo") }
            Button { showGifPicker = true } label: { Label("Search GIFs", systemImage: "party.popper") }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                ZStack {
                    if let img = account.avatarImage {
                        AnimatedImageView(image: img, contentMode: .scaleAspectFill)
                            .frame(width: 72, height: 72)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(.white.opacity(0.22))
                            .frame(width: 72, height: 72)
                            .overlay(Text(initials).font(.title.bold()).foregroundStyle(.white))
                    }
                    if uploadingAvatar {
                        Circle().fill(.black.opacity(0.45)).frame(width: 72, height: 72)
                        ProgressView().tint(.white)
                    }
                }
                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 2))
                Image(systemName: "camera.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.white))
            }
        }
        .accessibilityLabel("Profile photo")
    }

    private func vital(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Sync strip

    private var syncStrip: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(AppTheme.dynamicAccent.opacity(0.15)).frame(width: 34, height: 34)
                if account.isSyncing {
                    ProgressView().tint(AppTheme.dynamicAccent)
                } else {
                    Image(systemName: account.errorMessage == nil ? "checkmark.icloud" : "exclamationmark.icloud")
                        .foregroundStyle(account.errorMessage == nil ? AppTheme.dynamicAccent : AppTheme.warning)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(account.isSyncing ? "Syncing…" : "Library sync")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Group {
                    if let err = account.errorMessage {
                        Text(err).foregroundStyle(AppTheme.warning)
                    } else if let last = account.lastSyncDate {
                        Text("\(last, style: .relative) ago · auto every 8 min")
                    } else {
                        Text("Auto every 8 min")
                    }
                }
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(2)
            }
            Spacer(minLength: 4)
            Menu {
                Button { Task { await account.pushSync(library: library) } } label: { Label("Push to Server", systemImage: "icloud.and.arrow.up") }
                Button { Task { await account.pullSync(library: library) } } label: { Label("Pull from Server", systemImage: "icloud.and.arrow.down") }
            } label: {
                Text("Sync")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(AppTheme.dynamicAccent, in: Capsule())
                    .foregroundStyle(.white)
            }
            .disabled(account.isSyncing)
            NavigationLink(destination: BackupHistoryView()) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.elevatedSurface, in: Circle())
            }
            .accessibilityLabel("Backup History")
        }
        .padding(12)
        .background(card)
    }

    // MARK: - Deck picker

    private var deckPicker: some View {
        HStack(spacing: 4) {
            ForEach(Deck.allCases) { d in
                let on = deck == d
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    deckRaw = d.rawValue
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: d.symbol).font(.system(size: 15, weight: .semibold))
                        Text(d.rawValue).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundStyle(on ? .white : AppTheme.textSecondary)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.dynamicAccent)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(4)
        .background(card)
    }

    // MARK: - Profile deck

    private var profileDeck: some View {
        VStack(spacing: 12) {
            panel("About you") {
                bioRow
                rowDivider
                emailRow
                rowDivider
                dobRow
            }
            panel("Social") {
                NavigationLink(destination: DiscoverView()) {
                    row("Discover", "sparkles", detail: nil)
                }
                .buttonStyle(.plain)
                rowDivider
                Button { showListenRoom = true } label: {
                    row("Listen Together", "antenna.radiowaves.left.and.right", detail: listenRooms.roomCode)
                }
                .buttonStyle(.plain)
                rowDivider
                Toggle(isOn: Binding(
                    get: { account.currentUser?.shareListeningActivity ?? false },
                    set: { v in Task { await account.setShareListeningActivity(v) } }
                )) {
                    rowLabel("Share Listening Activity", "person.wave.2")
                }
                .tint(AppTheme.dynamicAccent)
                .padding(.vertical, 6)
            }
            footnote("When sharing is on, the titles and artists you play (never files or links) appear in Discover's activity feed and count toward Trending.")
        }
    }

    private var bioRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                rowLabel("Bio", "text.quote")
                Spacer()
                if !editingBio {
                    Button(bio.isEmpty ? "Add" : "Edit") {
                        draftBio = bio
                        editingBio = true
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.dynamicAccent)
                }
            }
            if editingBio {
                TextField("Say something about yourself…", text: $draftBio, axis: .vertical)
                    .lineLimit(1...4)
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(10)
                    .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onChange(of: draftBio) { v in
                        if v.count > 280 { draftBio = String(v.prefix(280)) }
                    }
                HStack {
                    Text("\(draftBio.count)/280").font(.caption2.monospacedDigit()).foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    if savingBio {
                        ProgressView().tint(AppTheme.dynamicAccent)
                    } else {
                        Button("Cancel") { editingBio = false }.font(.caption).foregroundStyle(AppTheme.textSecondary)
                        Button("Save", action: saveBio).font(.caption.bold()).foregroundStyle(AppTheme.dynamicAccent).padding(.leading, 8)
                    }
                }
            } else if !bio.isEmpty {
                Text(bio)
                    .font(AppTheme.bodyFont(size: 14))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var emailRow: some View {
        if let email = account.currentUser?.email, !email.isEmpty {
            row("Email", "envelope", detail: email)
        } else if addingEmail {
            VStack(alignment: .leading, spacing: 6) {
                rowLabel("Email", "envelope")
                TextField("you@example.com", text: $draftEmail)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit(saveEmail)
                    .padding(10)
                    .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack {
                    Spacer()
                    if savingEmail {
                        ProgressView().tint(AppTheme.dynamicAccent)
                    } else {
                        Button("Cancel") { addingEmail = false; draftEmail = "" }.font(.caption).foregroundStyle(AppTheme.textSecondary)
                        Button("Save", action: saveEmail).font(.caption.bold()).foregroundStyle(AppTheme.dynamicAccent).padding(.leading, 8)
                    }
                }
            }
            .padding(.vertical, 6)
        } else {
            Button { addingEmail = true } label: {
                row("Email", "envelope", detail: "Add", detailTint: AppTheme.dynamicAccent)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var dobRow: some View {
        if account.hasDateOfBirth {
            row("Date of Birth", "gift", detail: account.currentUser?.dateOfBirth ?? "Set")
        } else if pickingDOB {
            VStack(alignment: .leading, spacing: 6) {
                DatePicker("Date of Birth",
                           selection: $draftDOB,
                           in: ...(Calendar.current.date(byAdding: .year, value: -13, to: Date()) ?? Date()),
                           displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .foregroundStyle(AppTheme.textPrimary)
                HStack {
                    Spacer()
                    if savingDOB {
                        ProgressView().tint(AppTheme.dynamicAccent)
                    } else {
                        Button("Cancel") { pickingDOB = false }.font(.caption).foregroundStyle(AppTheme.textSecondary)
                        Button("Save", action: saveDOB).font(.caption.bold()).foregroundStyle(AppTheme.dynamicAccent).padding(.leading, 8)
                    }
                }
            }
            .padding(.vertical, 6)
        } else {
            Button { pickingDOB = true } label: {
                row("Date of Birth", "gift", detail: "Not set", detailTint: AppTheme.dynamicAccent)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Listening deck

    private var listeningDeck: some View {
        VStack(spacing: 12) {
            if let stats = account.stats, !stats.topArtists.isEmpty {
                panel("Your top artists") {
                    let top = Array(stats.topArtists.prefix(5))
                    let most = Double(top.first?.playCount ?? 1)
                    VStack(spacing: 8) {
                        ForEach(Array(top.enumerated()), id: \.element.id) { i, a in
                            HStack(spacing: 10) {
                                Text("\(i + 1)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(i == 0 ? AppTheme.dynamicAccent : AppTheme.textSecondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(a.artist).font(.subheadline).foregroundStyle(AppTheme.textPrimary).lineLimit(1)
                                        Spacer()
                                        Text("\(a.playCount)").font(.caption.monospacedDigit()).foregroundStyle(AppTheme.textSecondary)
                                    }
                                    GeometryReader { geo in
                                        Capsule()
                                            .fill(AppTheme.dynamicAccent.opacity(i == 0 ? 0.9 : 0.45))
                                            .frame(width: max(6, geo.size.width * Double(a.playCount) / max(most, 1)))
                                    }
                                    .frame(height: 4)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            panel("Library") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    tile(RewindView(), "Your Rewind", "chart.bar.xaxis")
                    tile(AchievementsView(), "Achievements", "trophy")
                    tile(ListeningGoalView(), "Listening Goal", "target")
                    tile(ListeningHeatmapView(), "Heatmap", "calendar")
                    tile(ConstellationView(), "Constellation", "sparkles")
                    tile(TimeCapsulesView(), "Time Capsules", "shippingbox")
                    tile(NeedleDropView(), "Needle Drop", "questionmark.circle")
                    tile(PodcastsView(), "Podcasts", "mic.square")
                    tile(HearingHealthView(), "Hearing Health", "ear")
                    tile(NotificationsView(), "Notifications", "bell",
                         badge: account.unreadNotificationCount > 0 ? "\(account.unreadNotificationCount)" : nil)
                }
                .padding(.vertical, 6)
            }
            panel("AI DJ") {
                Toggle(isOn: $aiDJ.isEnabled) { rowLabel("AI DJ Mode", "mic.fill") }
                    .tint(AppTheme.dynamicAccent)
                    .padding(.vertical, 6)
                if aiDJ.isEnabled {
                    rowDivider
                    LumiPicker(selection: $aiDJ.voiceIdentifier) {
                        Text("System Default").lumiOptionLabel("System Default").tag(nil as String?)
                        ForEach(AIDJVoiceOption.available) { option in
                            Text(option.displayName).lumiOptionLabel(String(describing: option.displayName)).tag(option.identifier as String?)
                        }
                    } label: {
                        rowLabel("Voice", "waveform")
                    }
                    .tint(AppTheme.dynamicAccent)
                    .padding(.vertical, 4)
                    rowDivider
                    HStack {
                        rowLabel("Pitch", "tuningfork")
                        Spacer()
                        Text(String(format: "%.2f×", aiDJ.pitchMultiplier)).font(AppTheme.monoFont(size: 13)).foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.top, 6)
                    Slider(value: $aiDJ.pitchMultiplier, in: 0.5...2.0, step: 0.02).tint(AppTheme.dynamicAccent)
                }
            }
            .animation(LumiMotion.fade(0.2), value: aiDJ.isEnabled)
            footnote("AI DJ speaks a short line between tracks with an on-device voice. Only the two track titles and artists are sent to write it — never audio.")
        }
    }

    // MARK: - Connections deck

    private var connectionsDeck: some View {
        VStack(spacing: 12) {
            panel("Discord") {
                if discordVerification.isVerified {
                    HStack {
                        rowLabel("Verified", "checkmark.seal.fill", tint: Self.discordBlurple)
                        if let name = discordVerification.discordUsername {
                            Text(name).font(.caption).foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                        Button("Unlink") { showDiscordUnlinkConfirm = true }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .padding(.vertical, 6)
                } else {
                    Button {
                        Task { await discordVerification.startVerification(presentationContext: discordPresentationContext) }
                    } label: {
                        HStack {
                            rowLabel("Verify with Discord", "checkmark.seal", tint: Self.discordBlurple)
                            Spacer()
                            if discordVerification.isLinking { ProgressView().tint(AppTheme.dynamicAccent) }
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .disabled(discordVerification.isLinking)
                    if let error = discordVerification.errorMessage {
                        Text(error).font(.caption).foregroundStyle(AppTheme.warning)
                    }
                }
                rowDivider
                NavigationLink(destination: DiscordRichPresenceView()) { row("Rich Presence", "key.viewfinder", detail: nil) }.buttonStyle(.plain)
                rowDivider
                NavigationLink(destination: DiscordWebhookView()) { row("Now Playing Webhook", "message", detail: nil) }.buttonStyle(.plain)
            }
            panel("Services") {
                NavigationLink(destination: ScrobblingView()) { row("Scrobbling", "waveform.path.ecg", detail: "Last.fm · Libre.fm") }.buttonStyle(.plain)
                rowDivider
                NavigationLink(destination: YoutubeApiKeyView()) { row("YouTube API Key", "key", detail: nil) }.buttonStyle(.plain)
                rowDivider
                NavigationLink(destination: CookiesFileView()) { row("YouTube Cookies", "doc.text", detail: nil) }.buttonStyle(.plain)
            }
            footnote("Your own YouTube Data API key lets long playlists resolve completely; a cookies.txt export lets downloads use your own session.")
        }
    }

    // MARK: - Security deck

    private var securityDeck: some View {
        VStack(spacing: 12) {
            panel("Sign-in") {
                NavigationLink(destination: TwoFactorAuthView()) {
                    row("Two-Factor Authentication", "lock.shield", detail: account.isTOTPEnabled ? "On" : "Off",
                        detailTint: account.isTOTPEnabled ? AppTheme.success : AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
                rowDivider
                NavigationLink(destination: ActiveSessionsView()) { row("Active Sessions", "laptopcomputer.and.iphone", detail: nil) }.buttonStyle(.plain)
                rowDivider
                NavigationLink(destination: ChangePasswordView()) { row("Change Password", "key", detail: nil) }.buttonStyle(.plain)
            }
            if account.currentUser?.id == AdminDashboardView.operatorUserID {
                panel("Operator") {
                    NavigationLink(destination: AdminDashboardView()) { row("Admin Dashboard", "server.rack", detail: nil) }.buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                Button { showLogoutConfirm = true } label: {
                    Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(card)
                        .foregroundStyle(AppTheme.textPrimary)
                }
                .buttonStyle(.plain)
                NavigationLink(destination: DeleteAccountView()) {
                    Label("Delete Account", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AppTheme.error.opacity(0.14)))
                        .foregroundStyle(AppTheme.error)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Building blocks

    private var card: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(AppTheme.surface)
    }

    private var rowDivider: some View {
        Rectangle().fill(AppTheme.textSecondary.opacity(0.12)).frame(height: 0.5).padding(.leading, 34)
    }

    private func panel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .kerning(1)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.bottom, 4)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private func rowLabel(_ title: String, _ icon: String, tint: Color? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint ?? AppTheme.dynamicAccent)
                .frame(width: 24)
            Text(title)
                .font(AppTheme.bodyFont(size: 15))
                .foregroundStyle(AppTheme.textPrimary)
        }
    }

    private func row(_ title: String, _ icon: String, detail: String?, detailTint: Color? = nil) -> some View {
        HStack {
            rowLabel(title, icon)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(detailTint ?? AppTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.textSecondary.opacity(0.5))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func tile<Destination: View>(_ destination: Destination, _ title: String, _ icon: String, badge: String? = nil) -> some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.dynamicAccent)
                    Spacer()
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.dynamicAccent, in: Capsule())
                    }
                }
                Text(title)
                    .font(AppTheme.bodyFont(size: 13).weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(AppTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
    }

    // MARK: - Helpers

    private var displayName: String {
        if let d = account.currentUser?.displayName, !d.isEmpty { return d }
        return account.currentUser?.username ?? ""
    }

    private var initials: String {
        let parts = displayName.split(separator: " ")
        if parts.count >= 2 { return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased() }
        return String(displayName.prefix(1)).uppercased()
    }

    private func listenTime(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func saveName() {
        guard !savingName else { return }
        let trimmed = draftName.trimmingCharacters(in: .whitespaces)
        savingName = true
        Task {
            defer { savingName = false; editingName = false }
            await account.updateDisplayName(trimmed)
        }
    }

    private func saveBio() {
        guard !savingBio else { return }
        let trimmed = draftBio.trimmingCharacters(in: .whitespacesAndNewlines)
        savingBio = true
        Task {
            defer { savingBio = false; editingBio = false }
            if await account.setBio(trimmed) { bio = trimmed }
        }
    }

    private func saveEmail() {
        guard !savingEmail else { return }
        savingEmail = true
        let candidate = draftEmail
        Task {
            defer { savingEmail = false }
            // Stays open on failure so the typed address can be corrected.
            if await account.setEmail(candidate) {
                addingEmail = false
                draftEmail = ""
            }
        }
    }

    private func saveDOB() {
        guard !savingDOB else { return }
        savingDOB = true
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let iso = f.string(from: draftDOB)
        Task {
            defer { savingDOB = false; pickingDOB = false }
            await account.setDateOfBirth(iso)
        }
    }
}

/// The torn-ticket line across the pass.
private struct Perforation: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// A barcode drawn from the user ID (decorative; stable per account).
private struct PassCode: Shape {
    let seed: String

    func path(in rect: CGRect) -> Path {
        var p = Path()
        var h: UInt64 = 0xcbf29ce484222325
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        var x = rect.minX
        while x < rect.maxX {
            h = h &* 6364136223846793005 &+ 1442695040888963407
            let w = CGFloat(1 + (h >> 60) % 3)
            let gap = CGFloat(1 + (h >> 56) % 2)
            p.addRect(CGRect(x: x, y: rect.minY, width: min(w, rect.maxX - x), height: rect.height))
            x += w + gap
        }
        return p
    }
}
