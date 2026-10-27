import SwiftUI
import WebKit

// MARK: - Accounts + Sources screens

public final class GoogleWebViewStore: NSObject, ObservableObject {
    public let webView: WKWebView
    public override init() {
        webView = WKWebView()
        super.init()
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com")!))
    }
    public func capture() async -> (cookie: String, visitorData: String?) {
        let cookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
        let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        let html = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            webView.evaluateJavaScript("document.documentElement.innerHTML") { result, _ in cont.resume(returning: result as? String ?? "") }
        }
        var visitor: String?
        if let range = html.range(of: #""visitorData":"([^"]+)""#, options: .regularExpression) {
            visitor = String(html[range]).replacingOccurrences(of: "\"visitorData\":\"", with: "").replacingOccurrences(of: "\"", with: "")
        }
        return (header, visitor)
    }
}

public struct GoogleWebView: UIViewRepresentable {
    public var store: GoogleWebViewStore
    public func makeUIView(context: Context) -> WKWebView { store.webView }
    public func updateUIView(_ uiView: WKWebView, context: Context) {}
}

public struct AccountsView: View {
    @StateObject private var google = GoogleAccount.shared
    @StateObject private var spotify = SpotifyAccount.shared
    @StateObject private var discord = DiscordPresence.shared
    @State private var showingGoogle = false
    @StateObject private var googleStore = GoogleWebViewStore()
    @State private var spotifyClientId = UserDefaults.standard.string(forKey: "spotifyClientId") ?? ""
    @State private var spotifyCode = ""
    @State private var spotifyMessage: String?
    @State private var discordToken = Keychain.get("discordToken") ?? ""
    @State private var lastfmKey = Scrobbler.lastfmKey
    @State private var lastfmSecret = Scrobbler.lastfmSecret
    @State private var lastfmToken = ""
    @State private var lastfmSession = Scrobbler.lastfmSession ?? ""
    @State private var listenBrainzToken = Scrobbler.listenBrainzToken
    @State private var lastfmEnabled = Scrobbler.lastfmEnabled
    @State private var listenBrainzEnabled = Scrobbler.listenBrainzEnabled
    @Environment(\.openURL) private var openURL
    public var body: some View {
        List {
            Section("YouTube Music (Google)") {
                Text(google.signedIn ? "Signed in — Innertube requests carry your session cookie." : "Not signed in — browsing and playback are guest-only, and ciphered streams will fail honestly.")
                    .font(.caption).foregroundStyle(.secondary)
                if google.signedIn {
                    Button("Sign out", role: .destructive) { google.signOut() }
                } else {
                    Button("Sign in via YouTube Music") { showingGoogle = true }
                }
            }
            Section("Spotify") {
                TextField("Spotify client id (PKCE — no secret is used or stored)", text: $spotifyClientId)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: spotifyClientId) { _, _ in UserDefaults.standard.set(spotifyClientId, forKey: "spotifyClientId") }
                if spotify.signedIn {
                    Text("Signed in.").foregroundStyle(.green)
                    Button("Refresh playlists & Liked Songs") { Task { await spotify.refreshLibrary() } }
                    Button("Sign out", role: .destructive) { spotify.signOut() }
                } else {
                    Button("Open Spotify login") {
                        if let url = spotify.authURL(redirectURI: "bitchord://spotify-callback") { openURL(url) }
                    }.disabled(spotifyClientId.isEmpty)
                    TextField("Paste the code from the redirect URL", text: $spotifyCode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Exchange code") {
                        Task {
                            let ok = await spotify.exchange(code: spotifyCode, redirectURI: "bitchord://spotify-callback")
                            spotifyMessage = ok ? "Spotify signed in." : "Spotify sign-in failed — check the client id and code."
                        }
                    }.disabled(spotifyCode.isEmpty)
                    if let msg = spotifyMessage { Text(msg).font(.caption) }
                }
                if !spotify.playlists.isEmpty {
                    ForEach(spotify.playlists) { p in Text(p.title) }
                }
            }
            Section("Discord Rich Presence") {
                SecureField("Discord user token", text: $discordToken)
                    .onChange(of: discordToken) { _, _ in Keychain.set(discordToken, for: "discordToken") }
                Toggle("Enable Rich Presence", isOn: $discord.enabled)
                Toggle("Show audio quality in presence", isOn: $discord.showAudioQuality)
                Button(discord.connected ? "Disconnect" : "Connect") {
                    if discord.connected { discord.disconnect() } else { discord.connect() }
                }
                Text("Token is stored in the Keychain, never in source. Presence shows track, artist, album and progress.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Scrobbling") {
                Toggle("Last.fm", isOn: $lastfmEnabled)
                    .onChange(of: lastfmEnabled) { _, _ in UserDefaults.standard.set(lastfmEnabled, forKey: "lastfmEnabled") }
                TextField("Last.fm API key", text: $lastfmKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: lastfmKey) { _, _ in Scrobbler.lastfmKey = lastfmKey }
                SecureField("Last.fm shared secret", text: $lastfmSecret)
                    .onChange(of: lastfmSecret) { _, _ in Scrobbler.lastfmSecret = lastfmSecret }
                if let authURL = Scrobbler.lastfmAuthURL() {
                    Link("Authorize on last.fm", destination: authURL)
                }
                TextField("Last.fm session key", text: $lastfmSession)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: lastfmSession) { _, _ in Scrobbler.lastfmSession = lastfmSession.isEmpty ? nil : lastfmSession }
                Toggle("ListenBrainz", isOn: $listenBrainzEnabled)
                    .onChange(of: listenBrainzEnabled) { _, _ in UserDefaults.standard.set(listenBrainzEnabled, forKey: "listenBrainzEnabled") }
                SecureField("ListenBrainz token", text: $listenBrainzToken)
                    .onChange(of: listenBrainzToken) { _, _ in Scrobbler.listenBrainzToken = listenBrainzToken }
                Text("Scrobble rule: 50% of the track or 240 seconds, whichever comes first. Now-playing is sent on track start.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Accounts")
        .sheet(isPresented: $showingGoogle) {
            NavigationStack {
                GoogleWebView(store: googleStore)
                    .navigationTitle("Sign in to YouTube Music")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Capture session") {
                                Task {
                                    let (cookie, visitor) = await googleStore.capture()
                                    if !cookie.isEmpty { google.applyCookies(cookie, visitorData: visitor) }
                                    showingGoogle = false
                                }
                            }
                        }
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Cancel") { showingGoogle = false }
                        }
                    }
                Text("Sign in, then tap Capture session. The cookie is stored in the Keychain and sent only to music.youtube.com.").font(.caption).foregroundStyle(.secondary).padding()
            }
        }
    }
}

