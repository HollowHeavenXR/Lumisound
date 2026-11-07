import SwiftUI
import MediaPlayer

// MARK: - Genres Tab

struct GenresTab: View {
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var player: AudioPlayerManager

    /// Same list/grid customization already available on Songs/Albums/Artists/
    /// Folders (see SongsTab/AlbumsTab's identical `@AppStorage` + toolbar
    /// menu pattern) — Genres had no such control despite browsing the same
    /// kind of library collection.
    @AppStorage("library_genres_columns") private var genreColumns: Int = 1

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: genreColumns)
    }

    var body: some View {
        Group {
            if genreColumns == 1 {
                List {
                    if library.genres.isEmpty {
                        EmptyStateView(icon: "music.note.list", title: "No genres", message: "Add music to see genres here.")
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(library.genres, id: \.self) { genre in
                            Button {
                                let songs = library.songs(inGenre: genre)
                                player.setQueue(songs, startIndex: 0, autoplay: true)
                            } label: {
                                GenreRow(genre: genre)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(AppTheme.surface.opacity(0.5))
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                ScrollView {
                    if library.genres.isEmpty {
                        EmptyStateView(icon: "music.note.list", title: "No genres", message: "Add music to see genres here.")
                            .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: gridColumns, spacing: 12) {
                            ForEach(library.genres, id: \.self) { genre in
                                Button {
                                    let songs = library.songs(inGenre: genre)
                                    player.setQueue(songs, startIndex: 0, autoplay: true)
                                } label: {
                                    GenreGridCell(genre: genre)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 190)
                    }
                }
                .background(Color.clear.ignoresSafeArea())
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                LumiMenu {
                    Button {
                        genreColumns = 1
                    } label: {
                        Label("1 Column", systemImage: "rectangle.grid.1x2")
                    }
                    Button {
                        genreColumns = 2
                    } label: {
                        Label("2 Columns", systemImage: "square.grid.2x2")
                    }
                    Button {
                        genreColumns = 3
                    } label: {
                        Label("3 Columns", systemImage: "square.grid.3x3")
                    }
                } label: {
                    Image(systemName: genreColumns == 1 ? "rectangle.grid.1x2" : genreColumns == 2 ? "square.grid.2x2" : "square.grid.3x3")
                }
                .tint(AppTheme.dynamicAccent)
            }
        }
    }
}

private struct GenreRow: View {
    let genre: String
    @EnvironmentObject private var library: LibraryManager

    private var songCount: Int {
        library.songs(inGenre: genre).count
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.elevatedSurface)
                Image(systemName: "music.note.list")
                    .foregroundStyle(AppTheme.dynamicAccent)
                    .font(.system(size: 16))
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(genre)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text("\(songCount) \(songCount == 1 ? "song" : "songs")")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer()

            Image(systemName: "play.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(AppTheme.dynamicAccent)
        }
        .padding(.vertical, 4)
    }
}

private struct GenreGridCell: View {
    let genre: String
    @EnvironmentObject private var library: LibraryManager

    private var songCount: Int {
        library.songs(inGenre: genre).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(AppTheme.elevatedSurface)
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.system(size: geo.size.width * 0.25))
                            .foregroundStyle(AppTheme.dynamicAccent)
                    }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(genre)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(2)
                Text("\(songCount) \(songCount == 1 ? "song" : "songs")")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 2)
        }
    }
}
