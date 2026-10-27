import SwiftUI

// MARK: - Shared catalogue UI + Home / Explore / Search / Library / Detail

public struct ArtworkView: View {
    public var url: String?; public var size: CGFloat
    public init(url: String?, size: CGFloat = 56) { self.url = url; self.size = size }
    public var body: some View {
        Group {
            if let url, let imageURL = URL(string: url) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: Color.gray.opacity(0.3)
                    }
                }
            } else { Color.gray.opacity(0.3) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

public struct TrackRow: View {
    public var track: Track
    public var onPlay: () -> Void
    public var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                ArtworkView(url: track.thumbnailURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title).lineLimit(1).foregroundStyle(.primary)
                    Text(track.artistText).lineLimit(1).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if track.durationSeconds > 0 { Text(track.durationText).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play next") { PlayerEngine.shared.addToQueue([track], playNext: true) }
            Button("Add to queue") { PlayerEngine.shared.addToQueue([track]) }
            Button("Download") { DownloadsStore.shared.download(track) }
        }
    }
}

public struct ShelfRow: View {
    public var shelf: Shelf
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(shelf.title).font(.headline).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(shelf.items, id: \.selfHash) { item in
                        switch item {
                        case .track(let t):
                            VStack(alignment: .leading, spacing: 4) {
                                ArtworkView(url: t.thumbnailURL, size: 120)
                                Text(t.title).lineLimit(2).font(.subheadline).frame(width: 120, alignment: .leading)
                                Text(t.artistText).lineLimit(1).font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                            }
                            .onTapGesture { PlayerEngine.shared.playTrack(t) }
                        case .album(let a):
                            NavigationLink(value: DetailDestination.album(a)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ArtworkView(url: a.thumbnailURL, size: 120)
                                    Text(a.title).lineLimit(2).font(.subheadline).frame(width: 120, alignment: .leading)
                                }
                            }.buttonStyle(.plain)
                        case .artist(let a):
                            NavigationLink(value: DetailDestination.artist(a)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ArtworkView(url: a.thumbnailURL, size: 120)
                                    Text(a.name).lineLimit(2).font(.subheadline).frame(width: 120, alignment: .leading)
                                }
                            }.buttonStyle(.plain)
                        case .playlist(let p):
                            NavigationLink(value: DetailDestination.playlist(p)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ArtworkView(url: p.thumbnailURL, size: 120)
                                    Text(p.title).lineLimit(2).font(.subheadline).frame(width: 120, alignment: .leading)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

extension ShelfItem {
    var selfHash: String {
        switch self {
        case .track(let t): return "t:\(t.id)"
        case .artist(let a): return "a:\(a.id)"
        case .album(let a): return "al:\(a.id)"
        case .playlist(let p): return "p:\(p.id)"
        }
    }
}

public enum DetailDestination: Hashable {
    case artist(ArtistItem), album(AlbumItem), playlist(PlaylistItem)
}

/// Parse Innertube shelves: carousel shelves (two-row cards) and list shelves.
public func parseShelves(from json: JSONValue) -> [Shelf] {
    var out: [Shelf] = []
    for shelf in json.findAllDeep("musicCarouselShelfRenderer") {
        let title = shelf["header"]["musicCarouselShelfBasicHeaderRenderer"]["title"].runsText
        var items: [ShelfItem] = []
        for card in shelf["contents"].array ?? [] {
            let two = card["musicTwoRowItemRenderer"]
            if !two.isNull {
                let cardTitle = two["title"].runsText
                let thumb = two["thumbnailRenderer"]["musicThumbnailRenderer"].thumbnailURL
                let browseId = two["navigationEndpoint"]["browseEndpoint"]["browseId"].string ?? ""
                let watchId = two["navigationEndpoint"]["watchEndpoint"]["videoId"].string ?? ""
                if !watchId.isEmpty {
                    items.append(.track(Track(id: watchId, title: cardTitle, artists: [], thumbnailURL: thumb)))
                } else if !browseId.isEmpty {
                    if browseId.hasPrefix("UC") { items.append(.artist(ArtistItem(id: browseId, name: cardTitle, thumbnailURL: thumb))) }
                    else if browseId.hasPrefix("MPRE") { items.append(.album(AlbumItem(id: browseId, title: cardTitle, thumbnailURL: thumb))) }
                    else { items.append(.playlist(PlaylistItem(id: browseId, title: cardTitle, thumbnailURL: thumb))) }
                }
                continue
            }
            if let track = InnertubeClient.parseTracks(from: card).first { items.append(.track(track)) }
        }
        if !items.isEmpty { out.append(Shelf(title: title.isEmpty ? "Browse" : title, items: items)) }
    }
    // List shelves that are not carousels (search results, detail lists).
    for shelf in json.findAllDeep("musicShelfRenderer") {
        let tracks = InnertubeClient.parseTracks(from: shelf)
        if !tracks.isEmpty { out.append(Shelf(title: shelf["title"].runsText, tracks: tracks, items: tracks.map { .track($0) })) }
    }
    return out
}

public struct BrowseView: View {
    public var browseId: String; public var title: String
    @State private var shelves: [Shelf] = []
    @State private var error: String?
    @State private var loading = false
    public init(browseId: String, title: String) { self.browseId = browseId; self.title = title }
    public var body: some View {
        ScrollView {
            if loading { ProgressView().padding() }
            if let error { Text(error).foregroundStyle(.red).padding() }
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(shelves) { shelf in
                    if shelf.tracks.count > 0, shelf.items.count == shelf.tracks.count {
                        VStack(alignment: .leading, spacing: 4) {
                            if !shelf.title.isEmpty { Text(shelf.title).font(.headline).padding(.horizontal) }
                            ForEach(shelf.tracks) { track in
                                TrackRow(track: track) { PlayerEngine.shared.playTrack(track, in: shelf.tracks) }.padding(.horizontal)
                            }
                        }
                    } else {
                        ShelfRow(shelf: shelf)
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(title)
        .task { await load() }
        .refreshable { await load() }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            _ = await InnertubeClient.shared.ensureVisitorData()
            let json = try await InnertubeClient.shared.browse(browseId: browseId)
            shelves = parseShelves(from: json)
            if shelves.isEmpty { error = "YouTube Music returned no shelves for this page. Sign in from Accounts if this is a personal page." }
            else { error = nil }
        } catch { self.error = error.localizedDescription }
    }
}

public struct HomeView: View {
    public var body: some View {
        NavigationStack {
            BrowseView(browseId: "FEmusic_home", title: "Home")
                .navigationDestination(for: DetailDestination.self) { dest in DetailView(destination: dest) }
        }
    }
}

public struct ExploreView: View {
    public var body: some View {
        NavigationStack {
            BrowseView(browseId: "FEmusic_explore", title: "Explore")
                .navigationDestination(for: DetailDestination.self) { dest in DetailView(destination: dest) }
        }
    }
}

public struct SearchView: View {
    @State private var query = ""
    @State private var filter: SearchFilter = .all
    @State private var tracks: [Track] = []
    @State private var items: [ShelfItem] = []
    @State private var continuation: String?
    @State private var history: [String] = UserDefaults.standard.stringArray(forKey: "searchHistory") ?? []
    @State private var error: String?
    @State private var searching = false
    public var body: some View {
        NavigationStack {
            List {
                if !tracks.isEmpty || !items.isEmpty {
                    Section("Results") {
                        ForEach(tracks) { track in TrackRow(track: track) { PlayerEngine.shared.playTrack(track, in: tracks) } }
                        ForEach(items, id: \.selfHash) { item in
                            switch item {
                            case .artist(let a): NavigationLink(a.name, value: DetailDestination.artist(a))
                            case .album(let a): NavigationLink(a.title, value: DetailDestination.album(a))
                            case .playlist(let p): NavigationLink(p.title, value: DetailDestination.playlist(p))
                            case .track(let t): TrackRow(track: t) { PlayerEngine.shared.playTrack(t) }
                            }
                        }
                    }
                } else if !history.isEmpty {
                    Section("Recent searches") {
                        ForEach(history, id: \.self) { q in
                            Button(q) { query = q; Task { await runSearch() } }
                        }
                        Button("Clear history", role: .destructive) { history = []; UserDefaults.standard.set(history, forKey: "searchHistory") }
                    }
                }
                if let token = continuation {
                    Section {
                        Button("Load more results") {
                            Task {
                                do {
                                    let json = try await InnertubeClient.shared.searchContinuation(token: token)
                                    tracks += InnertubeClient.parseTracks(from: json)
                                    continuation = InnertubeClient.continuationToken(from: json)
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if searching { Section { ProgressView() } }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Songs, albums, artists, playlists")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Picker("Filter", selection: $filter) { ForEach(SearchFilter.allCases) { f in Text(f.rawValue).tag(f) } }
                        .pickerStyle(.menu)
                        .onChange(of: filter) { _, _ in Task { if !query.isEmpty { await runSearch() } } }
                }
            }
            .navigationDestination(for: DetailDestination.self) { dest in DetailView(destination: dest) }
        }
    }
    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true; defer { searching = false }
        if !history.contains(q) { history.insert(q, at: 0); history = Array(history.prefix(20)); UserDefaults.standard.set(history, forKey: "searchHistory") }
        do {
            _ = await InnertubeClient.shared.ensureVisitorData()
            let json = try await InnertubeClient.shared.search(query: q, params: filter.innertubeParams)
            tracks = InnertubeClient.parseTracks(from: json)
            continuation = InnertubeClient.continuationToken(from: json)
            // Non-song rows (artists/albums/playlists) carry browseEndpoints, not videoIds.
            var found: [ShelfItem] = []
            for item in json.findAllDeep("musicResponsiveListItemRenderer") {
                guard let browseId = item["navigationEndpoint"]["browseEndpoint"]["browseId"].string, !browseId.isEmpty else { continue }
                let title = item["flexColumns"][0]["musicResponsiveListItemFlexColumnRenderer"]["text"].runsText
                let subtitle = item["flexColumns"][1]["musicResponsiveListItemFlexColumnRenderer"]["text"].runsText
                let thumb = item["thumbnail"]["musicThumbnailRenderer"].thumbnailURL
                if browseId.hasPrefix("UC") { found.append(.artist(ArtistItem(id: browseId, name: title, thumbnailURL: thumb))) }
                else if browseId.hasPrefix("MPRE") { found.append(.album(AlbumItem(id: browseId, title: title, thumbnailURL: thumb))) }
                else if subtitle.localizedCaseInsensitiveContains("playlist") { found.append(.playlist(PlaylistItem(id: browseId, title: title, thumbnailURL: thumb))) }
            }
            items = found; error = (tracks.isEmpty && found.isEmpty) ? "No results." : nil
            // Pluggable sources are searched too, after YouTube.
            let extra = await SourceRegistry.shared.searchAll(query: q)
            tracks += extra.filter { t in !tracks.contains { $0.title == t.title } }
        } catch { self.error = error.localizedDescription }
    }
}

public struct LibraryView: View {
    @StateObject private var history = HistoryStore.shared
    @StateObject private var downloads = DownloadsStore.shared
    @StateObject private var local = LocalLibrary.shared
    public var body: some View {
        NavigationStack {
            List {
                Section("Your library") {
                    NavigationLink("History") { HistoryView() }
                    NavigationLink("Downloads") { DownloadsView() }
                    NavigationLink("Local files") { LocalLibraryView() }
                    NavigationLink("Liked & saved (YouTube Music)") { BrowseView(browseId: "FEmusic_library_landing", title: "Library") }
                }
                if !history.entries.isEmpty {
                    Section("Recently played") {
                        ForEach(Array(history.entries.suffix(10).reversed().enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading) { Text(entry.title); Text(entry.artist).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                if !downloads.manifest.isEmpty {
                    Section("Downloaded") {
                        ForEach(downloads.downloadedTracks()) { track in TrackRow(track: track) { PlayerEngine.shared.playTrack(track) } }
                    }
                }
                if !local.allLocalTracks.isEmpty {
                    Section("On this device") {
                        ForEach(local.allLocalTracks.prefix(20)) { track in TrackRow(track: track) { PlayerEngine.shared.playTrack(track) } }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: DetailDestination.self) { dest in DetailView(destination: dest) }
            .task { local.refreshImported() }
        }
    }
}

public struct HistoryView: View {
    @StateObject private var history = HistoryStore.shared
    public var body: some View {
        List {
            ForEach(Array(history.entries.reversed().enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading) {
                    Text(entry.title)
                    Text("\(entry.artist) · \(Int(entry.playedSeconds))s of \(Int(entry.durationSeconds))s").font(.caption).foregroundStyle(.secondary)
                    Text(entry.date, style: .date).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !history.entries.isEmpty {
                Button("Clear history", role: .destructive) { history.clear() }
            }
        }
        .navigationTitle("History")
    }
}

public struct DetailView: View {
    public var destination: DetailDestination
    @State private var tracks: [Track] = []
    @State private var title = ""
    @State private var error: String?
    public init(destination: DetailDestination) { self.destination = destination }
    private var browseId: String {
        switch destination {
        case .artist(let a): return a.id
        case .album(let a): return a.id
        case .playlist(let p): return p.id
        }
    }
    public var body: some View {
        List {
            if !title.isEmpty { Section { Text(title).font(.headline) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section {
                ForEach(tracks) { track in TrackRow(track: track) { PlayerEngine.shared.playTrack(track, in: tracks) } }
            }
            Section {
                Button("Play all") { if let first = tracks.first { PlayerEngine.shared.playTrack(first, in: tracks) } }
                Button("Shuffle play") { let shuffled = tracks.shuffled(); if let first = shuffled.first { PlayerEngine.shared.playTrack(first, in: shuffled) } }
            }
        }
        .navigationTitle(title.isEmpty ? "Details" : title)
        .task { await load() }
    }
    private func load() async {
        do {
            let json = try await InnertubeClient.shared.browse(browseId: browseId)
            tracks = InnertubeClient.parseTracks(from: json)
            title = json.findDeep("musicDetailHeaderRenderer")["title"].runsText
            if title.isEmpty { title = json.findDeep("musicResponsiveHeaderRenderer")["title"].runsText }
            if title.isEmpty {
                switch destination {
                case .artist(let a): title = a.name
                case .album(let a): title = a.title
                case .playlist(let p): title = p.title
                }
            }
            if tracks.isEmpty { error = "No tracks found on this page." }
        } catch { self.error = error.localizedDescription }
    }
}
