import AuthenticationServices
import SwiftUI
import PhotosUI

/// Minimal `ASWebAuthenticationPresentationContextProviding` conformance —
/// Discord's OAuth2 consent screen (`DiscordVerificationService
/// .startVerification`) is the first thing in this app that needs a system
/// web-auth session, so there's no existing provider to reuse. Not private:
/// `DiscordRichPresenceView` reuses this same trivial, stateless conformance
/// rather than duplicating it for its own inline "Verify with Discord" entry
/// point.
final class DiscordAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

struct AccountView: View {

    @EnvironmentObject var account: AccountService
    @EnvironmentObject var library: LibraryManager
    @EnvironmentObject var aiDJ: AIDJService
    @EnvironmentObject var discordVerification: DiscordVerificationService
    @EnvironmentObject var listenRooms: ListenRoomService
    @Environment(\.dismiss) var dismiss

    private let discordPresentationContext = DiscordAuthPresentationContext()

    @State private var showLogoutConfirm = false
    @State private var showDiscordUnlinkConfirm = false
    @State private var isEditingDisplayName = false
    @State private var draftDisplayName = ""
    @State private var isSavingDisplayName = false

    // Profile bio
    @State private var bio = ""
    @State private var isEditingBio = false
    @State private var draftBio = ""
    @State private var isSavingBio = false

    // Avatar
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var isUploadingAvatar = false
    @State private var showAvatarGifPicker = false

    // DOB
    @State private var isPickingDOB = false

    // User ID copy feedback
    @State private var didCopyUserID = false

    @State private var draftDOB = Date()
    @State private var isSavingDOB = false
    @State private var isAddingEmail = false
    @State private var draftEmail = ""
    @State private var isSavingEmail = false
    @State private var showListenRoom = false

    var body: some View {
        // Classic has its own account screen (the listener pass); Lumen and
        // Strata keep this one.
        if InterfaceEdition.current == .classic {
            ClassicAccountView()
        } else {
            standardBody
        }
    }