public struct SourcesView: View {
    @StateObject private var registry = SourceRegistry.shared
    @State private var newKind: SourceKind = .addon
    @State private var newName = ""
    @State private var newURL = ""
    @State private var health: [String: Bool] = [:]
    @State private var webdavUsername = UserDefaults.standard.string(forKey: "webdavUsername") ?? ""
    @State private var webdavPassword = Keychain.get("webdavPassword") ?? ""
    public var body: some View {
        List {
            Section("Sources (drag to reorder — order is the resolution order)") {
                ForEach(registry.sources) { source in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(source.name)
                            Text(source.kind.label + (source.serverURL.isEmpty ? "" : " · \(source.serverURL)")).font(.caption).foregroundStyle(.secondary)
                            if let ok = health[source.id] {
                                Text(ok ? "Healthy" : "Unreachable").font(.caption).foregroundStyle(ok ? .green : .red)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { source.enabled }, set: { newValue in
                            if let idx = registry.sources.firstIndex(where: { $0.id == source.id }) { registry.sources[idx].enabled = newValue }
                        })).labelsHidden()
                        Button("Check") {
                            Task {
                                let ok: Bool
                                switch source.kind {
                                case .youtube: ok = true
                                case .jiosaavn: ok = await JioSaavnSource.shared.healthCheck()
                                case .addon: ok = await AddonSource(config: source).healthCheck()
                                case .module: ok = await ModuleSource(config: source).healthCheck()
                                case .webdav: ok = await WebDAVSource(config: source).healthCheck()
                                }
                                health[source.id] = ok
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    for idx in offsets { registry.remove(id: registry.sources[idx].id) }
                }
                .onMove { from, to in registry.move(from: from, to: to) }
            }
            Section("Add a source") {
                Picker("Kind", selection: $newKind) { ForEach([SourceKind.addon, .module, .webdav], id: \.self) { k in Text(k.label).tag(k) } }
                TextField("Name", text: $newName)
                TextField("Server URL", text: $newURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Add source") {
                    guard !newName.isEmpty, !newURL.isEmpty else { return }
                    registry.add(SourceConfig(kind: newKind, name: newName, serverURL: newURL))
                    newName = ""; newURL = ""
                }
                Text("YouTube Music is built-in and cannot be removed. JioSaavn is optional and off by default — its catalogue matching can pick the wrong song.").font(.caption).foregroundStyle(.secondary)
            }
            Section("WebDAV credentials") {
                TextField("Username", text: $webdavUsername)
                    .onChange(of: webdavUsername) { _, _ in UserDefaults.standard.set(webdavUsername, forKey: "webdavUsername") }
                SecureField("Password", text: $webdavPassword)
                    .onChange(of: webdavPassword) { _, _ in Keychain.set(webdavPassword, for: "webdavPassword") }
                Text("Password is stored in the Keychain.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Sources")
        .toolbar { EditButton() }
    }
}
