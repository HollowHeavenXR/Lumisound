import SwiftUI
import UniformTypeIdentifiers

// MARK: - PodcastsView
//
// Subscription list + add-a-feed form. A subscription is validated by the
// bridge fetching the feed once (see main.py's subscribe_podcast) — this
// screen only shows what's already confirmed to parse.
struct PodcastsView: View {
    @EnvironmentObject private var account: AccountService

    @State private var subscriptions: [PodcastSubscription] = []
    @State private var isLoading = true
    @State private var showAddSheet = false
    @AppStorage(PodcastAutoDownloadService.enabledKey) private var autoDownloadEnabled = false

    // OPML import/export
    @State private var showImporter = false
    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var isExporting = false
    @State private var opmlAlertMessage: String?

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if subscriptions.isEmpty {
                emptyState
            } else {
                List {
                    Section {
                        Toggle("Auto-Download New Episodes", isOn: $autoDownloadEnabled)
                    } footer: {
                        Text("Downloads episodes published in the last 2 days, checked every few hours (up to 3 per show per check).")
                    }
                    ForEach(subscriptions) { sub in
                        NavigationLink(destination: PodcastEpisodesView(subscription: sub)) {
                            row(for: sub)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                toggleMute(sub)
                            } label: {
                                Label(
                                    sub.notificationsMuted ? "Unmute" : "Mute",
                                    systemImage: sub.notificationsMuted ? "bell" : "bell.slash"
                                )
                            }
                            .tint(AppTheme.dynamicAccent)
                        }
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Podcasts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Menu {
                    Button {
                        exportOPML()
                    } label: {
                        Label("Export OPML", systemImage: "square.and.arrow.up")
                    }
                    .disabled(subscriptions.isEmpty || isExporting)

                    Button {
                        showImporter = true
                    } label: {
                        Label("Import OPML", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddPodcastSheet { await reload() }
        }
        .sheet(isPresented: $showShareSheet) {
            if let exportURL {
                RewindShareSheet(items: [exportURL])
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: opmlContentTypes) { result in
            handleImportResult(result)
        }
        .alert("Podcasts", isPresented: .constant(opmlAlertMessage != nil), presenting: opmlAlertMessage) { _ in
            Button("OK") { opmlAlertMessage = nil }
        } message: { message in
            Text(message)
        }
        .task { await reload() }
        .refreshable { await reload() }
    }

    private var opmlContentTypes: [UTType] {
        [UTType(filenameExtension: "opml"), .xml].compactMap { $0 }
    }

    private func exportOPML() {
        isExporting = true
        Task {
            defer { isExporting = false }
            guard let opml = await account.exportPodcastsOPML() else {
                opmlAlertMessage = account.errorMessage ?? "Couldn't export your subscriptions."
                return
            }
            do {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lumisound-Podcasts.opml")
                try opml.write(to: url, atomically: true, encoding: .utf8)
                exportURL = url
                showShareSheet = true
            } catch {
                opmlAlertMessage = "Couldn't create the export file."
            }
        }
    }

    private func handleImportResult(_ result: Result<URL, Error>) {
        switch result {
        case .failure:
            opmlAlertMessage = "Couldn't read that file."
        case .success(let url):
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
            guard let opml = try? String(contentsOf: url, encoding: .utf8) else {
                opmlAlertMessage = "Couldn't read that file."
                return
            }
            Task {
                guard let result = await account.importPodcastsOPML(opml) else {
                    opmlAlertMessage = account.errorMessage ?? "Import failed."
                    return
                }
                opmlAlertMessage = "Added \(result.added) of \(result.total) podcast(s)."
                await reload()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.square")
                .font(.system(size: 32))
                .foregroundStyle(AppTheme.textSecondary)
            Text("No Podcasts Yet")
                .font(.headline)
            Text("Add a show's RSS feed URL to start listening.")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Add a Podcast") { showAddSheet = true }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.dynamicAccent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for sub: PodcastSubscription) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: sub.artworkURL.flatMap(URL.init)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(AppTheme.surface)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(sub.title?.isEmpty == false ? sub.title! : sub.feedURL)
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)

            if sub.notificationsMuted {
                Spacer()
                Image(systemName: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private func toggleMute(_ sub: PodcastSubscription) {
        guard let index = subscriptions.firstIndex(where: { $0.id == sub.id }) else { return }
        let newValue = !sub.notificationsMuted
        subscriptions[index].notificationsMuted = newValue
        Task { await account.setPodcastNotificationsMuted(id: sub.id, muted: newValue) }
    }

    private func reload() async {
        isLoading = true
        subscriptions = await account.fetchPodcastSubscriptions()
        isLoading = false
    }

    private func delete(at offsets: IndexSet) {
        let toRemove = offsets.map { subscriptions[$0] }
        subscriptions.remove(atOffsets: offsets)
        Task {
            for sub in toRemove {
                await account.unsubscribeFromPodcast(id: sub.id)
            }
        }
    }
}

private struct AddPodcastSheet: View {
    @EnvironmentObject private var account: AccountService
    @Environment(\.dismiss) private var dismiss
    let onAdded: () async -> Void

    private enum Mode: String, CaseIterable { case search = "Search", trending = "Trending", url = "Feed URL" }
    @State private var mode: Mode = .search

    @State private var feedURLText = ""
    @State private var errorText: String?

    @State private var searchQuery = ""
    @State private var searchResults: [PodcastSearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var subscribingFeedURL: String?

    @State private var trendingResults: [PodcastSearchResult] = []
    @State private var isLoadingTrending = false
    @State private var hasLoadedTrending = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                switch mode {
                case .search: searchBody
                case .trending: trendingBody
                case .url: urlBody
                }
            }
            .navigationTitle("Add Podcast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: Search tab

    private var searchBody: some View {
        List {
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }
            if isSearching && searchResults.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if searchResults.isEmpty && !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("No podcasts found.")
                    .foregroundStyle(AppTheme.textSecondary)
            }
            ForEach(searchResults) { result in
                PodcastResultRow(result: result, isSubscribing: subscribingFeedURL == result.feedURL) {
                    subscribe(feedURL: result.feedURL)
                }
                .disabled(subscribingFeedURL != nil)
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchQuery, prompt: "Search podcasts")
        .onChange(of: searchQuery) { newValue in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await runSearch(newValue)
            }
        }
    }

    // MARK: Trending tab

    private var trendingBody: some View {
        List {
            if isLoadingTrending && trendingResults.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if trendingResults.isEmpty && hasLoadedTrending {
                Text("Nothing trending right now — try again later.")
                    .foregroundStyle(AppTheme.textSecondary)
            }
            ForEach(trendingResults) { result in
                PodcastResultRow(result: result, isSubscribing: subscribingFeedURL == result.feedURL) {
                    subscribe(feedURL: result.feedURL)
                }
                .disabled(subscribingFeedURL != nil)
            }
        }
        .listStyle(.plain)
        .task {
            guard !hasLoadedTrending else { return }
            isLoadingTrending = true
            trendingResults = await account.fetchTrendingPodcasts()
            hasLoadedTrending = true
            isLoadingTrending = false
        }
    }

    private func runSearch(_ query: String) async {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        isSearching = true
        searchResults = await account.searchPodcasts(query: query)
        isSearching = false
    }

    private func subscribe(feedURL: String) {
        subscribingFeedURL = feedURL
        errorText = nil
        Task {
            let result = await account.subscribeToPodcast(feedURL: feedURL)
            subscribingFeedURL = nil
            if result != nil {
                await onAdded()
                dismiss()
            } else {
                errorText = account.errorMessage ?? "Couldn't add that feed."
            }
        }
    }

    // MARK: Feed URL tab

    private var urlBody: some View {
        Form {
            Section {
                TextField("https://example.com/feed.xml", text: $feedURLText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Feed URL")
            } footer: {
                if let errorText {
                    Text(errorText).foregroundStyle(.red)
                }
            }
            Section {
                if subscribingFeedURL != nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    Button("Add") { subscribe(feedURL: feedURLText.trimmingCharacters(in: .whitespaces)) }
                        .disabled(feedURLText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

/// One tappable row for a `PodcastSearchResult` — shared by the Search and
/// Trending tabs of `AddPodcastSheet`, since both just show a subscribe
/// button over the same result shape.
private struct PodcastResultRow: View {
    let result: PodcastSearchResult
    let isSubscribing: Bool
    let onSubscribe: () -> Void

    var body: some View {
        Button(action: onSubscribe) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title ?? "Untitled")
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(2)
                    if let artist = result.artist {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                Spacer()
                if isSubscribing {
                    ProgressView()
                } else {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(AppTheme.dynamicAccent)
                }
            }
        }
    }
}