    private var standardBody: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            List {
                // MARK: Header — avatar + username
                Section {
                    HStack(spacing: 16) {
                        // Avatar circle: photo if available, else gradient + initials.
                        // AnimatedImageView (not a plain SwiftUI Image) so a GIF avatar
                        // actually plays here — Image(uiImage:) would only ever show
                        // its first frame. Static avatars render identically either way.
                        ZStack(alignment: .bottomTrailing) {
                            ZStack {
                                if let img = account.avatarImage {
                                    AnimatedImageView(image: img, contentMode: .scaleAspectFill)
                                        .frame(width: 64, height: 64)
                                        .clipShape(Circle())
                                } else {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [AppTheme.dynamicAccent, AppTheme.accentSoft],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 64, height: 64)
                                        .overlay(
                                            Text(initials)
                                                .font(.title2.bold())
                                                .foregroundStyle(.white)
                                        )
                                }
                                if isUploadingAvatar {
                                    Circle()
                                        .fill(.black.opacity(0.45))
                                        .frame(width: 64, height: 64)
                                    ProgressView()
                                        .tint(.white)
                                }
                            }

                            // Discord-verified badge — Discord's own "blurple" so it
                            // reads instantly as "this is specifically Discord", the
                            // same convention StreamTrackRow's per-source badges use.
                            if discordVerification.isVerified {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(Color(red: 0.345, green: 0.396, blue: 0.949))
                                    .background(Circle().fill(AppTheme.surface).frame(width: 18, height: 18))
                                    .offset(x: 2, y: 2)
                            }
                        }
                        .shadow(color: AppTheme.dynamicAccent.opacity(0.4), radius: 8, x: 0, y: 4)

                        VStack(alignment: .leading, spacing: 4) {
                            if let displayName = account.currentUser?.displayName,
                               !displayName.isEmpty {
                                Text(displayName)
                                    .font(.title3.bold())
                                    .foregroundStyle(AppTheme.textPrimary)
                                Text("@\(account.currentUser?.username ?? "")")
                                    .font(AppTheme.bodyFont(size: 13))
                                    .foregroundStyle(AppTheme.textSecondary)
                            } else {
                                Text(account.currentUser?.username ?? "")
                                    .font(.title3.bold())
                                    .foregroundStyle(AppTheme.textPrimary)
                            }
                            if let email = account.currentUser?.email, !email.isEmpty {
                                Text(email)
                                    .font(AppTheme.bodyFont(size: 12))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            if discordVerification.isVerified {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color(red: 0.345, green: 0.396, blue: 0.949))
                                    Text("Discord Verified")
                                        .font(AppTheme.bodyFont(size: 12).weight(.semibold))
                                        .foregroundStyle(AppTheme.textSecondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)

                    // Discord verification — link/unlink. Row lives here rather than
                    // buried in Settings → Integrations (where the pre-existing Now
                    // Playing webhook/Rich Presence config live) since this one drives
                    // the badge shown directly above, on the profile header itself.
                    if discordVerification.isVerified {
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Discord Verified")
                                        .foregroundStyle(AppTheme.textPrimary)
                                    if let username = discordVerification.discordUsername {
                                        Text(username)
                                            .font(AppTheme.bodyFont(size: 12))
                                            .foregroundStyle(AppTheme.textSecondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundStyle(Color(red: 0.345, green: 0.396, blue: 0.949))
                            }
                            Spacer()
                            // This was a bare, unconfirmed button calling straight
                            // through to a real server-side DELETE — a stray tap
                            // while scrolling this screen (it sits in a plain list
                            // row, not guarded by anything) permanently removed the
                            // verification with no "are you sure" step at all,
                            // reported as the badge "randomly, completely"
                            // unlinking. Every other destructive action on this
                            // screen (see `showLogoutConfirm` above) already goes
                            // through a confirmation dialog first — this one just
                            // hadn't gotten the same treatment.
                            Button("Unlink") {
                                showDiscordUnlinkConfirm = true
                            }
                            .font(AppTheme.bodyFont(size: 13).weight(.semibold))
                            .foregroundStyle(AppTheme.textSecondary)
                        }
                    } else {
                        Button {
                            Task {
                                await discordVerification.startVerification(
                                    presentationContext: discordPresentationContext
                                )
                            }
                        } label: {
                            HStack {
                                Label("Verify with Discord", systemImage: "checkmark.seal")
                                    .foregroundStyle(AppTheme.dynamicAccent)
                                Spacer()
                                if discordVerification.isLinking {
                                    ProgressView().tint(AppTheme.dynamicAccent)
                                }
                            }
                        }
                        .disabled(discordVerification.isLinking)
                        if let error = discordVerification.errorMessage {
                            Text(error)
                                .font(AppTheme.bodyFont(size: 12))
                                .foregroundStyle(AppTheme.warning)
                        }
                    }

                    // Upload photo button
                    PhotosPicker(
                        selection: $photosPickerItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label(
                            account.avatarImage == nil ? "Upload Profile Photo" : "Change Profile Photo",
                            systemImage: "camera.circle"
                        )
                        .foregroundStyle(AppTheme.dynamicAccent)
                    }
                    .onChange(of: photosPickerItem) { item in
                        guard let item else { return }
                        isUploadingAvatar = true
                        Task {
                            defer { isUploadingAvatar = false }
                            // Route through the raw Data, not a UIImage — `uploadAvatarData`
                            // needs to sniff the original bytes for a GIF header before any
                            // conversion happens. Decoding straight to UIImage first (like
                            // this used to) throws the animation away, since UIImage(data:)
                            // only ever keeps a GIF's first frame.
                            if let data = try? await item.loadTransferable(type: Data.self) {
                                await account.uploadAvatarData(data)
                            }
                            photosPickerItem = nil
                        }
                    }

                    // Alternative to picking from the gallery — search GIPHY
                    // for an animated GIF instead, same as ProfileView's
                    // avatar/banner pickers.
                    Button {
                        showAvatarGifPicker = true
                    } label: {
                        Label("Search GIFs", systemImage: "party.popper")
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
                }
                .listRowBackground(tintedRowBackground(.blue))

                // MARK: Sync Section
                Section {
                    // Last synced info
                    if let lastSync = account.lastSyncDate {
                        HStack {
                            Label("Last Synced", systemImage: "clock")
                                .foregroundStyle(AppTheme.textPrimary)
                            Spacer()
                            Text(lastSync, style: .relative)
                                .font(AppTheme.bodyFont(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }

                    // Auto-sync cadence info
                    HStack {
                        Label("Auto-sync", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer()
                        Text("every 8 min")
                            .font(AppTheme.bodyFont(size: 13))
                            .foregroundStyle(AppTheme.textSecondary)
                    }

                    // Push to server
                    Button {
                        Task { await account.pushSync(library: library) }
                    } label: {
                        HStack {
                            Label("Push to Server", systemImage: "icloud.and.arrow.up")
                                .foregroundStyle(AppTheme.dynamicAccent)
                            Spacer()
                            if account.isSyncing {
                                ProgressView()
                                    .tint(AppTheme.dynamicAccent)
                            }
                        }
                    }
                    .disabled(account.isSyncing)

                    // Pull from server
                    Button {
                        Task { await account.pullSync(library: library) }
                    } label: {
                        HStack {
                            Label("Pull from Server", systemImage: "icloud.and.arrow.down")
                                .foregroundStyle(AppTheme.dynamicAccent)
                            Spacer()
                            if account.isSyncing {
                                ProgressView()
                                    .tint(AppTheme.dynamicAccent)
                            }
                        }
                    }
                    .disabled(account.isSyncing)

                    // Backup history — automatic snapshots taken before every
                    // push/restore, in case a bad sync overwrites server data.
                    NavigationLink(destination: BackupHistoryView()) {
                        Label("Backup History", systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(AppTheme.textPrimary)
                    }

                    // Error message
                    if let err = account.errorMessage {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(AppTheme.bodyFont(size: 13))
                            .foregroundStyle(AppTheme.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                } header: {
                    sectionHeader("Sync")
                }
                .listRowBackground(tintedRowBackground(.blue))

                // MARK: Stats Section
                //
                // Structural redesign: the old screen buried every number
                // behind a vertical stack of `LabeledContent` rows and then
                // ten more `NavigationLink` rows underneath with no visual
                // grouping. Numbers now read as a scannable stat strip;
                // the destinations below read as a tappable icon grid, so
                // the eye can parse "here are my numbers" vs. "here's where
                // I go" at a glance instead of one undifferentiated list.
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            statTile(value: "\(library.playlists.count)", label: "Playlists", icon: "music.note.list")
                            statTile(value: "\(library.favoriteSongIDs.count)", label: "Favorites", icon: "heart.fill")
                            if let stats = account.stats {
                                statTile(value: "\(stats.totalPlays)", label: "Total Plays", icon: "play.fill")
                                statTile(value: formattedListenTime(stats.totalListenSeconds), label: "Listening Time", icon: "clock.fill")
                                if let topArtist = stats.topArtists.first {
                                    statTile(value: topArtist.artist, label: "Top Artist", icon: "star.fill")
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 0))

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        gridLink(destination: RewindView(), title: "Your Rewind", icon: "chart.bar.xaxis")
                        gridLink(destination: PodcastsView(), title: "Podcasts", icon: "mic.square")
                        gridLink(destination: AchievementsView(), title: "Achievements", icon: "trophy")
                        gridLink(destination: ListeningGoalView(), title: "Listening Goal", icon: "target")
                        gridLink(destination: NeedleDropView(), title: "Needle Drop", icon: "questionmark.circle")
                        gridLink(destination: TimeCapsulesView(), title: "Time Capsules", icon: "shippingbox")
                        gridLink(destination: ConstellationView(), title: "Constellation", icon: "sparkles")
                        gridLink(destination: ListeningHeatmapView(), title: "Heatmap", icon: "calendar")
                        gridLink(destination: HearingHealthView(), title: "Hearing Health", icon: "ear")
                        gridLink(
                            destination: NotificationsView(),
                            title: "Notifications",
                            icon: "bell",
                            badge: account.unreadNotificationCount > 0 ? "\(account.unreadNotificationCount)" : nil
                        )
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                } header: {
                    sectionHeader("Library")
                }
                .listRowBackground(tintedRowBackground(.blue))
                .task {
                    await account.fetchStats()
                    await account.refreshUnreadNotificationCount()
                }

                // MARK: Account Info Section
                Section {
                    LabeledContent("Username") {
                        Text(account.currentUser?.username ?? "")
                            .font(AppTheme.monoFont(size: 14))
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                    .foregroundStyle(AppTheme.textPrimary)

                    // Permanent account identifier — assigned once at signup and
                    // never changes, even if username/email/display name do.
                    // Useful to include when reporting a bug or contacting support.
                    if let userID = account.currentUser?.id {
                        Button {
                            UIPasteboard.general.string = userID
                            withAnimation(LumiMotion.glide) { didCopyUserID = true }
                            Task {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                withAnimation(LumiMotion.glide) { didCopyUserID = false }
                            }
                        } label: {
                            LabeledContent("User ID") {
                                HStack(spacing: 6) {
                                    Text(userID)
                                        .font(AppTheme.monoFont(size: 11))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Image(systemName: didCopyUserID ? "checkmark" : "doc.on.doc")
                                        .font(.caption2)
                                        .foregroundStyle(didCopyUserID ? AppTheme.success : AppTheme.dynamicAccent)
                                }
                                .foregroundStyle(AppTheme.textSecondary)
                            }
                            .foregroundStyle(AppTheme.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }

                    if let email = account.currentUser?.email, !email.isEmpty {
                        LabeledContent("Email") {
                            Text(email)
                                .font(AppTheme.bodyFont(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                        .foregroundStyle(AppTheme.textPrimary)
                    } else if isAddingEmail {
                        // Accounts created before email was mandatory — and every
                        // account auto-created by Discord sign-in before that flow
                        // asked for the email scope — have nothing on file. This is
                        // how they fill it in. Deliberately a prompt and not a
                        // gate: nothing in the app is withheld until they do.
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Email")
                                .font(AppTheme.bodyFont(size: 12))
                                .foregroundStyle(AppTheme.textSecondary)
                            TextField("you@example.com", text: $draftEmail)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .font(AppTheme.bodyFont(size: 14))
                                .foregroundStyle(AppTheme.textPrimary)
                                .submitLabel(.done)
                                .onSubmit { saveEmail() }
                            HStack {
                                if isSavingEmail {
                                    ProgressView().tint(AppTheme.dynamicAccent)
                                } else {
                                    Button("Save") { saveEmail() }
                                        .foregroundStyle(AppTheme.dynamicAccent)
                                        .font(.subheadline.bold())
                                    Button("Cancel") {
                                        isAddingEmail = false
                                        draftEmail = ""
                                    }
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .font(.subheadline)
                                    .padding(.leading, 8)
                                }
                            }
                        }
                    } else {
                        Button {
                            isAddingEmail = true
                        } label: {
                            LabeledContent("Email") {
                                Text("Add")
                                    .font(AppTheme.bodyFont(size: 13))
                                    .foregroundStyle(AppTheme.dynamicAccent)
                            }
                            .foregroundStyle(AppTheme.textPrimary)
                        }
                        .buttonStyle(.plain)
                        if account.needsEmail {
                            Text("Your account has no email address. Adding one is how you can be reached about your account — it isn't used for anything else.")
                                .font(AppTheme.bodyFont(size: 11))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                    }

                    // Date of birth — show once set; show picker if not yet set
                    if account.hasDateOfBirth {
                        LabeledContent("Date of Birth") {
                            Text(account.currentUser?.dateOfBirth ?? "Set")
                                .font(AppTheme.monoFont(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        .foregroundStyle(AppTheme.textPrimary)
                    } else if isPickingDOB {
                        VStack(alignment: .leading, spacing: 6) {
                            DatePicker(
                                "Date of Birth",
                                selection: $draftDOB,
                                in: ...Calendar.current.date(byAdding: .year, value: -13, to: Date())!,
                                displayedComponents: .date
                            )
                            .datePickerStyle(.compact)
                            .foregroundStyle(AppTheme.textPrimary)
                            HStack {
                                if isSavingDOB {
                                    ProgressView().tint(AppTheme.dynamicAccent)
                                } else {
                                    Button("Save") { saveDOB() }
                                        .foregroundStyle(AppTheme.dynamicAccent)
                                        .font(.subheadline.bold())
                                    Button("Cancel") { isPickingDOB = false }
                                        .foregroundStyle(AppTheme.textSecondary)
                                        .font(.subheadline)
                                        .padding(.leading, 8)
                                }
                            }
                        }
                    } else {
                        Button {
                            isPickingDOB = true
                        } label: {
                            HStack {
                                Text("Date of Birth")
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                Text("Not set")
                                    .font(AppTheme.bodyFont(size: 13))
                                    .foregroundStyle(AppTheme.textSecondary)
                                Image(systemName: "pencil")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppTheme.dynamicAccent)
                                    .padding(.leading, 4)
                            }
                        }
                    }

                    // Display name — tappable to edit inline
                    if isEditingDisplayName {
                        HStack {
                            TextField("Display name", text: $draftDisplayName)
                                .textContentType(.name)
                                .autocorrectionDisabled()
                                .foregroundStyle(AppTheme.textPrimary)
                                .submitLabel(.done)
                                .onSubmit { saveDisplayName() }
                            if isSavingDisplayName {
                                ProgressView()
                                    .tint(AppTheme.dynamicAccent)
                                    .padding(.leading, 6)
                            } else {
                                Button("Save") { saveDisplayName() }
                                    .foregroundStyle(AppTheme.dynamicAccent)
                                    .font(.subheadline.bold())
                                Button("Cancel") {
                                    isEditingDisplayName = false
                                    draftDisplayName = ""
                                }
                                .foregroundStyle(AppTheme.textSecondary)
                                .font(.subheadline)
                                .padding(.leading, 4)
                            }
                        }
                    } else {
                        Button {
                            draftDisplayName = account.currentUser?.displayName ?? ""
                            isEditingDisplayName = true
                        } label: {
                            HStack {
                                Text("Display Name")
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                Text(
                                    account.currentUser?.displayName.flatMap {
                                        $0.isEmpty ? nil : $0
                                    } ?? "Not set"
                                )
                                .font(AppTheme.bodyFont(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                                Image(systemName: "pencil")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppTheme.dynamicAccent)
                                    .padding(.leading, 4)
                            }
                        }
                    }

                    // Bio — same tappable-inline-edit pattern as Display Name above.
                    // 280-char cap enforced both here (immediate feedback) and
                    // server-side (PUT /user/bio) — see AccountService+Bio.swift.
                    if isEditingBio {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Say something about yourself…", text: $draftBio, axis: .vertical)
                                .lineLimit(1...3)
                                .foregroundStyle(AppTheme.textPrimary)
                                .onChange(of: draftBio) { newValue in
                                    if newValue.count > 280 { draftBio = String(newValue.prefix(280)) }
                                }
                            HStack {
                                Text("\(draftBio.count)/280")
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.textSecondary)
                                Spacer()
                                if isSavingBio {
                                    ProgressView().tint(AppTheme.dynamicAccent)
                                } else {
                                    Button("Save") { saveBio() }
                                        .foregroundStyle(AppTheme.dynamicAccent)
                                        .font(.subheadline.bold())
                                    Button("Cancel") {
                                        isEditingBio = false
                                        draftBio = ""
                                    }
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .font(.subheadline)
                                    .padding(.leading, 4)
                                }
                            }
                        }
                    } else {
                        Button {
                            draftBio = bio
                            isEditingBio = true
                        } label: {
                            HStack(alignment: .top) {
                                Text("Bio")
                                    .foregroundStyle(AppTheme.textPrimary)
                                Spacer()
                                Text(bio.isEmpty ? "Not set" : bio)
                                    .font(AppTheme.bodyFont(size: 13))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .multilineTextAlignment(.trailing)
                                    .lineLimit(3)
                                Image(systemName: "pencil")
                                    .font(.system(size: 12))
                                    .foregroundStyle(AppTheme.dynamicAccent)
                                    .padding(.leading, 4)
                            }
                        }
                    }

                } header: {
                    sectionHeader("Account")
                }
                .listRowBackground(tintedRowBackground(.blue))
                .task { bio = await account.fetchBio() }

                // MARK: Social / Discovery Section
                Section {
                    NavigationLink(destination: DiscoverView()) {
                        Label("Discover", systemImage: "sparkles")
                            .foregroundStyle(AppTheme.textPrimary)
                    }

                    Button {
                        showListenRoom = true
                    } label: {
                        LabeledContent {
                            // Shows the code when already in a room, so this row
                            // doubles as "get back to the room I'm in" rather than
                            // looking like it would start a second one.
                            if let code = listenRooms.roomCode {
                                Text(code)
                                    .font(AppTheme.monoFont(size: 13))
                                    .foregroundStyle(AppTheme.dynamicAccent)
                            }
                        } label: {
                            Label("Listen Together", systemImage: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                    }
                    .buttonStyle(.plain)

                    Toggle(isOn: Binding(
                        get: { account.currentUser?.shareListeningActivity ?? false },
                        set: { newValue in Task { await account.setShareListeningActivity(newValue) } }
                    )) {
                        Label("Share Listening Activity", systemImage: "person.wave.2")
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                    .tint(AppTheme.dynamicAccent)
                } header: {
                    sectionHeader("Discovery")
                } footer: {
                    Text("When on, the song titles and artists you play (not files or links) appear in Discover's activity feed and count toward Trending for other signed-in users.")
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .listRowBackground(tintedRowBackground(.blue))

                // MARK: Aria Lumi Section
                //
                // No longer a Toggle — Aria Lumi is a built-in part of the
                // metadata pipeline now, not an opt-in the user switches on
                // (see ios-bridge's intelligence.py / main.py's
                // /user/intelligence/metadata-resolve, which used to gate on
                // ai_assisted_suggestions and no longer does). Leaving a
                // toggle bound to a flag the server doesn't check anymore
                // would look interactive while silently doing nothing — this
                // row exists so the behavior change is still visible/explained
                // in Settings, not just documented in the Help guide.
                Section {
                    Label("Aria Lumi", systemImage: "wand.and.stars")
                        .foregroundStyle(AppTheme.textPrimary)

                    Toggle(isOn: $aiDJ.isEnabled) {
                        Label("AI DJ Mode", systemImage: "mic.fill")
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                    .tint(AppTheme.dynamicAccent)

                    if aiDJ.isEnabled {
                        LumiPicker(selection: $aiDJ.voiceIdentifier) {
                            Text("System Default").lumiOptionLabel("System Default").tag(nil as String?)
                            ForEach(AIDJVoiceOption.available) { option in
                                Text(option.displayName).lumiOptionLabel(String(describing: option.displayName)).tag(option.identifier as String?)
                            }
                        } label: {
                            Label("Voice", systemImage: "waveform")
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                        .tint(AppTheme.dynamicAccent)

                        HStack {
                            Label("Pitch", systemImage: "tuningfork")
                                .foregroundStyle(AppTheme.textPrimary)
                            Spacer()
                            Text(String(format: "%.2f×", aiDJ.pitchMultiplier))
                                .font(AppTheme.monoFont(size: 13))
                                .foregroundStyle(AppTheme.textSecondary)
                        }
                        Slider(value: $aiDJ.pitchMultiplier, in: 0.5...2.0, step: 0.02)
                            .tint(AppTheme.dynamicAccent)
                    }
                } header: {
                    sectionHeader("AI Features")
                } footer: {
                    Text("Aria Lumi, Lumisound's built-in music intelligence, automatically helps pick the right metadata match for local files — using titles, artists, thumbnails, and how you actually listen. Always on; see Settings → Help → Library for details. No audio or file contents are ever sent.\n\nAI DJ Mode is opt-in: when on, Aria briefly speaks a short transition line (on-device text-to-speech) between tracks. Only the two track titles/artists involved are sent to write that line — never audio. Voice and Pitch pick from this device's installed system voices (Settings app → Accessibility → Spoken Content → Voices to add more) and tune how high/low she sounds — not a clone of any specific person's voice.")
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .listRowBackground(tintedRowBackground(.blue))
                .animation(LumiMotion.fade(0.2), value: aiDJ.isEnabled)

                // MARK: Security Section
                Section {
                    NavigationLink(destination: TwoFactorAuthView()) {
                        HStack {
                            Label("Two-Factor Authentication", systemImage: "lock.shield")
                                .foregroundStyle(AppTheme.textPrimary)
                            Spacer()
                            if account.isTOTPEnabled {
                                Text("On")
                                    .font(AppTheme.bodyFont(size: 13))
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                    }
                    NavigationLink(destination: ActiveSessionsView()) {
                        Label("Active Sessions", systemImage: "laptopcomputer.and.iphone")
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                    NavigationLink(destination: ChangePasswordView()) {
                        Label("Change Password", systemImage: "key")
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                } header: {
                    sectionHeader("Security")
                }
                .listRowBackground(tintedRowBackground(.blue))
                .task { await account.refreshTOTPStatus() }

                // MARK: Operator Section
                // Only ever rendered for the hardcoded operator account —
                // see AdminDashboardView's own doc comment for why this is
                // just a UX gate, not the real access boundary (the server
                // enforces that independently either way).
                if account.currentUser?.id == AdminDashboardView.operatorUserID {
                    Section {
                        NavigationLink(destination: AdminDashboardView()) {
                            Label("Admin Dashboard", systemImage: "server.rack")
                                .foregroundStyle(AppTheme.textPrimary)
                        }
                    } header: {
                        sectionHeader("Operator")
                    }
                    .listRowBackground(tintedRowBackground(.blue))
                }

                // MARK: Integrations Section
                //
                // Was three separate sections (Discord Rich Presence, Discord
                // Webhook, Streaming/YouTube), each a single- or double-row
                // section with its own header+footer — a lot of vertical
                // scroll for four destinations. Folded into one grid,
                // matching the Library section's redesign above.
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        // Moved here from the Library grid above. Scrobbling is
                        // an external ACCOUNT CONNECTION (Last.fm / Libre.fm), not
                        // a way to browse your own music, and it had zero uptake
                        // while it sat among "Your Rewind", "Achievements" and
                        // "Heatmap" — nobody looking to link an outside account
                        // would think to search a list of listening stats for it.
                        gridLink(destination: ScrobblingView(), title: "Scrobbling", icon: "waveform.path.ecg")
                        gridLink(destination: DiscordRichPresenceView(), title: "Rich Presence", icon: "key.viewfinder")
                        gridLink(destination: DiscordWebhookView(), title: "Now Playing Webhook", icon: "message")
                        gridLink(destination: YoutubeApiKeyView(), title: "YouTube API Key", icon: "key")
                        gridLink(destination: CookiesFileView(), title: "YouTube Cookies", icon: "doc.text")
                    }
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                } header: {
                    sectionHeader("Integrations")
                } footer: {
                    Text("Scrobbling logs every track you play to Last.fm or Libre.fm. Discord Rich Presence shows what you're playing on your profile; the webhook posts \"Now Playing\" messages to a channel. Add your own YouTube Data API v3 key so full playlists (beyond ~205 tracks) resolve completely, and a cookies.txt export to authenticate downloads as your own session.")
                        .font(AppTheme.bodyFont(size: 12))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .listRowBackground(tintedRowBackground(.blue))

                // MARK: Danger Section
                Section {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                            Spacer()
                        }
                    }

                    NavigationLink(destination: DeleteAccountView()) {
                        HStack {
                            Spacer()
                            Label("Delete Account", systemImage: "trash")
                                .foregroundStyle(AppTheme.error)
                            Spacer()
                        }
                    }
                } header: {
                    sectionHeader("Session")
                }
                .listRowBackground(tintedRowBackground(.blue))
            }
            .scrollContentBackground(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            MiniPlayerBar()
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: account.isLoggedIn) { loggedIn in
            if loggedIn {
                Task { await account.pullSync(library: library) }
            } else {
                dismiss()
            }
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
            Button("Unlink", role: .destructive) {
                Task { await discordVerification.unlink() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your Discord Verified badge will be removed. You can link it again later.")
        }
        .sheet(isPresented: $showAvatarGifPicker) {
            GifPickerSheet { data in
                Task { await account.uploadAvatarData(data) }
            }
        }
        .sheet(isPresented: $showListenRoom) {
            // Straight to the room when already in one, rather than making
            // somebody pass back through the create/join form to get to it.
            if listenRooms.isInRoom {
                ListenRoomView()
            } else {
                ListenRoomEntryView()
            }
        }
    }

    // MARK: - Helpers

    private var initials: String {
        guard let user = account.currentUser else { return "?" }
        let name = user.displayName ?? user.username
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(1)).uppercased()
    }

    private func formattedListenTime(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// A single stat card in the horizontal strip at the top of the Library
    /// section — replaces a `LabeledContent` row per number.
    private func statTile(value: String, label: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.dynamicAccent)
            Text(value)
                .font(AppTheme.monoFont(size: 15).weight(.semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(AppTheme.bodyFont(size: 11))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(width: 104, alignment: .leading)
        .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// A single tile in the icon-grid destinations — replaces a plain
    /// `NavigationLink` row in the old Library/Integrations sections.
    private func gridLink<Destination: View>(
        destination: Destination,
        title: String,
        icon: String,
        badge: String? = nil
    ) -> some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .frame(width: 22)
                Text(title)
                    .font(AppTheme.bodyFont(size: 13))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.dynamicAccent, in: Capsule())
                }
            }
            .padding(10)
            .background(AppTheme.elevatedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(AppTheme.bodyFont(size: 11))
            .foregroundStyle(AppTheme.textSecondary)
            .kerning(0.8)
    }

    private func saveDOB() {
        guard !isSavingDOB else { return }
        isSavingDOB = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let iso = formatter.string(from: draftDOB)
        Task {
            defer {
                isSavingDOB = false
                isPickingDOB = false
            }
            await account.setDateOfBirth(iso)
        }
    }

    private func saveEmail() {
        guard !isSavingEmail else { return }
        isSavingEmail = true
        let candidate = draftEmail
        Task {
            defer { isSavingEmail = false }
            // The prompt stays open on failure so the typed address is still
            // there to correct — the server rejects more than this client checks
            // (undeliverable domain, disposable provider, already in use), and
            // dismissing on those would silently discard what they entered.
            if await account.setEmail(candidate) {
                isAddingEmail = false
                draftEmail = ""
            }
        }
    }

    private func saveDisplayName() {
        let trimmed = draftDisplayName.trimmingCharacters(in: .whitespaces)
        guard !isSavingDisplayName else { return }
        isSavingDisplayName = true
        Task {
            defer {
                isSavingDisplayName = false
                isEditingDisplayName = false
                draftDisplayName = ""
            }
            await account.updateDisplayName(trimmed)
        }
    }

    private func saveBio() {
        let trimmed = draftBio.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSavingBio else { return }
        isSavingBio = true
        Task {
            defer {
                isSavingBio = false
                isEditingBio = false
                draftBio = ""
            }
            if await account.setBio(trimmed) {
                bio = trimmed
            }
        }
    }
}
